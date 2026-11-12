#!/usr/bin/env bash
# Publishes one software release as software.release.* records in the
# publisher's own atproto repo, over XRPC with curl: the project (once), an
# immutable manifest and version, and the channels that should point at it.
#
# Records and keys, for project P and version V published at T:
#   software.release.project   P              created once, then left alone
#   software.release.manifest  TID(T)         immutable: must equal the plan
#   software.release.version   P.V            immutable: must equal the plan
#   software.release.channel   P.<channel>    moved forward, never back
# TID(T) is T in microseconds shifted left 10 bits with clock id 0, so a rerun
# for the same release finds the same manifest.
#
# Everything is planned from public reads first; if any immutable record
# differs from the plan, or a planned record holds a blob, nothing is written.
# A dry run prints that plan and stops, without signing in.
#
# Environment (the action's inputs):
#   IDENTIFIER     handle or DID of the publishing account (required)
#   PASSWORD       an app password for it; not needed for a dry run
#   PUBLISHER_DID  the DID IDENTIFIER must resolve to; required
#   PROJECT, VERSION, REPOSITORY, COMMIT   (required)
#   TAG            the git tag; default v<version>
#   CHANGELOG_URL  optional
#   PUBLISHED_AT   RFC 3339 (required); gives the manifest's key
#   CHANNELS       channel names, comma or newline separated; may be empty
#   RELEASES       a path to a JSON file holding an array of releases, each
#                  {version, repository, commit, tag, changelog-url,
#                  published-at, channels}; replaces the seven inputs above,
#                  which must then be empty
#   DRY_RUN        true (default) or false
#   PACE           seconds between writes (default 2); not used in a dry run
#   PLC_URL        default https://plc.directory
# A batch runs in the given order with one session and stops at the first
# release that fails; the releases before it stay published.
# Writes version-uri and version-cid (of the last release), published (true
# when anything was written), count-written and count-skipped (releases that
# needed writes, and releases that needed none) to $GITHUB_OUTPUT, and the
# plan to $GITHUB_STEP_SUMMARY, when they are set.
#
# Sourcing this file defines its functions without running anything; the
# tests use that to plant a blob in a record.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_NSID=software.release.project
MANIFEST_NSID=software.release.manifest
VERSION_NSID=software.release.version
CHANNEL_NSID=software.release.channel
# Stands in for a CID that only exists once the record is written.
PENDING_CID="<cid once created>"

die() {
  echo "::error::$*"
  exit 1
}

helper() { python3 "$here/release.py" "$@"; }

output() { if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi; }
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "$1" >> "$GITHUB_STEP_SUMMARY"; fi; }

# One item a line, without blanks or surrounding spaces.
list() {
  tr ',' '\n' <<<"$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true
}

uri_encode() { jq -rn --arg v "$1" '$v | @uri'; }

# ---------------------------------------------------------------- HTTP ------

tmp=""
auth_header=""
cleanup() { if [[ -n "$tmp" ]]; then rm -rf "$tmp"; fi; }

