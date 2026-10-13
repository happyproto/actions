#!/usr/bin/env bash
# setup-hpy/resolve.sh against canned GitHub API responses.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib.sh
. "$here/lib.sh"
resolve="$here/../setup-hpy/resolve.sh"

RELEASES='[
  {"tag_name": "v1.0.0", "draft": false},
  {"tag_name": "v1.1.0-alpha.9", "draft": false},
  {"tag_name": "v1.1.0-alpha.10", "draft": false},
  {"tag_name": "v1.1.0-beta.1", "draft": false},
  {"tag_name": "v2.0.0", "draft": false},
  {"tag_name": "not-a-version", "draft": false},
  {"tag_name": "v1.1.0-alpha.11", "draft": true},
  {"tag_name": "v3.0.0-rc.1", "draft": false},
  {"tag_name": "v1.2.0-alphabet.1", "draft": false}
]'

test_an_exact_version_passes_through_without_its_v() {
  assert_eq 1.0.0-alpha.2 "$("$resolve" v1.0.0-alpha.2 stable </dev/null)"
  assert_eq 1.0.0 "$("$resolve" 1.0.0 alpha </dev/null)"
}

test_latest_is_the_highest_on_the_channel() {
  assert_eq 2.0.0 "$("$resolve" latest stable <<<"$RELEASES")" stable
  assert_eq 1.1.0-beta.1 "$("$resolve" latest beta <<<"$RELEASES")" beta
}

test_main_means_stable() {
  assert_eq 2.0.0 "$("$resolve" latest main <<<"$RELEASES")"
}

test_alpha_compares_numbers_numerically_and_skips_drafts_and_other_channels() {
  # alpha.10 beats alpha.9; the draft alpha.11, the newer stables, rc and
  # "alphabet" never count
  assert_eq 1.1.0-alpha.10 "$("$resolve" latest alpha <<<"$RELEASES")"
}

test_no_release_on_the_channel_fails() {
  local err
  err=$("$resolve" latest alpha <<<'[{"tag_name": "v1.0.0", "draft": false}]' 2>&1) && fail "expected failure"
  assert_contains "$err" "no alpha release of hpy has been published"
}

test_an_unknown_channel_fails() {
  local err
  err=$("$resolve" latest nightly </dev/null 2>&1) && fail "expected failure"
  assert_contains "$err" "\`nightly\` is not a channel; choose stable, beta or alpha"
}

run_tests
