#!/usr/bin/env bash
# release-publish/publish.sh against stub `curl` and `dig` commands. The curl
# stub is a small fake PDS, PLC directory and handle host that keeps its repo
# in files, so a second run sees what the first one wrote. release.py runs for
# real: it is pure.
#
# Each test runs in a subshell of its own, with its own $WORK, by design.
# Single-quoted JSON holding $type is literal, by design.
# shellcheck disable=SC2031,SC2016
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib.sh
. "$here/lib.sh"
publish="$here/../release-publish/publish.sh"
helper="$here/../release-publish/release.py"

DID="did:plc:publisher"
HANDLE="publisher.test"
PDS="https://pds.test"
COMMIT_SHA="0123456789abcdef0123456789abcdef01234567"
PUBLISHED_AT="2026-11-12T00:00:00Z"
TID="3n235z4as2222" # $PUBLISHED_AT, checked against @atproto/common-web's TID.fromTime
PROJECT_URI="at://$DID/software.release.project/happyview"
MANIFEST_URI="at://$DID/software.release.manifest/$TID"
VERSION_URI="at://$DID/software.release.version/happyview.2.17.4"

# Stubs in $WORK/bin, answering from files:
#   dns/<name>              the TXT answer for <name>, as dig +short prints it
#   web/<host><path>        a body for GET https://<host><path> (DID documents,
#                           .well-known/atproto-did)
#   repo/<did>/<collection>/<rkey>.json   a stored record: {uri, cid, value}
#   fail/<xrpc method>      "<status>" on the first line, then the body to send
# Every curl call appends one JSON line to requests.jsonl:
#   {argv, method, url, xrpc, auth, body}
stub_tools() {
  mkdir -p "$WORK/bin" "$WORK/dns" "$WORK/web" "$WORK/repo" "$WORK/fail"
  cat > "$WORK/bin/curl" <<STUB
#!/usr/bin/env python3
import json, os, sys, urllib.parse
work = "$WORK"
argv = sys.argv[1:]
method, out, headers, data, url = "GET", None, [], None, None
i = 0
while i < len(argv):
    a = argv[i]
    if a == "-X": method = argv[i + 1]; i += 2; continue
    if a == "-o": out = argv[i + 1]; i += 2; continue
    if a == "-w": i += 2; continue
    if a == "-H":
        h = argv[i + 1]
        headers += open(h[1:]).read().splitlines() if h.startswith("@") else [h]
        i += 2; continue
    if a == "--data-binary":
        data = sys.stdin.read() if argv[i + 1] == "@-" else argv[i + 1]; i += 2; continue
    if a.startswith("-"): i += 1; continue
    url = a; i += 1
auth = next((h.split(":", 1)[1].strip() for h in headers if h.lower().startswith("authorization:")), "")
parts = urllib.parse.urlsplit(url)
query = dict(urllib.parse.parse_qsl(parts.query))
xrpc = parts.path[len("/xrpc/"):] if parts.path.startswith("/xrpc/") else ""
body = json.loads(data) if data else None
with open(os.path.join(work, "requests.jsonl"), "a") as log:
    log.write(json.dumps({"argv": argv, "method": method, "url": url, "xrpc": xrpc, "auth": auth, "body": body}) + "\n")

def reply(status, payload):
    with open(out, "w") as f:
        f.write(payload if isinstance(payload, str) else json.dumps(payload))
    sys.stdout.write(str(status))
    sys.exit(0)

def err(status, name, message):
    reply(status, {"error": name, "message": message})

def path(repo, collection, rkey):
    return os.path.join(work, "repo", repo, collection, rkey + ".json")

def next_cid(collection, rkey):
    counter = os.path.join(work, "cid-counter")
    n = int(open(counter).read()) + 1 if os.path.exists(counter) else 1
    open(counter, "w").write(str(n))
    return "bafy%d%s" % (n, rkey.replace(".", "").replace(":", "")[:8])

fail = os.path.join(work, "fail", xrpc) if xrpc else None
if fail and os.path.exists(fail):
    status, _, payload = open(fail).read().partition("\n")
    reply(int(status), payload)

if parts.netloc != "pds.test":
    web = os.path.join(work, "web", parts.netloc + "/" + parts.path.lstrip("/"))
    if os.path.isfile(web): reply(200, open(web).read())
    reply(404, "not found")

if xrpc == "com.atproto.server.createSession":
    if body.get("password") != "app-password-secret":
        err(401, "AuthenticationRequired", "Invalid identifier or password")
    signed_in = os.path.join(work, "session-did")
    session_did = open(signed_in).read().strip() if os.path.exists(signed_in) else "$DID"
    reply(200, {"did": session_did, "handle": "$HANDLE", "accessJwt": "access-jwt-secret", "refreshJwt": "refresh-jwt-secret"})

if xrpc == "com.atproto.repo.getRecord":
    p = path(query["repo"], query["collection"], query["rkey"])
    if not os.path.exists(p):
        err(400, "RecordNotFound", "Could not locate record")
    reply(200, open(p).read())

if xrpc in ("com.atproto.repo.createRecord", "com.atproto.repo.putRecord"):
    if auth != "Bearer access-jwt-secret":
        err(401, "AuthenticationRequired", "Authentication Required")
    p = path(body["repo"], body["collection"], body["rkey"])
    exists = os.path.exists(p)
    if xrpc.endswith("createRecord") and exists:
        err(400, "InvalidRequest", "Record already exists")
    if "swapRecord" in body:
        current = json.load(open(p))["cid"] if exists else None
        if body["swapRecord"] != current:
            err(400, "InvalidSwap", "Record was at %s" % current)
    uri = "at://%s/%s/%s" % (body["repo"], body["collection"], body["rkey"])
    stored = {"uri": uri, "cid": next_cid(body["collection"], body["rkey"]), "value": body["record"]}
    os.makedirs(os.path.dirname(p), exist_ok=True)
    json.dump(stored, open(p, "w"))
    reply(200, {"uri": uri, "cid": stored["cid"], "commit": {"cid": "bafycommit", "rev": "rev"}})

err(400, "MethodNotImplemented", xrpc or url)
STUB
  cat > "$WORK/bin/sleep" <<STUB
#!/usr/bin/env bash
echo "sleep \$*" >> "$WORK/sleep.log"
STUB
  chmod +x "$WORK/bin/sleep"
  cat > "$WORK/bin/dig" <<STUB
#!/usr/bin/env bash
echo "dig \$*" >> "$WORK/dig.log"
name="\${*: -1}"
[[ -f "$WORK/dns/\$name" ]] && cat "$WORK/dns/\$name"
exit 0
STUB
  chmod +x "$WORK/bin/curl" "$WORK/bin/dig"
  : > "$WORK/requests.jsonl"

  echo "\"did=$DID\"" > "$WORK/dns/_atproto.$HANDLE"
  mkdir -p "$WORK/web/plc.directory"
  did_doc "$DID" "$HANDLE" > "$WORK/web/plc.directory/$DID"
}