# request METHOD URL [BODY]: sets $status and $body. BODY goes over stdin, and
# the session token from a header file, so neither is ever in curl's argv.
# No retries: any failure stops the run.
request() {
  local method=$1 url=$2 data=${3-} out="$tmp/response"
  local args=(-sS -X "$method" -o "$out" -w '%{http_code}' -H 'Accept: application/json')
  if [[ -n "$auth_header" ]]; then args+=(-H "@$auth_header"); fi
  : > "$out"
  if [[ $# -ge 3 ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary @-)
    status=$(printf '%s' "$data" | curl "${args[@]}" "$url") || die "could not reach ${url%%\?*}"
  else
    status=$(curl "${args[@]}" "$url" </dev/null) || die "could not reach ${url%%\?*}"
  fi
  body=$(cat "$out")
}

ok() { [[ "$status" == 2[0-9][0-9] ]]; }

# xrpc_error WHAT: dies naming the XRPC error and message, or the HTTP status.
xrpc_error() {
  local detail
  detail=$(jq -r 'select(type == "object" and .error != null) | "\(.error): \(.message // "no message")"' <<<"$body" 2>/dev/null || true)
  die "$1 failed (HTTP $status${detail:+, $detail})"
}

# ---------------------------------------------------------- identity --------

# resolve_did IDENTIFIER: sets $did.
resolve_did() {
  local id=$1 txt
  if [[ "$id" == did:* ]]; then
    did=$id
    return
  fi
  id="${id#@}"
  id=$(tr '[:upper:]' '[:lower:]' <<<"$id")
  did=""
  # DNS first, then HTTPS, as https://atproto.com/specs/handle says.
  txt=$(dig +short TXT "_atproto.$id" 2>/dev/null | tr -d '"' | grep '^did=' || true)
  if [[ $(grep -c . <<<"$txt") -gt 1 ]]; then
    die "_atproto.$id has more than one did= TXT record"
  fi
  did="${txt#did=}"
  if [[ -z "$did" ]]; then
    request GET "https://$id/.well-known/atproto-did"
    if ok; then did=$(head -n1 <<<"$body" | tr -d '[:space:]'); fi
  fi
  [[ "$did" == did:* ]] || die "$1 did not resolve to a DID (no _atproto.$id TXT record or https://$id/.well-known/atproto-did)"
  HANDLE=$id
}

# did_document DID: sets $doc.
did_document() {
  local url
  case "$1" in
    did:plc:*) url="${PLC_URL%/}/$1" ;;
    did:web:*)
      local host="${1#did:web:}"
      [[ "$host" != *:* ]] || die "$1: did:web with a path or port is not an atproto DID"
      url="https://$host/.well-known/did.json" ;;
    *) die "$1 is neither did:plc nor did:web" ;;
  esac
  request GET "$url"
  ok || die "could not fetch the DID document for $1 from $url (HTTP $status)"
  doc=$body
  [[ "$(jq -r '.id // empty' <<<"$doc")" == "$1" ]] || die "the DID document at $url is not for $1"
}

# pds_endpoint: the #atproto_pds service in $doc.
pds_endpoint() {
  jq -r --arg did "$did" '
    [.service[]? | select((.id == "#atproto_pds" or .id == ($did + "#atproto_pds"))
      and .type == "AtprotoPersonalDataServer") | .serviceEndpoint][0] // empty' <<<"$doc"
}

sign_in() {
  local session
  # The password reaches jq through its environment and curl through stdin.
  session=$(SESSION_ID="$did" jq -n '{identifier: env.SESSION_ID, password: env.PASSWORD}')
  request POST "$pds/xrpc/com.atproto.server.createSession" "$session"
  ok || xrpc_error "signing in as $did"
  local jwt session_did
  jwt=$(jq -r '.accessJwt // empty' <<<"$body")
  session_did=$(jq -r '.did // empty' <<<"$body")
  body=""
  [[ -n "$jwt" ]] || die "signing in as $did returned no access token"
  echo "::add-mask::$jwt"
  [[ "$session_did" == "$did" ]] || die "signed in as $session_did, not $did"
  auth_header="$tmp/auth"
  (umask 077 && printf 'Authorization: Bearer %s\n' "$jwt" > "$auth_header")
}

# ----------------------------------------------------------- records --------

project_uri() { echo "at://$did/$PROJECT_NSID/$PROJECT"; }

project_record() {
  jq -n --arg name "$PROJECT" '{"$type": "software.release.project", name: $name}'
}

manifest_record() {
  jq -n --arg project "$(project_uri)" --arg repository "$REPOSITORY" \
    --arg commit "$COMMIT" --arg ref "$GIT_REF" '{
      "$type": "software.release.manifest",
      project: $project,
      artifacts: [{
        "$type": "software.release.defs#gitRevision",
        repository: $repository,
        commit: {algorithm: "sha1", digest: $commit},
        ref: $ref
      }]
    }'
}

version_record() { # manifest-uri manifest-cid
  jq -n --arg project "$(project_uri)" --arg version "$VERSION" \
    --arg changelog "$CHANGELOG_URL" --arg uri "$1" --arg cid "$2" '{
      "$type": "software.release.version",
      project: $project,
      version: $version
    }
    + (if $changelog == "" then {} else {changelog: $changelog} end)
    + {manifest: {uri: $uri, cid: $cid}}'
}

