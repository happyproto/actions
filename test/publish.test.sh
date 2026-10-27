#!/usr/bin/env bash
# plugin-publish/publish.sh against a stub `hpy` that logs its arguments and
# environment and plays back canned JSON.
#
# Each test runs in a subshell of its own, with its own $WORK, by design.
# shellcheck disable=SC2031
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib.sh
. "$here/lib.sh"
publish="$here/../plugin-publish/publish.sh"

# A stub hpy in $WORK/bin. Its replies come from files the test writes:
#   status.json   for `hpy registry plugin status`
#   publish.json  for `hpy registry plugin publish`; absent means it fails
# Each call appends "cwd | args | HPY_CREDENTIAL=..." to calls.log.
stub_hpy() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/hpy" <<STUB
#!/usr/bin/env bash
echo "\$PWD | \$* | HPY_CREDENTIAL=\${HPY_CREDENTIAL:-}" >> "$WORK/calls.log"
case "\$3" in
  status) cat "$WORK/status.json" ;;
  publish)
    [[ -f "$WORK/publish.json" ]] || { echo "error: the registry refused it" >&2; exit 2; }
    cat "$WORK/publish.json" ;;
esac
STUB
  chmod +x "$WORK/bin/hpy"
  : > "$WORK/calls.log"
  echo '{"name": "my-plugin", "project": null, "versions": []}' > "$WORK/status.json"
  echo '{"uri": "at://did:plc:me/software.release.version/my-plugin:1.2.0", "cid": "bafy", "createdProject": false, "resumed": false, "availability": "available"}' > "$WORK/publish.json"
}

# Runs publish.sh with the action's defaults, overridden by NAME=value args.
run_publish() {
  env PATH="$WORK/bin:$PATH" GITHUB_OUTPUT="$WORK/output" GITHUB_STEP_SUMMARY="$WORK/summary" \
    GITHUB_ENV="$WORK/env" VERSION=1.2.0 CREDENTIAL=secret-credential WORKING_DIRECTORY=. \
    WASM= TRACK= WAIT=true DRY_RUN=false SKIP_EXISTING=true "$@" "$publish"
}

test_publishes_with_the_flags_ci_needs() {
  stub_hpy
  run_publish WASM=../target/my_plugin.wasm >/dev/null || fail "publish failed"
  local calls
  calls=$(cat "$WORK/calls.log")
  assert_contains "$calls" "registry plugin status --json"
  assert_contains "$calls" "registry plugin publish --no-input --yes --no-build --json --version 1.2.0 --wasm ../target/my_plugin.wasm --wait"
  assert_contains "$(cat "$WORK/output")" "published=true"
  assert_contains "$(cat "$WORK/output")" "uri=at://did:plc:me/software.release.version/my-plugin:1.2.0"
  assert_contains "$(cat "$WORK/output")" "status=available"
  assert_contains "$(cat "$WORK/summary")" "Published at://"
}

test_a_track_is_passed_to_publish() {
  stub_hpy
  run_publish TRACK=beta >/dev/null || fail "publish failed"
  assert_contains "$(grep publish "$WORK/calls.log")" "--version 1.2.0 --track beta"
}

test_no_track_passes_no_flag() {
  stub_hpy
  run_publish TRACK= >/dev/null || fail "publish failed"
  assert_not_contains "$(grep publish "$WORK/calls.log")" "--track"
}

test_without_wait_or_wasm_neither_flag_is_passed() {
  stub_hpy
  run_publish WAIT=false >/dev/null || fail "publish failed"
  local calls
  calls=$(grep publish "$WORK/calls.log")
  assert_not_contains "$calls" "--wait"
  assert_not_contains "$calls" "--wasm"
}

test_the_credential_reaches_hpy_and_nothing_else() {
  stub_hpy
  run_publish >/dev/null || fail "publish failed"
  assert_contains "$(cat "$WORK/calls.log")" "HPY_CREDENTIAL=secret-credential"
  [[ ! -e "$WORK/env" ]] || assert_not_contains "$(cat "$WORK/env")" "secret-credential" GITHUB_ENV
  assert_not_contains "$(cat "$WORK/output")" "secret-credential" GITHUB_OUTPUT
}