did_doc() { # did handle
  jq -n --arg did "$1" --arg handle "$2" --arg pds "$PDS" '{
    id: $did, alsoKnownAs: ["at://\($handle)"],
    service: [
      {id: "#other", type: "Other", serviceEndpoint: "https://elsewhere.test"},
      {id: "#atproto_pds", type: "AtprotoPersonalDataServer", serviceEndpoint: $pds}
    ]}'
}

# seed COLLECTION RKEY CID VALUE-JSON: a record already in the repo.
seed() {
  mkdir -p "$WORK/repo/$DID/$1"
  jq -n --arg uri "at://$DID/$1/$2" --arg cid "$3" --argjson value "$4" \
    '{uri: $uri, cid: $cid, value: $value}' > "$WORK/repo/$DID/$1/$2.json"
}

seed_version() { # version cid
  seed software.release.version "happyview.$1" "$2" "$(jq -n --arg v "$1" --arg p "$PROJECT_URI" \
    '{"$type": "software.release.version", project: $p, version: $v, manifest: {uri: "at://x/y/z", cid: "bafyold"}}')"
}

seed_channel() { # channel version cid
  seed software.release.channel "happyview.$1" "$3" "$(jq -n --arg c "$1" --arg v "$2" --arg p "$PROJECT_URI" --arg d "$DID" \
    '{"$type": "software.release.channel", project: $p, channel: $c,
      version: {uri: "at://\($d)/software.release.version/happyview.\($v)", cid: "bafyversion\($v)"}}')"
}

# Runs publish.sh with a full set of inputs, overridden by NAME=value args.
run_publish() {
  env PATH="$WORK/bin:$PATH" GITHUB_OUTPUT="$WORK/output" GITHUB_STEP_SUMMARY="$WORK/summary" \
    IDENTIFIER="$HANDLE" PASSWORD=app-password-secret PUBLISHER_DID="$DID" \
    PROJECT=happyview VERSION=2.17.4 REPOSITORY=https://github.com/example/happyview.git \
    COMMIT="$COMMIT_SHA" TAG=v2.17.4 CHANGELOG_URL=https://github.com/example/happyview/releases/tag/v2.17.4 \
    PUBLISHED_AT="$PUBLISHED_AT" CHANNELS=v2 DRY_RUN=false PACE=0 "$@" "$publish"
}

# Write calls, in order, as "<xrpc> <collection>/<rkey>".
writes() {
  jq -r 'select(.xrpc | test("create|put")) | select(.xrpc != "com.atproto.server.createSession")
    | "\(.xrpc) \(.body.collection)/\(.body.rkey)"' "$WORK/requests.jsonl"
}

stored() { # collection rkey
  cat "$WORK/repo/$DID/$1/$2.json"
}

output_of() { grep "^$1=" "$WORK/output" | cut -d= -f2-; }

# ---------------------------------------------------------- release.py ----