channel_record() { # channel version-uri version-cid
  jq -n --arg project "$(project_uri)" --arg channel "$1" --arg uri "$2" --arg cid "$3" '{
    "$type": "software.release.channel",
    project: $project,
    channel: $channel,
    version: {uri: $uri, cid: $cid}
  }'
}

# refuse_blobs NAME JSON: these records never carry blobs; dies if one does.
refuse_blobs() {
  # A blob ref, an untyped ref, or the legacy {cid, mimeType} shape.
  if jq -e '[.. | objects | select(."$type" == "blob"
      or ((.ref | type) == "object" and (.ref | has("$link")))
      or ((.cid | type) == "string" and (.mimeType | type) == "string"))] | length > 0' <<<"$2" >/dev/null; then
    die "$1 would hold a blob, and release records never do; nothing was written"
  fi
}

# get_record COLLECTION RKEY [REPO]: sets $found (true/false) and $record
# ({uri, cid, value}). A public read: no session, even after signing in.
get_record() {
  local repo=${3:-$did} saved=$auth_header
  auth_header=""
  request GET "$pds/xrpc/com.atproto.repo.getRecord?repo=$(uri_encode "$repo")&collection=$(uri_encode "$1")&rkey=$(uri_encode "$2")"
  auth_header=$saved
  if ok; then
    found=true
    record=$body
  elif [[ "$status" == 400 && "$(jq -r '.error // empty' <<<"$body" 2>/dev/null)" == RecordNotFound ]]; then
    found=false
    record=""
  else
    xrpc_error "reading at://$repo/$1/$2"
  fi
}

same_json() { [[ "$(jq -S . <<<"$1")" == "$(jq -S . <<<"$2")" ]]; }

# write_record create|put COLLECTION RKEY JSON [SWAP-CID]: sets $written_uri
# and $written_cid.
writes_done=0
write_record() {
  local kind=$1 collection=$2 rkey=$3 json=$4 swap=${5-} method payload
  refuse_blobs "at://$did/$collection/$rkey" "$json"
  # PACE seconds between writes, so a long batch stays under the PDS's limits.
  if ((writes_done > 0)) && [[ "$PACE" != 0 ]]; then sleep "$PACE"; fi
  writes_done=$((writes_done + 1))
  entry_wrote=true
  payload=$(jq -n --arg repo "$did" --arg collection "$collection" --arg rkey "$rkey" \
    --argjson record "$json" --arg swap "$swap" \
    '{repo: $repo, collection: $collection, rkey: $rkey, record: $record}
     + (if $swap == "" then {} else {swapRecord: $swap} end)')
  case "$kind" in
    create) method=com.atproto.repo.createRecord ;;
    put) method=com.atproto.repo.putRecord ;;
  esac
  request POST "$pds/xrpc/$method" "$payload"
  ok || xrpc_error "writing at://$did/$collection/$rkey ($method)"
  written_uri=$(jq -r '.uri // empty' <<<"$body")
  written_cid=$(jq -r '.cid // empty' <<<"$body")
  [[ "$written_uri" == "at://$did/$collection/$rkey" && -n "$written_cid" ]] ||
    die "$method for at://$did/$collection/$rkey answered with uri ${written_uri:-none} and cid ${written_cid:-none}"
  echo "Wrote $written_uri ($written_cid)"
}

# ------------------------------------------------------------- plan ---------

plan_lines=()
failures=0
project_planned=false
project_action=""

# planned_nothing: true when the last plan writes nothing.
planned_nothing() {
  [[ "$project_action$manifest_action$version_action" == skipskipskip ]] || return 1
  local action
  for action in ${channel_actions[@]+"${channel_actions[@]}"}; do
    [[ "$action" == skip || "$action" == skip-backwards ]] || return 1
  done
}

note() { # action what [detail]
  local line
  line=$(printf '%-15s %s%s' "$1" "$2" "${3:+  ($3)}")
  plan_lines+=("$line")
  echo "$line"
}

