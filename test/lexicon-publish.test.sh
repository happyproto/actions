#!/usr/bin/env bash
# lexicon-publish/publish.sh against stub `goat` and `dig` commands that log
# their arguments and environment and play back canned answers.
#
# Each test runs in a subshell of its own, with its own $WORK, by design.
# shellcheck disable=SC2031
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib.sh
. "$here/lib.sh"
publish="$here/../lexicon-publish/publish.sh"

DID="did:plc:lexicons"

# Stubs in $WORK/bin. Their answers come from files the test writes:
#   dns/<name>  the TXT answer for <name>, as dig +short prints it; absent
#               means no record
#   did         the DID `goat resolve` answers; absent means it fails
# Each call appends "cmd args | GOAT_PASSWORD=..." to calls.log.
stub_tools() {
  mkdir -p "$WORK/bin" "$WORK/dns"
  cat > "$WORK/bin/goat" <<STUB
#!/usr/bin/env bash
echo "goat \$* | GOAT_USERNAME=\${GOAT_USERNAME:-} GOAT_PASSWORD=\${GOAT_PASSWORD:-}" >> "$WORK/calls.log"
if [[ "\$1" == resolve ]]; then
  [[ -f "$WORK/did" ]] || { echo "error: could not resolve \$2" >&2; exit 1; }
  printf '{"id": "%s"}\n' "\$(cat "$WORK/did")"
fi
STUB
  cat > "$WORK/bin/dig" <<STUB
#!/usr/bin/env bash
echo "dig \$*" >> "$WORK/calls.log"
name="\${*: -1}"
[[ -f "$WORK/dns/\$name" ]] && cat "$WORK/dns/\$name"
exit 0
STUB
  chmod +x "$WORK/bin/goat" "$WORK/bin/dig"
  : > "$WORK/calls.log"
  echo "$DID" > "$WORK/did"

  mkdir -p "$WORK/lexicons/com/example/thing" "$WORK/lexicons/com/example/other"
  echo '{"lexicon": 1, "id": "com.example.thing.record", "defs": {}}' > "$WORK/lexicons/com/example/thing/record.json"
  echo '{"lexicon": 1, "id": "com.example.thing.getRecord", "defs": {}}' > "$WORK/lexicons/com/example/thing/getRecord.json"
  echo '{"lexicon": 1, "id": "com.example.other.ping", "defs": {}}' > "$WORK/lexicons/com/example/other/ping.json"
  echo '{"not": "a lexicon"}' > "$WORK/lexicons/notes.json"
}

# DNS saying every authority in the fixture belongs to $DID.
dns_for_all() {
  echo "\"did=$DID\"" > "$WORK/dns/_lexicon.thing.example.com"
  echo "\"did=$DID\"" > "$WORK/dns/_lexicon.other.example.com"
}

run_publish() {
  env PATH="$WORK/bin:$PATH" IDENTIFIER=lexicons.example.com PASSWORD=app-password-secret \
    LEXICONS_DIR="$WORK/lexicons" DRY_RUN=false "$@" "$publish"
}

test_publishes_once_every_authority_resolves_to_the_account() {
  stub_tools
  dns_for_all
  local out
  out=$(run_publish 2>&1) || fail "publish failed: $out"
  local calls
  calls=$(cat "$WORK/calls.log")
  assert_contains "$calls" "goat lex publish --update --lexicons-dir $WORK/lexicons"
  assert_contains "$calls" "GOAT_USERNAME=lexicons.example.com GOAT_PASSWORD=app-password-secret"
}

test_each_authority_is_looked_up_once() {
  stub_tools
  dns_for_all
  run_publish >/dev/null 2>&1 || fail "publish failed"
  assert_eq 1 "$(grep -c "_lexicon.thing.example.com" "$WORK/calls.log")" "thing lookups"
  assert_eq 1 "$(grep -c "_lexicon.other.example.com" "$WORK/calls.log")" "other lookups"
  assert_eq 2 "$(grep -c "^dig " "$WORK/calls.log")" "lookups"
}

test_a_missing_dns_record_fails_naming_the_record_to_add() {
  stub_tools
  echo "\"did=$DID\"" > "$WORK/dns/_lexicon.thing.example.com"
  local out
  out=$(run_publish 2>&1) && fail "expected failure"
  assert_contains "$out" "::error::"
  assert_contains "$out" "_lexicon.other.example.com TXT \"did=$DID\""
  assert_not_contains "$out" "_lexicon.thing.example.com TXT" "a record that is right"
  assert_not_contains "$(cat "$WORK/calls.log")" "lex publish"
}

test_dns_naming_another_account_fails() {
  stub_tools
  dns_for_all
  echo '"did=did:plc:someoneelse"' > "$WORK/dns/_lexicon.other.example.com"
  local out
  out=$(run_publish 2>&1) && fail "expected failure"
  assert_contains "$out" "_lexicon.other.example.com TXT \"did=$DID\""
  assert_contains "$out" "did:plc:someoneelse"
  assert_not_contains "$(cat "$WORK/calls.log")" "lex publish"
}

test_an_account_that_does_not_resolve_fails() {
  stub_tools
  dns_for_all
  rm "$WORK/did"
  local out
  out=$(run_publish 2>&1) && fail "expected failure"
  assert_contains "$out" "lexicons.example.com"
  assert_not_contains "$(cat "$WORK/calls.log")" "lex publish"
}

test_a_dry_run_reports_status_without_signing_in() {
  stub_tools
  dns_for_all
  run_publish DRY_RUN=true PASSWORD= >/dev/null 2>&1 || fail "dry run failed"
  local calls
  calls=$(cat "$WORK/calls.log")
  assert_contains "$calls" "goat lex status --lexicons-dir $WORK/lexicons"
  assert_not_contains "$calls" "lex publish"
  assert_not_contains "$calls" "GOAT_PASSWORD=app"
}

test_publishing_needs_a_password() {
  stub_tools
  dns_for_all
  local out
  out=$(run_publish PASSWORD= 2>&1) && fail "expected failure"
  assert_contains "$out" "password"
  assert_not_contains "$(cat "$WORK/calls.log")" "lex publish"
}

test_the_password_is_masked_and_never_printed_otherwise() {
  stub_tools
  dns_for_all
  local out
  out=$(run_publish 2>&1) || fail "publish failed"
  assert_contains "$out" "::add-mask::app-password-secret"
  assert_eq 1 "$(grep -c "app-password-secret" <<<"$out")" "mentions of the password"
}

test_a_directory_with_no_lexicons_fails() {
  stub_tools
  local out
  out=$(run_publish LEXICONS_DIR="$WORK/empty" 2>&1) && fail "expected failure"
  assert_contains "$out" "no lexicons"
}

run_tests