test_tid_is_the_known_value_for_a_timestamp() {
  assert_eq "$TID" "$(python3 "$helper" tid "$PUBLISHED_AT")"
  # (1794441600123456 << 10) | 0, from @atproto/common-web's TID.fromTime.
  assert_eq 3n235z4ekm222 "$(python3 "$helper" tid 2026-11-12T00:00:00.123456Z)"
  # The same instant in another zone, with a seventh digit that is dropped.
  assert_eq 3n235z4ekm222 "$(python3 "$helper" tid 2026-11-11T19:00:00.1234567-05:00)"
  assert_eq 2222222222222 "$(python3 "$helper" tid 1970-01-01T00:00:00Z)"
}

test_tid_is_deterministic_and_its_top_bit_is_zero() {
  local a b
  a=$(python3 "$helper" tid 2025-03-04T05:06:07.890Z)
  b=$(python3 "$helper" tid 2025-03-04T05:06:07.890Z)
  assert_eq "$a" "$b" "same timestamp"
  assert_eq 13 "${#a}" "length"
  # The first character holds the top 5 bits; with the top one 0 it is one
  # of the first 16 letters of the alphabet.
  [[ "${a:0:1}" == [234567abcdefghij] ]] || fail "top bit set: $a"
  # Its clock id is 0: the last two characters are both 2 (all zero bits).
  assert_eq 22 "${a: -2}" "clock id"
}

test_tid_refuses_what_is_not_rfc_3339() {
  python3 "$helper" tid 2026-11-12 2>/dev/null && fail "accepted a date"
  python3 "$helper" tid 2026-02-30T00:00:00Z 2>/dev/null && fail "accepted Feb 30"
  python3 "$helper" tid 1969-12-31T23:59:59Z 2>/dev/null && fail "accepted a time before 1970"
  return 0
}

test_semver_ordering() {
  local pair higher lower
  for pair in "3.0.0-alpha.10 3.0.0-alpha.9" "3.0.0 3.0.0-beta.12" "2.17.10 2.17.9" \
    "1.0.0-alpha.1 1.0.0-alpha" "1.0.0-alpha.beta 1.0.0-alpha.1" "1.0.0-beta 1.0.0-alpha.beta" \
    "1.0.0-beta.2 1.0.0-beta" "1.0.0-beta.11 1.0.0-beta.2" "1.0.0-rc.1 1.0.0-beta.11" \
    "1.0.0 1.0.0-rc.1" "3.0.0-alpha.1 2.99.99" "10.0.0 9.0.0"; do
    read -r higher lower <<<"$pair"
    assert_eq 1 "$(python3 "$helper" semver-cmp "$higher" "$lower")" "$higher > $lower"
    assert_eq -1 "$(python3 "$helper" semver-cmp "$lower" "$higher")" "$lower < $higher"
  done
  assert_eq 0 "$(python3 "$helper" semver-cmp 2.17.4 2.17.4)"
  assert_eq 0 "$(python3 "$helper" semver-cmp 2.17.4+a 2.17.4+b)" "build metadata"
  python3 "$helper" semver-check 2.17 2>/dev/null && fail "accepted 2.17"
  python3 "$helper" semver-check 01.2.3 2>/dev/null && fail "accepted a leading zero"
  return 0
}

# ------------------------------------------------------------- publish ----

test_a_fresh_publish_writes_project_manifest_version_channel_in_order() {
  stub_tools
  local out
  out=$(run_publish CHANNELS="v2,latest" 2>&1) || fail "publish failed: $out"
  assert_eq "com.atproto.repo.createRecord software.release.project/happyview
com.atproto.repo.createRecord software.release.manifest/$TID
com.atproto.repo.createRecord software.release.version/happyview.2.17.4
com.atproto.repo.createRecord software.release.channel/happyview.v2
com.atproto.repo.createRecord software.release.channel/happyview.latest" "$(writes)" "writes"

  assert_eq '{"$type":"software.release.project","name":"happyview"}' \
    "$(stored software.release.project happyview | jq -c .value)" "project"
  assert_eq "{\"\$type\":\"software.release.manifest\",\"project\":\"$PROJECT_URI\",\"artifacts\":[{\"\$type\":\"software.release.defs#gitRevision\",\"repository\":\"https://github.com/example/happyview.git\",\"commit\":{\"algorithm\":\"sha1\",\"digest\":\"$COMMIT_SHA\"},\"ref\":\"refs/tags/v2.17.4\"}]}" \
    "$(stored software.release.manifest "$TID" | jq -c .value)" "manifest"

  local manifest_cid version version_cid channel
  manifest_cid=$(stored software.release.manifest "$TID" | jq -r .cid)
  version=$(stored software.release.version happyview.2.17.4)
  version_cid=$(jq -r .cid <<<"$version")
  assert_eq "{\"\$type\":\"software.release.version\",\"project\":\"$PROJECT_URI\",\"version\":\"2.17.4\",\"changelog\":\"https://github.com/example/happyview/releases/tag/v2.17.4\",\"manifest\":{\"uri\":\"$MANIFEST_URI\",\"cid\":\"$manifest_cid\"}}" \
    "$(jq -c .value <<<"$version")" "version"
  channel=$(stored software.release.channel happyview.v2 | jq -c .value)
  assert_eq "{\"\$type\":\"software.release.channel\",\"project\":\"$PROJECT_URI\",\"channel\":\"v2\",\"version\":{\"uri\":\"$VERSION_URI\",\"cid\":\"$version_cid\"}}" \
    "$channel" "channel"

  assert_eq "$VERSION_URI" "$(output_of version-uri)"
  assert_eq "$version_cid" "$(output_of version-cid)"
  assert_eq true "$(output_of published)"
}