show() { # json
  jq . <<<"$1" | sed 's/^/    /'
}

# Reads what is there and decides one action a record, without writing.
plan() {
  # Every planned record is checked for blobs before anything is read.
  local channel
  refuse_blobs "the project record" "$(project_record)"
  refuse_blobs "the manifest record" "$(manifest_record)"
  refuse_blobs "the version record" "$(version_record "$manifest_uri" "$PENDING_CID")"
  while read -r channel; do
    [[ -n "$channel" ]] || continue
    refuse_blobs "the $channel channel record" "$(channel_record "$channel" "$version_uri" "$PENDING_CID")"
  done <<<"$channels"

  echo "Plan for $PROJECT $VERSION in $did ($pds):"

  # Project: created if missing, otherwise left as it is. Once an earlier
  # release in this run has planned it, it is not read again.
  if [[ "$project_planned" == true ]]; then
    project_action=skip
    note skip "$(project_uri)" "planned by an earlier release"
  else
    get_record "$PROJECT_NSID" "$PROJECT"
    if [[ "$found" == true ]]; then
      project_action=skip
      note skip "$(project_uri)" "exists"
    else
      project_action=create
      note create "$(project_uri)"
      show "$(project_record)"
    fi
    project_planned=true
  fi

  # Manifest: immutable.
  local planned
  planned=$(manifest_record)
  get_record "$MANIFEST_NSID" "$manifest_rkey"
  manifest_cid=$PENDING_CID
  if [[ "$found" == false ]]; then
    manifest_action=create
    note create "$manifest_uri"
    show "$planned"
  elif same_json "$(jq .value <<<"$record")" "$planned"; then
    manifest_action=skip
    manifest_cid=$(jq -r .cid <<<"$record")
    note skip "$manifest_uri" "already published, identical"
  else
    manifest_action=fail
    failures=$((failures + 1))
    note fail "$manifest_uri" "already published with different contents; manifests are immutable"
    echo "    planned:"; show "$planned"
    echo "    published:"; show "$(jq .value <<<"$record")"
  fi

  # Version: immutable, and it names the manifest by CID.
  planned=$(version_record "$manifest_uri" "$manifest_cid")
  get_record "$VERSION_NSID" "$version_rkey"
  version_cid=""
  if [[ "$found" == false ]]; then
    version_action=create
    note create "$version_uri"
    show "$planned"
  elif same_json "$(jq .value <<<"$record")" "$planned"; then
    version_action=skip
    version_cid=$(jq -r .cid <<<"$record")
    note skip "$version_uri" "already published, identical"
  else
    version_action=fail
    failures=$((failures + 1))
    note fail "$version_uri" "already published with different contents; versions are immutable"
    echo "    planned:"; show "$planned"
    echo "    published:"; show "$(jq .value <<<"$record")"
  fi

  # Channels: forward only.
  channel_names=()
  channel_actions=()
  channel_swaps=()
  local rkey uri current_uri current_cid current_version target cmp
  while read -r channel; do
    [[ -n "$channel" ]] || continue
    rkey="$PROJECT.$channel"
    uri="at://$did/$CHANNEL_NSID/$rkey"
    get_record "$CHANNEL_NSID" "$rkey"
    channel_names+=("$channel")
    if [[ "$found" == false ]]; then
      channel_actions+=(create)
      channel_swaps+=("")
      note create "$uri" "-> $VERSION"
      show "$(channel_record "$channel" "$version_uri" "${version_cid:-$PENDING_CID}")"
      continue
    fi
    current_cid=$(jq -r .cid <<<"$record")
    current_uri=$(jq -r '.value.version.uri // empty' <<<"$record")
    if [[ "$current_uri" == "$version_uri" && -n "$version_cid" &&
      "$(jq -r '.value.version.cid // empty' <<<"$record")" == "$version_cid" ]]; then
      channel_actions+=(skip)
      channel_swaps+=("")
      note skip "$uri" "already at $VERSION"
      continue
    fi
    # What the channel points at now, read from that version record. If that
    # can't be read, its version is unknown, and moving the channel could take
    # it backwards: that is a planned failure for a person to settle.
    current_version=""
    target="${current_uri:-no version}"
    if [[ "$current_uri" =~ ^at://([^/]+)/([^/]+)/([^/]+)$ ]]; then
      get_record "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}"
      if [[ "$found" == true ]]; then
        current_version=$(jq -r '.value.version // empty' <<<"$record")
      fi
    fi
    local problem=""
    if [[ -z "$current_version" ]]; then
      problem="points at $target, which is not a readable version record"
    elif ! helper semver-check "$current_version" 2>/dev/null; then
      problem="points at $target, whose version $current_version is not SemVer"
    fi
    if [[ -n "$problem" ]]; then
      channel_actions+=(fail)
      channel_swaps+=("")
      failures=$((failures + 1))
      note fail "$uri" "$problem"
      echo "::error::the $channel channel ($uri) $problem, so the action can't tell whether $VERSION is newer and won't move it. Fix it by hand: restore $target, or point the channel at the right version with putRecord, or delete the channel record so a rerun creates it at $VERSION."
      continue
    fi
    cmp=$(helper semver-cmp "$current_version" "$VERSION")
    if [[ "$cmp" == 1 ]]; then
      channel_actions+=(skip-backwards)
      channel_swaps+=("")
      note skip-backwards "$uri" "at $current_version, newer than $VERSION; left there"
      continue
    fi
    channel_actions+=(move)
    channel_swaps+=("$current_cid")
    note move "$uri" "$current_version -> $VERSION, swapping $current_cid"
    show "$(channel_record "$channel" "$version_uri" "${version_cid:-$PENDING_CID}")"
  done <<<"$channels"
}

# ----------------------------------------------------------- execute --------

execute() {
  if [[ "$project_action" == create ]]; then
    write_record create "$PROJECT_NSID" "$PROJECT" "$(project_record)"
  fi
  if [[ "$manifest_action" == create ]]; then
    write_record create "$MANIFEST_NSID" "$manifest_rkey" "$(manifest_record)"
    manifest_cid=$written_cid
  fi
  if [[ "$version_action" == create ]]; then
    write_record create "$VERSION_NSID" "$version_rkey" "$(version_record "$manifest_uri" "$manifest_cid")"
    version_cid=$written_cid
  fi
  local i channel
  for i in ${channel_names[@]+"${!channel_names[@]}"}; do
    channel=${channel_names[$i]}
    case "${channel_actions[$i]}" in
      create)
        write_record create "$CHANNEL_NSID" "$PROJECT.$channel" \
          "$(channel_record "$channel" "$version_uri" "$version_cid")" ;;
      move)
        write_record put "$CHANNEL_NSID" "$PROJECT.$channel" \
          "$(channel_record "$channel" "$version_uri" "$version_cid")" "${channel_swaps[$i]}" ;;
      skip-backwards)
        echo "::notice::the $channel channel stays on a newer version than $VERSION" ;;
    esac
  done
}