test_runs_in_the_working_directory() {
  stub_hpy
  mkdir -p "$WORK/plugins/mine"
  run_publish WORKING_DIRECTORY="$WORK/plugins/mine" >/dev/null || fail "publish failed"
  assert_contains "$(grep publish "$WORK/calls.log")" "$WORK/plugins/mine | registry plugin publish"
}

test_a_version_already_available_is_skipped() {
  stub_hpy
  echo '{"name": "my-plugin", "versions": [{"version": "1.2.0", "availability": "available", "state": "active", "installable": true, "inRepo": true}]}' > "$WORK/status.json"
  local out
  out=$(run_publish) || fail "publish failed"
  assert_contains "$out" "::notice::my-plugin 1.2.0 is already in the registry (available); skipping"
  assert_not_contains "$(cat "$WORK/calls.log")" "registry plugin publish"
  assert_contains "$(cat "$WORK/output")" "published=false"
  assert_contains "$(cat "$WORK/output")" "status=available"
}

test_a_version_still_pending_is_skipped() {
  stub_hpy
  echo '{"name": "my-plugin", "versions": [{"version": "1.2.0", "availability": "pending", "state": "active", "installable": false, "inRepo": true}]}' > "$WORK/status.json"
  local out
  out=$(run_publish) || fail "publish failed"
  assert_contains "$out" "::notice::my-plugin 1.2.0 is already in the registry (pending); skipping"
  assert_not_contains "$(cat "$WORK/calls.log")" "registry plugin publish"
}

test_a_version_in_the_repo_but_not_indexed_is_published() {
  stub_hpy
  echo '{"name": "my-plugin", "versions": [{"version": "1.2.0", "availability": "not indexed", "state": "active", "installable": false, "inRepo": true}]}' > "$WORK/status.json"
  run_publish >/dev/null || fail "publish failed"
  assert_contains "$(cat "$WORK/calls.log")" "registry plugin publish"
  assert_contains "$(cat "$WORK/output")" "published=true"
}

test_a_version_deleted_at_source_fails() {
  stub_hpy
  echo '{"name": "my-plugin", "versions": [{"version": "1.2.0", "availability": "deletedAtSource", "state": "active", "installable": false, "inRepo": false}]}' > "$WORK/status.json"
  local out
  out=$(run_publish) && fail "expected failure"
  assert_contains "$out" "::error::my-plugin 1.2.0 is in the registry, but it reports \`deletedAtSource\`"
  assert_not_contains "$(cat "$WORK/calls.log")" "registry plugin publish"
}

test_skip_existing_false_publishes_without_checking() {
  stub_hpy
  rm "$WORK/publish.json" # hpy refuses: the version exists
  run_publish SKIP_EXISTING=false >/dev/null 2>&1 && fail "expected hpy's refusal to fail the step"
  assert_not_contains "$(cat "$WORK/calls.log")" "registry plugin status"
  assert_contains "$(cat "$WORK/calls.log")" "registry plugin publish"
}

test_a_dry_run_never_checks_status() {
  stub_hpy
  echo '{"dryRun": true, "record": {}}' > "$WORK/publish.json"
  run_publish DRY_RUN=true >/dev/null || fail "publish failed"
  assert_not_contains "$(cat "$WORK/calls.log")" "registry plugin status"
  assert_contains "$(cat "$WORK/calls.log")" "--dry-run"
  assert_contains "$(cat "$WORK/output")" "published=false"
}

test_waiting_that_ends_short_of_available_warns() {
  stub_hpy
  echo '{"uri": "at://did:plc:me/software.release.version/my-plugin:1.2.0", "availability": "pending"}' > "$WORK/publish.json"
  local out
  out=$(run_publish) || fail "publish failed"
  assert_contains "$out" "::warning::"
  assert_contains "$(cat "$WORK/output")" "status=pending"
}

run_tests