test_a_rerun_skips_everything() {
  stub_tools
  run_publish >/dev/null 2>&1 || fail "first publish failed"
  : > "$WORK/requests.jsonl"
  rm "$WORK/output"
  local out
  out=$(run_publish 2>&1) || fail "rerun failed: $out"
  assert_eq "" "$(writes)" "writes"
  assert_contains "$out" "skip            $MANIFEST_URI"
  assert_contains "$out" "already at 2.17.4"
  assert_eq false "$(output_of published)"
  assert_eq "$(stored software.release.version happyview.2.17.4 | jq -r .cid)" "$(output_of version-cid)"
}

test_a_dry_run_reads_and_prints_but_never_signs_in_or_writes() {
  stub_tools
  local out
  out=$(run_publish DRY_RUN=true PASSWORD= 2>&1) || fail "dry run failed: $out"
  assert_eq "" "$(jq -r 'select(.method != "GET") | .url' "$WORK/requests.jsonl")" "non-GET calls"
  assert_eq "" "$(jq -r 'select(.auth != "") | .url' "$WORK/requests.jsonl")" "authenticated calls"
  assert_contains "$out" "create          $MANIFEST_URI"
  assert_contains "$out" '"digest": "'"$COMMIT_SHA"'"'
  assert_contains "$out" '"cid": "<cid once created>"'
  assert_contains "$out" "Dry run: nothing was written."
  assert_eq false "$(output_of published)"
  assert_eq "$VERSION_URI" "$(output_of version-uri)"
  [[ ! -d "$WORK/repo/$DID" ]] || fail "the repo changed"
}

test_dry_run_is_the_default() {
  stub_tools
  local out
  out=$(run_publish DRY_RUN= 2>&1) || fail "dry run failed: $out"
  assert_eq "" "$(writes)" "writes"
  assert_not_contains "$(jq -r .xrpc "$WORK/requests.jsonl")" createSession
}

test_a_dry_run_reports_a_mismatch_and_fails() {
  stub_tools
  seed software.release.manifest "$TID" bafyother '{"$type": "software.release.manifest", "project": "x", "artifacts": []}'
  local out
  out=$(run_publish DRY_RUN=true 2>&1) && fail "expected failure"
  assert_contains "$out" "fail            $MANIFEST_URI"
  assert_contains "$out" "::error::"
}

test_a_publisher_mismatch_fails_before_anything_else() {
  stub_tools
  local out
  out=$(run_publish PUBLISHER_DID=did:plc:someoneelse 2>&1) && fail "expected failure"
  assert_contains "$out" "::error::"
  assert_contains "$out" "did:plc:someoneelse"
  assert_contains "$out" "$DID"
  assert_eq "" "$(jq -r 'select(.url | startswith("https://pds.test")) | .url' "$WORK/requests.jsonl")" "PDS calls"
}

test_publisher_did_is_required() {
  stub_tools
  local out
  out=$(run_publish PUBLISHER_DID= 2>&1) && fail "expected failure"
  assert_contains "$out" "::error::the publisher-did input is required"
  assert_eq "" "$(cat "$WORK/requests.jsonl" 2>/dev/null)" "calls"
}

test_a_session_for_another_account_fails_without_writing() {
  stub_tools
  echo did:plc:someoneelse > "$WORK/session-did"
  local out
  out=$(run_publish 2>&1) && fail "expected failure"
  assert_contains "$out" "::error::signed in as did:plc:someoneelse, not $DID"
  assert_eq "" "$(writes)" "writes"
}

test_a_manifest_mismatch_fails_without_writing() {
  stub_tools
  seed software.release.manifest "$TID" bafyother "$(jq -n --arg p "$PROJECT_URI" '{
    "$type": "software.release.manifest", project: $p,
    artifacts: [{"$type": "software.release.defs#gitRevision", repository: "https://github.com/example/happyview.git",
      commit: {algorithm: "sha1", digest: "ffffffffffffffffffffffffffffffffffffffff"}, ref: "refs/tags/v2.17.4"}]}')"
  local out
  out=$(run_publish 2>&1) && fail "expected failure"
  assert_contains "$out" "::error::"
  assert_contains "$out" "$MANIFEST_URI"
  assert_contains "$out" "immutable"
  assert_eq "" "$(writes)" "writes"
}