# -------------------------------------------------------------- main --------

rkey_ok() { [[ "$1" =~ ^[A-Za-z0-9._:~-]+$ && ${#1} -le 512 && "$1" != . && "$1" != .. ]]; }

SINGLE_INPUTS=(VERSION REPOSITORY COMMIT TAG CHANGELOG_URL PUBLISHED_AT CHANNELS)
ENTRY_KEYS='["version", "repository", "commit", "tag", "changelog-url", "published-at", "channels"]'

# check_releases_file: dies unless RELEASES names a file holding a non-empty
# array of entries with only the known keys.
check_releases_file() {
  [[ -f "$RELEASES" ]] || die "releases: $RELEASES is not a file"
  jq -e --argjson keys "$ENTRY_KEYS" '
    type == "array" and length > 0 and all(.[];
      type == "object" and (keys - $keys == [])
      and all(to_entries[]; (.value | type) == "string"
        or (.key == "channels" and (.value | type) == "array" and all(.value[]; type == "string"))))' \
    "$RELEASES" >/dev/null 2>&1 ||
    die "releases: $RELEASES must hold a non-empty JSON array of objects with only the keys $(jq -r 'join(", ")' <<<"$ENTRY_KEYS"), each a string (channels may be an array of strings)"
}

# releases_json: every release to publish, as a JSON array of entries with
# every key a string. From the checked RELEASES file, or one entry made of the
# single-release inputs.
releases_json() {
  if [[ -z "${RELEASES:-}" ]]; then
    jq -n '[{version: env.VERSION, repository: env.REPOSITORY, commit: env.COMMIT, tag: env.TAG,
      "changelog-url": env.CHANGELOG_URL, "published-at": env.PUBLISHED_AT, channels: env.CHANNELS}
      | map_values(. // "")]'
  else
    jq -c '[.[] | {version, repository, commit, tag, "changelog-url", "published-at",
      channels: (.channels | if type == "array" then join("\n") else . end)} | map_values(. // "")]' "$RELEASES"
  fi
}

# load_release INDEX: sets the per-release globals from entry INDEX of
# $releases, checking each. Reads and writes nothing.
load_release() {
  local entry where field
  entry=$(jq -c ".[$1]" <<<"$releases")
  if [[ -n "${RELEASES:-}" ]]; then where="releases[$1]: "; else where=""; fi
  for field in version repository commit published-at; do
    [[ -n "$(jq -r --arg f "$field" '.[$f]' <<<"$entry")" ]] ||
      die "${where}the $field ${where:+field}${where:-input} is required"
  done
  VERSION=$(jq -r .version <<<"$entry")
  REPOSITORY=$(jq -r .repository <<<"$entry")
  COMMIT=$(jq -r .commit <<<"$entry")
  CHANGELOG_URL=$(jq -r '.["changelog-url"]' <<<"$entry")
  PUBLISHED_AT=$(jq -r '.["published-at"]' <<<"$entry")
  local tag
  tag=$(jq -r .tag <<<"$entry")

  VERSION="${VERSION#v}"
  helper semver-check "$VERSION" 2>/dev/null || die "${where}version $VERSION is not a SemVer version"
  [[ "$VERSION" != *+* ]] || die "${where}version $VERSION has build metadata, which a record key cannot hold"
  COMMIT=$(tr '[:upper:]' '[:lower:]' <<<"$COMMIT")
  [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "${where}commit must be a full 40-character SHA-1, not $COMMIT"
  tag="${tag:-v$VERSION}"
  if [[ "$tag" == refs/* ]]; then GIT_REF=$tag; else GIT_REF="refs/tags/$tag"; fi
  manifest_rkey=$(helper tid "$PUBLISHED_AT" 2>&1) || die "${where}published-at: $manifest_rkey"
  version_rkey="$PROJECT.$VERSION"
  channels=$(list "$(jq -r .channels <<<"$entry")")
  local channel
  while read -r channel; do
    [[ -n "$channel" ]] || continue
    rkey_ok "$PROJECT.$channel" || die "${where}channel $channel can't be part of a record key (letters, digits and . _ : ~ - only)"
  done <<<"$channels"
  if [[ -n "$channels" && $(sort <<<"$channels" | uniq -d) ]]; then
    die "${where}channels lists $(sort <<<"$channels" | uniq -d | head -n1) twice"
  fi
  if [[ -n "${did:-}" ]]; then
    manifest_uri="at://$did/$MANIFEST_NSID/$manifest_rkey"
    version_uri="at://$did/$VERSION_NSID/$version_rkey"
  fi
}

main() {
  : "${IDENTIFIER:?the identifier input is required}"
  : "${PROJECT:?the project input is required}"
  [[ "${PUBLISHER_DID:-}" == did:* ]] ||
    die "the publisher-did input is required: the DID release records must be written by"
  PLC_URL="${PLC_URL:-https://plc.directory}"
  DRY_RUN="${DRY_RUN:-true}"
  [[ "$DRY_RUN" == true || "$DRY_RUN" == false ]] || die "dry-run must be true or false, not $DRY_RUN"
  PACE="${PACE:-2}"
  [[ "$PACE" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "pace must be a number of seconds, not $PACE"

  if [[ -n "${PASSWORD:-}" ]]; then
    echo "::add-mask::$PASSWORD"
  elif [[ "$DRY_RUN" != true ]]; then
    die "publishing needs the password input: an app password for $IDENTIFIER"
  fi
  rkey_ok "$PROJECT" || die "project $PROJECT can't be part of a record key (letters, digits and . _ : ~ - only)"

  if [[ -n "${RELEASES:-}" ]]; then
    local name mixed=""
    for name in "${SINGLE_INPUTS[@]}"; do
      if [[ -n "${!name:-}" ]]; then mixed+=" $(tr '[:upper:]_' '[:lower:]-' <<<"$name")"; fi
    done
    [[ -z "$mixed" ]] || die "releases replaces the single-release inputs; leave these empty:$mixed"
    check_releases_file
  fi

  # Every entry is checked before anything is read, so a bad one late in a
  # batch stops the run before the first write.
  did=""
  releases=$(releases_json)
  local count i keys=""
  count=$(jq length <<<"$releases")
  for ((i = 0; i < count; i++)); do
    load_release "$i"
    keys+="$manifest_rkey $VERSION"$'\n'
  done
  local clash
  clash=$(cut -d' ' -f1 <<<"$keys" | grep -v '^$' | sort | uniq -d | head -n1)
  [[ -z "$clash" ]] || die "releases: two entries share a published-at, so they would share the manifest key $clash"

  tmp=$(mktemp -d)
  trap cleanup EXIT

  HANDLE=""
  resolve_did "$IDENTIFIER"
  if [[ "$did" != "$PUBLISHER_DID" ]]; then
    die "$IDENTIFIER resolves to $did, not the expected publisher $PUBLISHER_DID; nothing was read or written"
  fi
  did_document "$did"
  if [[ -n "$HANDLE" ]] && ! jq -e --arg aka "at://$HANDLE" '(.alsoKnownAs // []) | index($aka)' <<<"$doc" >/dev/null; then
    die "$did's DID document does not name $HANDLE as its handle"
  fi
  pds=$(pds_endpoint)
  [[ "$pds" == https://* ]] || die "$did's DID document names no #atproto_pds endpoint"
  pds="${pds%/}"

  if [[ "$DRY_RUN" != true ]]; then
    sign_in
  fi

  local heading="### release-publish: $PROJECT"
  if ((count == 1)); then heading+=" $(jq -r '.[0].version | ltrimstr("v")' <<<"$releases")"; else heading+=", $count releases"; fi
  if [[ "$DRY_RUN" == true ]]; then heading+=" (dry run)"; fi
  summary "$heading"
  summary '```'

  local written=0 skipped=0 line before
  for ((i = 0; i < count; i++)); do
    load_release "$i"
    if ((count > 1)); then echo "== release $((i + 1)) of $count"; fi
    before=$failures
    plan
    if ((failures > before)) && [[ "$DRY_RUN" != true ]]; then
      for line in ${plan_lines[@]+"${plan_lines[@]}"}; do summary "$line"; done
      summary '```'
      local done_note=""
      if ((i > 0)); then done_note=" (the $i release(s) before it are published: $written written, $skipped already there)"; fi
      die "$VERSION: $((failures - before)) record(s) can't be published as planned (see the fail lines above); stopped before writing anything for it$done_note"
    fi
    if [[ "$DRY_RUN" == true ]]; then
      if ((failures == before)) && planned_nothing; then skipped=$((skipped + 1)); fi
      continue
    fi
    entry_wrote=false
    execute
    if [[ "$entry_wrote" == true ]]; then written=$((written + 1)); else skipped=$((skipped + 1)); fi
  done
  for line in ${plan_lines[@]+"${plan_lines[@]}"}; do summary "$line"; done
  summary '```'

  if ((failures > 0)); then
    die "$failures record(s) can't be published as planned; see the fail lines above"
  fi
  if [[ "$DRY_RUN" == true ]]; then echo "Dry run: nothing was written."; fi
  output version-uri "$version_uri"
  output version-cid "$version_cid"
  if ((written > 0)); then output published true; else output published false; fi
  output count-written "$written"
  output count-skipped "$skipped"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
