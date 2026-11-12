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
#   PUBLISHER_DID  the DID IDENTIFIER must resolve to; empty skips the check
#   PROJECT, VERSION, REPOSITORY, COMMIT   (required)
#   TAG            the git tag; default v<version>
#   CHANGELOG_URL  optional
#   PUBLISHED_AT   RFC 3339 (required); gives the manifest's key
#   CHANNELS       channel names, comma or newline separated; may be empty
#   DRY_RUN        true (default) or false
#   PLC_URL        default https://plc.directory
# Writes version-uri, version-cid and published to $GITHUB_OUTPUT, and the
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
  if jq -e '[.. | objects | select(."$type" == "blob"
      or ((.ref | type) == "object" and (.ref | has("$link"))))] | length > 0' <<<"$2" >/dev/null; then
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
write_record() {
  local kind=$1 collection=$2 rkey=$3 json=$4 swap=${5-} method payload
  refuse_blobs "at://$did/$collection/$rkey" "$json"
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

  # Project: created if missing, otherwise left as it is.
  get_record "$PROJECT_NSID" "$PROJECT"
  if [[ "$found" == true ]]; then
    project_action=skip
    note skip "$(project_uri)" "exists"
  else
    project_action=create
    note create "$(project_uri)"
    show "$(project_record)"
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
    # What the channel points at now, read from that version record.
    current_version=""
    if [[ "$current_uri" =~ ^at://([^/]+)/([^/]+)/([^/]+)$ ]]; then
      target=$current_uri
      get_record "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}"
      if [[ "$found" == true ]]; then
        current_version=$(jq -r '.value.version // empty' <<<"$record")
      fi
    else
      target="${current_uri:-nothing}"
    fi
    if [[ -n "$current_version" ]] && ! helper semver-check "$current_version" 2>/dev/null; then
      die "the $channel channel points at $target, whose version $current_version is not SemVer; fix it by hand"
    fi
    if [[ -n "$current_version" ]]; then
      cmp=$(helper semver-cmp "$current_version" "$VERSION")
      if [[ "$cmp" == 1 ]]; then
        channel_actions+=(skip-backwards)
        channel_swaps+=("")
        note skip-backwards "$uri" "at $current_version, newer than $VERSION; left there"
        continue
      fi
    else
      echo "::warning::the $channel channel points at $target, which is not a readable version record; moving it to $VERSION"
    fi
    channel_actions+=(move)
    channel_swaps+=("$current_cid")
    note move "$uri" "${current_version:-?} -> $VERSION, swapping $current_cid"
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
  published=false
  if [[ "$version_action" == create ]]; then
    write_record create "$VERSION_NSID" "$version_rkey" "$(version_record "$manifest_uri" "$manifest_cid")"
    version_cid=$written_cid
    published=true
  fi
  local i channel
  for i in "${!channel_names[@]}"; do
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

main() {
  : "${IDENTIFIER:?the identifier input is required}"
  : "${PROJECT:?the project input is required}"
  : "${VERSION:?the version input is required}"
  : "${REPOSITORY:?the repository input is required}"
  : "${COMMIT:?the commit input is required}"
  : "${PUBLISHED_AT:?the published-at input is required}"
  PLC_URL="${PLC_URL:-https://plc.directory}"
  CHANGELOG_URL="${CHANGELOG_URL:-}"
  local dry_run="${DRY_RUN:-true}"
  [[ "$dry_run" == true || "$dry_run" == false ]] || die "dry-run must be true or false, not $dry_run"

  if [[ -n "${PASSWORD:-}" ]]; then
    echo "::add-mask::$PASSWORD"
  elif [[ "$dry_run" != true ]]; then
    die "publishing needs the password input: an app password for $IDENTIFIER"
  fi

  VERSION="${VERSION#v}"
  helper semver-check "$VERSION" 2>/dev/null || die "version $VERSION is not a SemVer version"
  [[ "$VERSION" != *+* ]] || die "version $VERSION has build metadata, which a record key cannot hold"
  rkey_ok "$PROJECT" || die "project $PROJECT can't be part of a record key (letters, digits and . _ : ~ - only)"
  COMMIT=$(tr '[:upper:]' '[:lower:]' <<<"$COMMIT")
  [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "commit must be a full 40-character SHA-1, not $COMMIT"
  local tag="${TAG:-v$VERSION}"
  if [[ "$tag" == refs/* ]]; then GIT_REF=$tag; else GIT_REF="refs/tags/$tag"; fi
  manifest_rkey=$(helper tid "$PUBLISHED_AT" 2>&1) || die "published-at: $manifest_rkey"
  version_rkey="$PROJECT.$VERSION"
  channels=$(list "${CHANNELS:-}")
  local channel
  while read -r channel; do
    [[ -n "$channel" ]] || continue
    rkey_ok "$PROJECT.$channel" || die "channel $channel can't be part of a record key (letters, digits and . _ : ~ - only)"
  done <<<"$channels"
  if [[ -n "$channels" && $(sort <<<"$channels" | uniq -d) ]]; then
    die "channels lists $(sort <<<"$channels" | uniq -d | head -n1) twice"
  fi

  tmp=$(mktemp -d)
  trap cleanup EXIT

  HANDLE=""
  resolve_did "$IDENTIFIER"
  if [[ -n "${PUBLISHER_DID:-}" && "$did" != "$PUBLISHER_DID" ]]; then
    die "$IDENTIFIER resolves to $did, not the expected publisher $PUBLISHER_DID; nothing was read or written"
  fi
  did_document "$did"
  if [[ -n "$HANDLE" ]] && ! jq -e --arg aka "at://$HANDLE" '(.alsoKnownAs // []) | index($aka)' <<<"$doc" >/dev/null; then
    die "$did's DID document does not name $HANDLE as its handle"
  fi
  pds=$(pds_endpoint)
  [[ "$pds" == https://* ]] || die "$did's DID document names no #atproto_pds endpoint"
  pds="${pds%/}"

  manifest_uri="at://$did/$MANIFEST_NSID/$manifest_rkey"
  version_uri="at://$did/$VERSION_NSID/$version_rkey"

  if [[ "$dry_run" != true ]]; then
    sign_in
  fi

  plan

  local heading="### release-publish: $PROJECT $VERSION"
  if [[ "$dry_run" == true ]]; then heading+=" (dry run)"; fi
  summary "$heading"
  summary '```'
  local line
  for line in "${plan_lines[@]}"; do summary "$line"; done
  summary '```'

  if ((failures > 0)); then
    die "$failures record(s) already published with different contents; nothing was written"
  fi

  if [[ "$dry_run" == true ]]; then
    echo "Dry run: nothing was written."
    output version-uri "$version_uri"
    output version-cid "$version_cid"
    output published false
    return
  fi

  execute
  output version-uri "$version_uri"
  output version-cid "$version_cid"
  output published "$published"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