test_a_version_mismatch_fails_without_writing() {
  stub_tools
  run_publish CHANNELS= >/dev/null 2>&1 || fail "first publish failed"
  : > "$WORK/requests.jsonl"
  local out
  out=$(run_publish CHANGELOG_URL=https://example.com/other 2>&1) && fail "expected failure"
  assert_contains "$out" "fail            $VERSION_URI"
  assert_eq "" "$(writes)" "writes"
}

test_a_channel_never_moves_backwards() {
  stub_tools
  seed_version 2.18.0 bafyversion2.18.0
  seed_channel v2 2.18.0 bafychannelv2
  local out
  out=$(run_publish 2>&1) || fail "publish failed: $out"
  assert_contains "$out" "skip-backwards"
  assert_contains "$out" "::notice::"
  assert_not_contains "$(writes)" "software.release.channel"
  assert_eq bafychannelv2 "$(stored software.release.channel happyview.v2 | jq -r .cid)"
}

test_a_prerelease_does_not_displace_its_release() {
  stub_tools
  seed_version 3.0.0 bafyversion3.0.0
  seed_channel v3 3.0.0 bafychannelv3
  local out
  out=$(run_publish VERSION=3.0.0-beta.12 TAG=v3.0.0-beta.12 CHANNELS=v3 2>&1) || fail "publish failed: $out"
  assert_contains "$out" "skip-backwards"
  assert_not_contains "$(writes)" "software.release.channel"
}

test_moving_a_channel_swaps_on_its_current_cid() {
  stub_tools
  seed_version 3.0.0-alpha.9 bafyversionalpha9
  seed_channel v3-alpha 3.0.0-alpha.9 bafychannelalpha
  local out
  out=$(run_publish VERSION=3.0.0-alpha.10 TAG=v3.0.0-alpha.10 CHANNELS=v3-alpha 2>&1) || fail "publish failed: $out"
  local put
  put=$(jq -c 'select(.xrpc == "com.atproto.repo.putRecord") | .body' "$WORK/requests.jsonl")
  assert_eq bafychannelalpha "$(jq -r .swapRecord <<<"$put")" "swapRecord"
  assert_eq "at://$DID/software.release.version/happyview.3.0.0-alpha.10" "$(jq -r .record.version.uri <<<"$put")" "new target"
  assert_eq "$(stored software.release.version happyview.3.0.0-alpha.10 | jq -r .cid)" \
    "$(jq -r .record.version.cid <<<"$put")" "new target cid"
  assert_eq "com.atproto.repo.putRecord software.release.channel/happyview.v3-alpha" "$(writes | tail -n1)"
}

test_a_lost_swap_race_fails() {
  stub_tools
  seed_version 2.17.3 bafyversion2.17.3
  seed_channel v2 2.17.3 bafychannelv2
  # Another writer moves the channel between the plan's read and the write.
  printf '400\n{"error":"InvalidSwap","message":"Record was at bafysomeoneelse"}' \
    > "$WORK/fail/com.atproto.repo.putRecord"
  local out
  out=$(run_publish 2>&1) && fail "expected failure"
  assert_contains "$out" "InvalidSwap: Record was at bafysomeoneelse"
  assert_eq 1 "$(jq -r 'select(.xrpc == "com.atproto.repo.putRecord") | .url' "$WORK/requests.jsonl" | grep -c .)" "attempts"
}

test_channels_take_commas_newlines_and_spaces_around_them() {
  stub_tools
  local out
  out=$(run_publish CHANNELS=" v2 ,
latest
" DRY_RUN=true 2>&1) || fail "dry run failed: $out"
  assert_contains "$out" "create          at://$DID/software.release.channel/happyview.v2  "
  assert_contains "$out" "create          at://$DID/software.release.channel/happyview.latest  "
}

test_a_channel_on_an_unreadable_version_fails_without_writing() {
  stub_tools
  # The channel names a version record that is not in the repo.
  seed_channel v2 2.18.0 bafychannelv2
  local out
  out=$(run_publish 2>&1) && fail "expected failure"
  assert_contains "$out" "fail            at://$DID/software.release.channel/happyview.v2"
  assert_contains "$out" "::error::the v2 channel (at://$DID/software.release.channel/happyview.v2) points at at://$DID/software.release.version/happyview.2.18.0, which is not a readable version record"
  assert_contains "$out" "Fix it by hand"
  assert_eq "" "$(writes)" "writes"
  assert_eq bafychannelv2 "$(stored software.release.channel happyview.v2 | jq -r .cid)"
}

test_a_dry_run_reports_an_unreadable_channel_target_as_a_failure() {
  stub_tools
  seed_channel v2 2.18.0 bafychannelv2
  local out
  out=$(run_publish DRY_RUN=true PASSWORD= 2>&1) && fail "expected failure"
  assert_contains "$out" "create          $VERSION_URI"
  assert_contains "$out" "fail            at://$DID/software.release.channel/happyview.v2"
  assert_contains "$out" "::error::1 record(s) can't be published as planned"
}

test_a_channel_on_a_version_that_is_not_semver_fails() {
  stub_tools
  seed_version banana bafyversionbanana
  seed_channel v2 banana bafychannelv2
  local out
  out=$(run_publish 2>&1) && fail "expected failure"
  assert_contains "$out" "whose version banana is not SemVer"
  assert_eq "" "$(writes)" "writes"
}

test_no_channels_writes_no_channel() {
  stub_tools
  local out
  out=$(run_publish CHANNELS= 2>&1) || fail "publish failed: $out"
  assert_eq 3 "$(writes | grep -c .)" "writes"
  assert_not_contains "$(jq -r .url "$WORK/requests.jsonl")" "software.release.channel"
}

test_a_planned_blob_is_refused_before_anything_is_written() {
  stub_tools
  local out
  out=$(env PATH="$WORK/bin:$PATH" IDENTIFIER="$HANDLE" PASSWORD=app-password-secret PUBLISHER_DID="$DID" \
    PROJECT=happyview VERSION=2.17.4 REPOSITORY=https://github.com/example/happyview.git \
    COMMIT="$COMMIT_SHA" PUBLISHED_AT="$PUBLISHED_AT" CHANNELS=v2 DRY_RUN=false bash -c '
      . "$1"
      manifest_record() {
        jq -n "{\"\$type\": \"software.release.manifest\", icon: {\"\$type\": \"blob\",
          ref: {\"\$link\": \"bafkrei\"}, mimeType: \"image/png\", size: 1}}"
      }
      main' _ "$publish" 2>&1) && fail "expected failure"
  assert_contains "$out" "::error::the manifest record would hold a blob"
  assert_eq "" "$(writes)" "writes"
}

test_any_blob_shape_is_refused() {
  local out
  out=$(bash -c '. "$1"; refuse_blobs legacy "{\"a\": [{\"ref\": {\"\$link\": \"bafk\"}}]}"' _ "$publish" 2>&1) &&
    fail "accepted a ref.\$link"
  assert_contains "$out" "legacy would hold a blob"
  out=$(bash -c '. "$1"; refuse_blobs legacy "{\"icon\": {\"cid\": \"bafk\", \"mimeType\": \"image/png\"}}"' _ "$publish" 2>&1) &&
    fail "expected the legacy {cid, mimeType} blob shape to be refused"
  assert_contains "$out" "legacy would hold a blob"
  bash -c '. "$1"; refuse_blobs ok "{\"ref\": \"refs/tags/v1\", \"x\": {\"\$type\": \"blobby\"}}"' _ "$publish" ||
    fail "refused a record without a blob"
}

test_an_xrpc_error_fails_fast_naming_it() {
  stub_tools
  printf '500\n{"error":"InternalServerError","message":"database is sad"}' > "$WORK/fail/com.atproto.repo.createRecord"
  local out
  out=$(run_publish 2>&1) && fail "expected failure"
  assert_contains "$out" "::error::"
  assert_contains "$out" "InternalServerError: database is sad"
  assert_eq 1 "$(writes | grep -c .)" "attempts"
}

test_a_bad_password_fails_naming_the_error() {
  stub_tools
  local out
  out=$(run_publish PASSWORD=wrong 2>&1) && fail "expected failure"
  assert_contains "$out" "AuthenticationRequired: Invalid identifier or password"
  assert_eq "" "$(writes)" "writes"
}

test_publishing_needs_a_password() {
  stub_tools
  local out
  out=$(run_publish PASSWORD= 2>&1) && fail "expected failure"
  assert_contains "$out" "password"
  assert_eq "" "$(cat "$WORK/requests.jsonl")" "requests"
}

test_secrets_are_masked_and_never_in_argv_or_logs() {
  stub_tools
  local out
  out=$(run_publish 2>&1) || fail "publish failed: $out"
  assert_contains "$out" "::add-mask::app-password-secret"
  assert_contains "$out" "::add-mask::access-jwt-secret"
  assert_eq 1 "$(grep -c app-password-secret <<<"$out")" "mentions of the password"
  assert_eq 1 "$(grep -c access-jwt-secret <<<"$out")" "mentions of the token"
  local argv
  argv=$(jq -c .argv "$WORK/requests.jsonl")
  assert_not_contains "$argv" app-password-secret "curl argv"
  assert_not_contains "$argv" access-jwt-secret "curl argv"
  # Writes carry the session; reads never do.
  assert_eq "" "$(jq -r 'select(.xrpc == "com.atproto.repo.getRecord" and .auth != "") | .url' "$WORK/requests.jsonl")" "authenticated reads"
  assert_eq "" "$(jq -r 'select((.xrpc | test("Record$")) and .method == "POST" and .auth != "Bearer access-jwt-secret") | .url' "$WORK/requests.jsonl")" "anonymous writes"
}

test_a_handle_resolves_over_https_without_dns() {
  stub_tools
  rm "$WORK/dns/_atproto.$HANDLE"
  mkdir -p "$WORK/web/$HANDLE/.well-known"
  echo "$DID" > "$WORK/web/$HANDLE/.well-known/atproto-did"
  local out
  out=$(run_publish DRY_RUN=true 2>&1) || fail "dry run failed: $out"
  assert_contains "$out" "in $DID ($PDS)"
}

test_a_did_identifier_and_a_custom_plc() {
  stub_tools
  mkdir -p "$WORK/web/plc.example"
  did_doc "$DID" "$HANDLE" > "$WORK/web/plc.example/$DID"
  rm "$WORK/web/plc.directory/$DID"
  local out
  out=$(run_publish IDENTIFIER="$DID" PLC_URL=https://plc.example/ DRY_RUN=true 2>&1) || fail "dry run failed: $out"
  assert_contains "$(jq -r .url "$WORK/requests.jsonl")" "https://plc.example/$DID"
}

test_a_did_web_publisher() {
  stub_tools
  mkdir -p "$WORK/web/web.test/.well-known"
  did_doc did:web:web.test web.test > "$WORK/web/web.test/.well-known/did.json"
  local out
  out=$(run_publish IDENTIFIER=did:web:web.test PUBLISHER_DID=did:web:web.test DRY_RUN=true 2>&1) || fail "dry run failed: $out"
  assert_contains "$out" "in did:web:web.test ($PDS)"
}

test_a_handle_its_did_document_disowns_fails() {
  stub_tools
  did_doc "$DID" someone.else > "$WORK/web/plc.directory/$DID"
  local out
  out=$(run_publish DRY_RUN=true 2>&1) && fail "expected failure"
  assert_contains "$out" "does not name $HANDLE"
}

test_bad_inputs_fail_before_any_request() {
  stub_tools
  local out
  out=$(run_publish COMMIT=abc123 2>&1) && fail "accepted a short commit"
  assert_contains "$out" "40-character"
  out=$(run_publish VERSION=2.17 2>&1) && fail "accepted 2.17"
  out=$(run_publish VERSION=2.17.4+build.5 2>&1) && fail "accepted build metadata"
  out=$(run_publish PUBLISHED_AT=yesterday 2>&1) && fail "accepted yesterday"
  assert_contains "$out" "published-at"
  out=$(run_publish CHANNELS="v2, v2" 2>&1) && fail "accepted a channel twice"
  out=$(run_publish CHANNELS="v 2" 2>&1) && fail "accepted a space in a channel"
  assert_eq "" "$(cat "$WORK/requests.jsonl")" "requests"
}

test_a_leading_v_is_dropped_and_the_tag_defaults_to_it() {
  stub_tools
  local out
  out=$(run_publish VERSION=v2.17.4 TAG= CHANNELS= 2>&1) || fail "publish failed: $out"
  assert_eq "$VERSION_URI" "$(output_of version-uri)"
  assert_eq refs/tags/v2.17.4 "$(stored software.release.manifest "$TID" | jq -r '.value.artifacts[0].ref')"
}

# ---------------------------------------------------------------- batch ----

# A backfill: three releases, the newest carrying the channels.
write_releases() {
  jq -n --arg commit "$COMMIT_SHA" '[
    {version: "2.17.2", repository: "https://github.com/example/happyview.git", commit: $commit,
     "published-at": "2026-10-01T00:00:00Z"},
    {version: "v2.17.3", repository: "https://github.com/example/happyview.git", commit: $commit,
     tag: "v2.17.3", "published-at": "2026-10-15T00:00:00Z", channels: ""},
    {version: "2.17.4", repository: "https://github.com/example/happyview.git", commit: $commit,
     "changelog-url": "https://github.com/example/happyview/releases/tag/v2.17.4",
     "published-at": "2026-11-12T00:00:00Z", channels: ["v2", "latest"]}
  ]' > "$WORK/releases.json"
}

# Runs a batch: RELEASES set and the single-release inputs empty.
run_batch() {
  run_publish VERSION= REPOSITORY= COMMIT= TAG= CHANGELOG_URL= PUBLISHED_AT= CHANNELS= \
    RELEASES="$WORK/releases.json" "$@"
}

tid_of() { python3 "$helper" tid "$1"; }

test_a_batch_publishes_in_order_with_one_session() {
  stub_tools
  write_releases
  local out
  out=$(run_batch 2>&1) || fail "batch failed: $out"
  assert_eq "com.atproto.repo.createRecord software.release.project/happyview
com.atproto.repo.createRecord software.release.manifest/$(tid_of 2026-10-01T00:00:00Z)
com.atproto.repo.createRecord software.release.version/happyview.2.17.2
com.atproto.repo.createRecord software.release.manifest/$(tid_of 2026-10-15T00:00:00Z)
com.atproto.repo.createRecord software.release.version/happyview.2.17.3
com.atproto.repo.createRecord software.release.manifest/$TID
com.atproto.repo.createRecord software.release.version/happyview.2.17.4
com.atproto.repo.createRecord software.release.channel/happyview.v2
com.atproto.repo.createRecord software.release.channel/happyview.latest" "$(writes)" "writes"
  assert_eq 1 "$(jq -r 'select(.xrpc == "com.atproto.server.createSession") | .url' "$WORK/requests.jsonl" | grep -c .)" "sessions"
  assert_eq "$(stored software.release.version happyview.2.17.4 | jq -r .cid)" \
    "$(stored software.release.channel happyview.latest | jq -r .value.version.cid)" "latest's target"
  assert_eq refs/tags/v2.17.2 "$(stored software.release.manifest "$(tid_of 2026-10-01T00:00:00Z)" | jq -r '.value.artifacts[0].ref')" "default tag"
  assert_eq "$VERSION_URI" "$(output_of version-uri)"
  assert_eq "$(stored software.release.version happyview.2.17.4 | jq -r .cid)" "$(output_of version-cid)"
  assert_eq true "$(output_of published)"
  assert_eq 3 "$(output_of count-written)"
  assert_eq 0 "$(output_of count-skipped)"
}

test_a_rerun_batch_is_all_skips() {
  stub_tools
  write_releases
  run_batch >/dev/null 2>&1 || fail "first batch failed"
  : > "$WORK/requests.jsonl"
  rm "$WORK/output"
  local out
  out=$(run_batch 2>&1) || fail "rerun failed: $out"
  assert_eq "" "$(writes)" "writes"
  assert_eq false "$(output_of published)"
  assert_eq 0 "$(output_of count-written)"
  assert_eq 3 "$(output_of count-skipped)"
}

test_a_failure_mid_batch_stops_and_keeps_what_came_before() {
  stub_tools
  write_releases
  seed software.release.manifest "$(tid_of 2026-10-15T00:00:00Z)" bafyother \
    '{"$type": "software.release.manifest", "project": "x", "artifacts": []}'
  local out
  out=$(run_batch 2>&1) && fail "expected failure"
  assert_contains "$out" "::error::2.17.3:"
  assert_contains "$out" "the 1 release(s) before it are published"
  assert_eq "com.atproto.repo.createRecord software.release.project/happyview
com.atproto.repo.createRecord software.release.manifest/$(tid_of 2026-10-01T00:00:00Z)
com.atproto.repo.createRecord software.release.version/happyview.2.17.2" "$(writes)" "writes"
  assert_not_contains "$out" "release 3 of 3" "the release after it"
}

test_a_batch_dry_run_prints_every_plan_and_writes_nothing() {
  stub_tools
  write_releases
  local out
  out=$(run_batch DRY_RUN=true PASSWORD= PACE=5 2>&1) || fail "dry run failed: $out"
  assert_eq "" "$(jq -r 'select(.method != "GET") | .url' "$WORK/requests.jsonl")" "non-GET calls"
  assert_contains "$out" "== release 1 of 3"
  assert_contains "$out" "create          at://$DID/software.release.version/happyview.2.17.2"
  assert_contains "$out" "create          at://$DID/software.release.version/happyview.2.17.3"
  assert_contains "$out" "create          at://$DID/software.release.channel/happyview.latest"
  assert_eq 1 "$(grep -c "^create          $PROJECT_URI" <<<"$out")" "project planned"
  assert_eq false "$(output_of published)"
  assert_eq 0 "$(output_of count-written)"
  [[ ! -f "$WORK/sleep.log" ]] || fail "paced a dry run"
}

test_a_batch_waits_pace_seconds_between_writes() {
  stub_tools
  write_releases
  run_batch PACE=2 >/dev/null 2>&1 || fail "batch failed"
  assert_eq 8 "$(grep -c '^sleep 2$' "$WORK/sleep.log")" "pauses between 9 writes"
}

test_single_release_inputs_mixed_with_releases_are_refused() {
  stub_tools
  write_releases
  local out
  out=$(run_batch VERSION=2.17.4 CHANNELS=v2 2>&1) && fail "expected failure"
  assert_contains "$out" "::error::releases replaces the single-release inputs; leave these empty: version channels"
  assert_eq "" "$(cat "$WORK/requests.jsonl")" "requests"
}

test_a_bad_entry_anywhere_fails_before_any_request() {
  stub_tools
  write_releases
  jq '.[2].commit = "abc"' "$WORK/releases.json" > "$WORK/r" && mv "$WORK/r" "$WORK/releases.json"
  local out
  out=$(run_batch 2>&1) && fail "expected failure"
  assert_contains "$out" "releases[2]: commit must be a full 40-character SHA-1"
  assert_eq "" "$(cat "$WORK/requests.jsonl")" "requests"
}

test_a_malformed_releases_file_is_refused() {
  stub_tools
  local out
  echo '{"version": "1.0.0"}' > "$WORK/releases.json"
  out=$(run_batch 2>&1) && fail "accepted an object"
  assert_contains "$out" "non-empty JSON array"
  echo '[{"version": "1.0.0", "publishedAt": "2026-01-01T00:00:00Z"}]' > "$WORK/releases.json"
  out=$(run_batch 2>&1) && fail "accepted an unknown key"
  out=$(run_batch RELEASES="$WORK/missing.json" 2>&1) && fail "accepted a missing file"
  assert_contains "$out" "is not a file"
  assert_eq "" "$(cat "$WORK/requests.jsonl")" "requests"
}

test_two_entries_with_one_published_at_are_refused() {
  stub_tools
  write_releases
  jq '.[1]["published-at"] = .[0]["published-at"]' "$WORK/releases.json" > "$WORK/r" && mv "$WORK/r" "$WORK/releases.json"
  local out
  out=$(run_batch 2>&1) && fail "expected failure"
  assert_contains "$out" "share a published-at"
  assert_eq "" "$(cat "$WORK/requests.jsonl")" "requests"
}

run_tests
