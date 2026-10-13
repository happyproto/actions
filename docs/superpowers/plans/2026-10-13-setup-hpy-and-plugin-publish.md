# setup-hpy and plugin-publish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two GitHub Actions in `happyproto/actions` — `setup-hpy` installs the `hpy` CLI, `plugin-publish` publishes a HappyView plugin to the HappyProto registry — and `happyproto/plugins` wired to publish each release with them.

**Architecture:** Bash composite actions. `setup-hpy/setup.sh` resolves a version (`resolve.sh`, strict channels), runs that release's installer and checks the credential; `plugin-publish/action.yml` runs that same script by path (so both come from one ref), then `publish.sh`, which skips a version the registry already has and otherwise runs `hpy registry plugin publish`. In `happyproto/plugins`, semantic-release cuts the GitHub release, then `plugin-publish` runs when it did; a manual workflow re-publishes a stuck version from its tag.

**Tech Stack:** bash (3.2-compatible), jq, curl, GitHub composite actions, semantic-release 25, `semantic-release-export-data`, Node 22 (`node --test`), shellcheck, actionlint.

**Spec:** `docs/superpowers/specs/2026-10-13-setup-hpy-and-plugin-publish-design.md` (in `happyproto/actions`).

## Global Constraints

- Repositories: `happyproto/actions` at `/Users/trezy/Development/clients/happyproto/actions` (Tasks 1–4), `happyproto/plugins` at `/Users/trezy/Development/clients/happyproto/plugins` (Tasks 5–6), the CLI at `/Users/trezy/Development/clients/happyproto/cli` (Task 7).
- **Git:** the user's rule is "Do not run git commands (commit, add, push, etc.) unless explicitly asked." Every commit step below runs only with the user's go-ahead for this execution. Never add Co-Authored-By or any Claude attribution to commits or PRs. Commit messages are Conventional Commits.
- **The plugins working tree has the user's uncommitted work** (`package-lock.json` modified; `hpy.toml`, `DESCRIPTION.md`, `INSTALLATION.md`, `SECURITY.md`, `CHANGELOG.md` untracked under `plugins/happyview/*`). Do not stage, revert or overwrite any of it. Stage only the files each task names, by path.
- Scripts must run on bash 3.2 (macOS's `/bin/bash`): no associative arrays, no `mapfile`, no `${x,,}`.
- `hpy` channel semantics are the CLI's (`crates/hpy/src/channel.rs`): a plain version is `stable`, `-beta.N` `beta`, `-alpha.N` `alpha`, anything else no channel; `main` means `stable`; strict — `latest` never crosses channels.
- `channel` defaults to `stable`; `happyproto/plugins` sets `hpy-channel: alpha` until hpy has a stable release.
- The credential is never written to `$GITHUB_ENV`, `$GITHUB_OUTPUT` or logs; it is `::add-mask::`ed before any output and given only to the `hpy` commands that need it.
- `hpy registry whoami` is offline (decodes the credential only). `hpy registry plugin status --json` prints `{"slug","package","releases":[{"version","registry","inRepo"}]}` and needs a live session; asking it for one version that doesn't exist is an error, so ask for all. `hpy registry plugin publish --json` prints `{"uri","cid","createdProfile","registryStatus"}` (`registryStatus` is null without `--wait`), or `{"dryRun":true,"record":…}`.

## Review Focus

1. **semantic-release-export-data's `new-release-version` in the monorepo is the tag** (`happyview-sql-v1.2.0`): `semantic-release-monorepo` and `release/package-paths.mjs` replace `nextRelease.version` with the git tag in every plugin's `generateNotes`, which is where export-data reads it. The release job must derive the version from `new-release-git-tag` and check it against `manifest.json` (Task 6), with `versionOfTag` tested (Task 5).
2. **The credential leaking** into `$GITHUB_ENV`, outputs or the job log — pinned by `test_the_credential_reaches_hpy_and_nothing_else` (Task 3) and the masking in `setup.sh` (Task 2).
3. **`hpy` not on `PATH` in a later step** — `$GITHUB_PATH` only affects later steps; CI's "hpy is on PATH for later steps" step checks it on both OSes (Task 4).
4. **A rerun after a partial failure** — `skip-existing` (Task 3 tests) plus the recovery workflow (Task 6).
5. **macOS runners** — bash 3.2 and BSD tools: scripts are tested locally on macOS's bash 3.2, and CI runs `setup-hpy` on `macos-latest` (Task 4).

---

### Task 1: The test runner and the version resolver

**Files:**
- Create: `test/lib.sh`, `test/resolve.test.sh`, `setup-hpy/resolve.sh` (all in `happyproto/actions`)

**Interfaces:**
- Produces: `setup-hpy/resolve.sh VERSION CHANNEL < releases.json` → prints the version without `v`; exit 1 with `no <channel> release of hpy has been published`; exit 2 with `` `<x>` is not a channel; choose stable, beta or alpha ``. `test/lib.sh` → `fail`, `assert_eq`, `assert_contains`, `assert_not_contains`, `run_tests` (runs every `test_*` function in a subshell with a fresh `$WORK` as the cwd).

- [ ] **Step 1: Write the test runner**

`test/lib.sh`:

```bash
# shellcheck shell=bash
# Shared by the test/*.test.sh files: a tiny runner and assertions.
# Each test is a function; `run_tests` calls every function named test_*,
# each in a subshell with a fresh $WORK directory, and exits non-zero if any
# failed.

fail() {
  echo "    $*" >&2
  exit 1
}

assert_eq() { # expected actual [label]
  [[ "$1" == "$2" ]] || fail "${3:-value}: expected [$1], got [$2]"
}

assert_contains() { # haystack needle [label]
  [[ "$1" == *"$2"* ]] || fail "${3:-text}: [$1] does not contain [$2]"
}

assert_not_contains() { # haystack needle [label]
  [[ "$1" != *"$2"* ]] || fail "${3:-text}: [$1] contains [$2]"
}

run_tests() {
  local failed=0 name
  for name in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
    if (WORK=$(mktemp -d) && cd "$WORK" && "$name"); then
      echo "ok   $name"
    else
      echo "FAIL $name"
      failed=1
    fi
  done
  return "$failed"
}
```

- [ ] **Step 2: Write the failing resolver tests**

`test/resolve.test.sh`:

```bash
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
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd /Users/trezy/Development/clients/happyproto/actions && bash test/resolve.test.sh`
Expected: six `FAIL` lines (`resolve.sh` does not exist), exit 1.

- [ ] **Step 4: Write the resolver**

`setup-hpy/resolve.sh` (then `chmod +x setup-hpy/resolve.sh test/*.test.sh`):

```bash
#!/usr/bin/env bash
# Prints the hpy version to install, without a leading `v`.
#
# Usage: resolve.sh VERSION CHANNEL < releases.json
#   VERSION  an exact version (`1.0.0-alpha.2`, `v1.0.0`), or `latest`
#   CHANNEL  stable (or main), beta or alpha: which channel `latest` means
#   stdin    GitHub's /repos/happyproto/cli/releases response; read only for
#            `latest`
#
# Channels are strict, as in hpy itself (crates/hpy/src/channel.rs): a plain
# version is stable, `-beta.N` beta, `-alpha.N` alpha, anything else on no
# channel, and `latest` never crosses channels.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 VERSION CHANNEL < releases.json" >&2
  exit 2
fi
version="$1"
channel="$2"

case "$channel" in
  stable | main) channel=stable ;;
  beta | alpha) ;;
  *) echo "\`$channel\` is not a channel; choose stable, beta or alpha" >&2; exit 2 ;;
esac

if [[ "$version" != latest ]]; then
  echo "${version#v}"
  exit 0
fi

found=$(jq -r --arg channel "$channel" '
  def semver: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-([0-9A-Za-z.-]+))?(\\+[0-9A-Za-z.-]+)?$";
  def channel_of($pre):
    if $pre == null then "stable"
    else ($pre | split(".")[0]) as $c | if $c == "beta" or $c == "alpha" then $c else null end
    end;
  [ .[]
    | select(.draft | not)
    | (.tag_name | ltrimstr("v")) as $v
    | select($v | test(semver))
    | ($v | capture("^[0-9]+\\.[0-9]+\\.[0-9]+(-(?<pre>[0-9A-Za-z.-]+))?").pre) as $pre
    | select(channel_of($pre) == $channel)
    | { v: $v,
        key: (($v | split("-")[0] | split("+")[0] | split(".") | map(tonumber))
              + (if $pre == null then [] else ($pre | split(".") | map(if test("^[0-9]+$") then tonumber else . end)) end)) }
  ]
  | sort_by(.key) | last | .v // empty
')
if [[ -z "$found" ]]; then
  echo "no $channel release of hpy has been published" >&2
  exit 1
fi
echo "$found"
```

- [ ] **Step 5: Run the tests and shellcheck**

Run: `bash test/resolve.test.sh && shellcheck -x setup-hpy/resolve.sh test/*.sh`
Expected: six `ok` lines, exit 0, no shellcheck output.

Also: `gh api 'repos/happyproto/cli/releases?per_page=100' | setup-hpy/resolve.sh latest alpha`
Expected: the newest published alpha (`1.0.0-alpha.2` at the time of writing).

- [ ] **Step 6: Commit** (only with the user's go-ahead)

```bash
git add test/lib.sh test/resolve.test.sh setup-hpy/resolve.sh
git commit -m "feat: resolve which hpy to install"
```

### Task 2: `setup-hpy`

**Files:**
- Create: `setup-hpy/setup.sh`, `setup-hpy/action.yml`

**Interfaces:**
- Consumes: `setup-hpy/resolve.sh` (Task 1).
- Produces: `setup-hpy/setup.sh`, driven by env `VERSION`, `CHANNEL`, `CREDENTIAL`, `GITHUB_TOKEN`; appends `version` (and `did`, `handle` with a credential) to `$GITHUB_OUTPUT`, hpy's bin directory to `$GITHUB_PATH`. `plugin-publish` (Task 3) runs it as `$GITHUB_ACTION_PATH/../setup-hpy/setup.sh`.

There is no unit test for this script: everything it does is a download or a call to the real `hpy`. Step 3 runs it against the real releases instead, and CI (Task 4) runs the action on Ubuntu and macOS.

- [ ] **Step 1: Write the script**

`setup-hpy/setup.sh` (then `chmod +x`):

```bash
#!/usr/bin/env bash
# Installs hpy and, given a credential, checks it. setup-hpy/action.yml runs
# it, and so does plugin-publish/action.yml, so both install hpy the same way.
#
# Environment (setup-hpy's inputs):
#   VERSION       an exact hpy version, or latest (default)
#   CHANNEL       stable (default), beta or alpha: what latest means
#   CREDENTIAL    optional HPY_CREDENTIAL; checked, never exported
#   GITHUB_TOKEN  for the GitHub API call that resolves latest
# Writes version, did and handle to $GITHUB_OUTPUT and hpy's directory to
# $GITHUB_PATH.
set -euo pipefail

if [[ "${RUNNER_OS:-}" == Windows ]]; then
  echo "::error::setup-hpy runs on Linux and macOS runners, not Windows"
  exit 1
fi

here="$(cd "$(dirname "$0")" && pwd)"
repo=happyproto/cli

releases() {
  curl -fsSL --retry 3 \
    -H "Accept: application/vnd.github+json" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/repos/$repo/releases?per_page=100"
}

requested="${VERSION:-latest}"
channel="${CHANNEL:-stable}"
if [[ "$requested" == latest ]]; then
  version=$(releases | "$here/resolve.sh" latest "$channel")
else
  version=$("$here/resolve.sh" "$requested" "$channel" </dev/null)
fi

installer="$(mktemp)"
trap 'rm -f "$installer"' EXIT
url="https://github.com/$repo/releases/download/v$version/hpy-cli-installer.sh"
if ! curl -fsSL --retry 3 -o "$installer" "$url"; then
  echo "::error::hpy $version does not exist (no installer at $url)"
  exit 1
fi
HPY_CLI_NO_MODIFY_PATH=1 sh "$installer" --quiet

bin="${CARGO_HOME:-$HOME/.cargo}/bin"
echo "$bin" >> "$GITHUB_PATH"
export PATH="$bin:$PATH"

export HPY_NO_UPDATE_CHECK=1
installed=$(hpy --version)
if [[ "$installed" != "hpy $version" ]]; then
  echo "::error::installed hpy $version, but \`hpy --version\` says \`$installed\`"
  exit 1
fi
echo "version=$version" >> "$GITHUB_OUTPUT"
echo "Installed hpy $version"

if [[ -n "${CREDENTIAL:-}" ]]; then
  echo "::add-mask::$CREDENTIAL"
  # whoami decodes the credential without the network: this catches a
  # malformed or truncated secret. An expired or revoked session fails at the
  # first call that reaches the registry.
  identity=$(HPY_CREDENTIAL="$CREDENTIAL" hpy registry whoami --json)
  did=$(jq -r .did <<<"$identity")
  handle=$(jq -r '.handle // ""' <<<"$identity")
  echo "did=$did" >> "$GITHUB_OUTPUT"
  echo "handle=$handle" >> "$GITHUB_OUTPUT"
  echo "The credential signs in as ${handle:+@$handle }($did)"
fi
```

- [ ] **Step 2: Write the action**

`setup-hpy/action.yml`:

```yaml
name: Set up hpy
description: Install hpy, the HappyProto command line, and optionally check a registry credential.
author: HappyProto
branding:
  icon: download
  color: purple

inputs:
  version:
    description: An exact hpy version (e.g. 1.0.0-alpha.2), or `latest`.
    required: false
    default: latest
  channel:
    description: stable, beta or alpha — which channel `latest` means. Ignored with an exact version.
    required: false
    default: stable
  credential:
    description: An HPY_CREDENTIAL from `hpy registry login --export`. Checked, never exported to later steps.
    required: false
    default: ""
  github-token:
    description: Used only to look up releases when `version` is `latest`.
    required: false
    default: ${{ github.token }}

outputs:
  version:
    description: The installed hpy version.
    value: ${{ steps.setup.outputs.version }}
  did:
    description: The DID the credential signs in as; empty without one.
    value: ${{ steps.setup.outputs.did }}
  handle:
    description: The handle the credential signs in as; empty without one.
    value: ${{ steps.setup.outputs.handle }}

runs:
  using: composite
  steps:
    - id: setup
      shell: bash
      env:
        VERSION: ${{ inputs.version }}
        CHANNEL: ${{ inputs.channel }}
        CREDENTIAL: ${{ inputs.credential }}
        GITHUB_TOKEN: ${{ inputs.github-token }}
      run: '"$GITHUB_ACTION_PATH/setup.sh"'
```

- [ ] **Step 3: Run it against the real releases, in a scratch CARGO_HOME**

Never let it install into the real `~/.cargo`. Run:

```bash
T=$(mktemp -d)
env CARGO_HOME=$T/cargo GITHUB_PATH=$T/path GITHUB_OUTPUT=$T/out CHANNEL=alpha GITHUB_TOKEN=$(gh auth token) setup-hpy/setup.sh
cat $T/out $T/path
env CARGO_HOME=$T/cargo GITHUB_PATH=$T/path GITHUB_OUTPUT=$T/out VERSION=9.9.9 setup-hpy/setup.sh; echo "exit $?"
env CARGO_HOME=$T/cargo GITHUB_PATH=$T/path GITHUB_OUTPUT=$T/out VERSION=1.0.0-alpha.2 CREDENTIAL=bogus setup-hpy/setup.sh; echo "exit $?"
rm -rf "$T"
```

Expected: the first prints `Installed hpy 1.0.0-alpha.2` (or a newer alpha), then `version=…` and `$T/cargo/bin`; the second prints `::error::hpy 9.9.9 does not exist (no installer at …)` and exit 1; the third prints `::add-mask::bogus`, hpy's `HPY_CREDENTIAL is not a credential from` error, and a non-zero exit.

- [ ] **Step 4: Shellcheck and YAML**

Run: `shellcheck -x setup-hpy/*.sh && ruby -ryaml -e 'YAML.load_file("setup-hpy/action.yml"); puts "ok"'`
Expected: `ok`.

- [ ] **Step 5: Commit** (only with the user's go-ahead)

```bash
git add setup-hpy/setup.sh setup-hpy/action.yml
git commit -m "feat: setup-hpy installs hpy and checks a credential"
```

### Task 3: `plugin-publish`

**Files:**
- Create: `test/publish.test.sh`, `plugin-publish/publish.sh`, `plugin-publish/action.yml`

**Interfaces:**
- Consumes: `test/lib.sh` (Task 1); `setup-hpy/setup.sh` (Task 2), by path.
- Produces: `plugin-publish/publish.sh`, driven by env `VERSION`, `CREDENTIAL`, `WORKING_DIRECTORY`, `WASM`, `WAIT`, `DRY_RUN`, `SKIP_EXISTING`; appends `published`, `uri`, `status` to `$GITHUB_OUTPUT`. The action `happyproto/actions/plugin-publish` with the inputs in the spec.

- [ ] **Step 1: Write the failing tests**

`test/publish.test.sh` (then `chmod +x`):

```bash
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
  echo '{"slug": "my-plugin", "package": "active", "releases": []}' > "$WORK/status.json"
  echo '{"uri": "at://did:plc:me/at.happyproto.plugin.release/my-plugin:1.2.0", "cid": "bafy", "createdProfile": false, "registryStatus": "active"}' > "$WORK/publish.json"
}

# Runs publish.sh with the action's defaults, overridden by NAME=value args.
run_publish() {
  env PATH="$WORK/bin:$PATH" GITHUB_OUTPUT="$WORK/output" GITHUB_STEP_SUMMARY="$WORK/summary" \
    GITHUB_ENV="$WORK/env" VERSION=1.2.0 CREDENTIAL=secret-credential WORKING_DIRECTORY=. \
    WASM= WAIT=true DRY_RUN=false SKIP_EXISTING=true "$@" "$publish"
}

test_publishes_with_the_flags_ci_needs() {
  stub_hpy
  run_publish WASM=../target/my_plugin.wasm >/dev/null || fail "publish failed"
  local calls
  calls=$(cat "$WORK/calls.log")
  assert_contains "$calls" "registry plugin status --json"
  assert_contains "$calls" "registry plugin publish --no-input --yes --no-build --json --version 1.2.0 --wasm ../target/my_plugin.wasm --wait"
  assert_contains "$(cat "$WORK/output")" "published=true"
  assert_contains "$(cat "$WORK/output")" "uri=at://did:plc:me/at.happyproto.plugin.release/my-plugin:1.2.0"
  assert_contains "$(cat "$WORK/output")" "status=active"
  assert_contains "$(cat "$WORK/summary")" "Published at://"
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

test_a_version_already_active_is_skipped() {
  stub_hpy
  echo '{"slug": "my-plugin", "releases": [{"version": "1.2.0", "registry": "active", "inRepo": true}]}' > "$WORK/status.json"
  local out
  out=$(run_publish) || fail "publish failed"
  assert_contains "$out" "::notice::my-plugin 1.2.0 is already in the registry (active); skipping"
  assert_not_contains "$(cat "$WORK/calls.log")" "registry plugin publish"
  assert_contains "$(cat "$WORK/output")" "published=false"
}

test_a_version_in_the_repo_but_refused_fails() {
  stub_hpy
  echo '{"slug": "my-plugin", "releases": [{"version": "1.2.0", "registry": "not indexed", "inRepo": true}]}' > "$WORK/status.json"
  local out
  out=$(run_publish) && fail "expected failure"
  assert_contains "$out" "::error::my-plugin 1.2.0 is in your repo, but the registry reports \`not indexed\`"
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

test_waiting_that_ends_short_of_active_warns() {
  stub_hpy
  echo '{"uri": "at://did:plc:me/at.happyproto.plugin.release/my-plugin:1.2.0", "registryStatus": "pending"}' > "$WORK/publish.json"
  local out
  out=$(run_publish) || fail "publish failed"
  assert_contains "$out" "::warning::"
  assert_contains "$(cat "$WORK/output")" "status=pending"
}

run_tests
```

- [ ] **Step 2: Run them to see them fail**

Run: `bash test/publish.test.sh`
Expected: nine `FAIL` lines (`publish.sh` does not exist), exit 1.

- [ ] **Step 3: Write the script**

`plugin-publish/publish.sh` (then `chmod +x`):

```bash
#!/usr/bin/env bash
# Publishes one plugin release with hpy. plugin-publish/action.yml runs it
# after setup-hpy/setup.sh has put hpy on PATH.
#
# Environment (the action's inputs):
#   VERSION            the plugin version to publish (required)
#   CREDENTIAL         HPY_CREDENTIAL (required); given to hpy alone
#   WORKING_DIRECTORY  the plugin's directory (default .)
#   WASM               the built module, relative to WORKING_DIRECTORY
#   WAIT, DRY_RUN, SKIP_EXISTING   true or false
# Writes published, uri and status to $GITHUB_OUTPUT and one line to
# $GITHUB_STEP_SUMMARY.
set -euo pipefail

: "${VERSION:?the version input is required}"
: "${CREDENTIAL:?the credential input is required}"
cd "${WORKING_DIRECTORY:-.}"

hpy_() { HPY_CREDENTIAL="$CREDENTIAL" HPY_NO_UPDATE_CHECK=1 hpy "$@"; }
output() { echo "$1=$2" >> "$GITHUB_OUTPUT"; }
summary() { echo "$1" >> "$GITHUB_STEP_SUMMARY"; }

if [[ "${SKIP_EXISTING:-true}" == true && "${DRY_RUN:-false}" != true ]]; then
  # Every version: asking `status` for one that doesn't exist is an error.
  status=$(hpy_ registry plugin status --json)
  slug=$(jq -r .slug <<<"$status")
  registry=$(jq -r --arg v "$VERSION" '.releases[] | select(.version == $v) | .registry' <<<"$status")
  case "$registry" in
    "") ;;
    active | pending)
      echo "::notice::$slug $VERSION is already in the registry ($registry); skipping. Releases are immutable, so it was not compared with this build."
      output published false
      output uri ""
      output status "$registry"
      summary "Skipped $slug $VERSION: already in the registry ($registry)."
      exit 0
      ;;
    *)
      echo "::error::$slug $VERSION is in your repo, but the registry reports \`$registry\`; run \`hpy registry plugin status $VERSION\` to see why."
      exit 1
      ;;
  esac
fi

args=(registry plugin publish --no-input --yes --no-build --json --version "$VERSION")
if [[ -n "${WASM:-}" ]]; then args+=(--wasm "$WASM"); fi
if [[ "${WAIT:-true}" == true ]]; then args+=(--wait); fi
if [[ "${DRY_RUN:-false}" == true ]]; then args+=(--dry-run); fi
result=$(hpy_ "${args[@]}")

if [[ "${DRY_RUN:-false}" == true ]]; then
  output published false
  output uri ""
  output status ""
  summary "Dry run of $VERSION: the record is valid."
  exit 0
fi

uri=$(jq -r .uri <<<"$result")
status=$(jq -r '.registryStatus // ""' <<<"$result")
output published true
output uri "$uri"
output status "$status"
if [[ "${WAIT:-true}" == true && "$status" != active ]]; then
  echo "::warning::$uri is published, but the registry still reports \`$status\`; it will finish copying the artifact on its own."
fi
summary "Published $uri${status:+ ($status)}."
```

- [ ] **Step 4: Run the tests and shellcheck**

Run: `bash test/publish.test.sh && bash test/resolve.test.sh && shellcheck -x setup-hpy/*.sh plugin-publish/*.sh test/*.sh`
Expected: nine and six `ok` lines, no shellcheck output.

- [ ] **Step 5: Write the action**

`plugin-publish/action.yml`:

```yaml
name: Publish a HappyView plugin
description: Publish a HappyView plugin release to the HappyProto registry with hpy.
author: HappyProto
branding:
  icon: upload-cloud
  color: purple

inputs:
  version:
    description: The plugin version to publish.
    required: true
  credential:
    description: An HPY_CREDENTIAL from `hpy registry login --export`. Given to hpy alone.
    required: true
  working-directory:
    description: The plugin's directory, where hpy.toml and manifest.json are.
    required: false
    default: .
  wasm:
    description: The built module, relative to working-directory. Omitted, hpy finds it.
    required: false
    default: ""
  wait:
    description: Wait until the registry has copied the artifact and the release is active.
    required: false
    default: "true"
  dry-run:
    description: Validate and print the record without publishing.
    required: false
    default: "false"
  skip-existing:
    description: When the registry already has this version, succeed with a notice instead of failing.
    required: false
    default: "true"
  hpy-version:
    description: The hpy to use (setup-hpy's `version`).
    required: false
    default: latest
  hpy-channel:
    description: Which channel `latest` means for hpy-version (setup-hpy's `channel`).
    required: false
    default: stable
  github-token:
    description: Used only to look up hpy releases.
    required: false
    default: ${{ github.token }}

outputs:
  published:
    description: "`true` if this run published; `false` if it skipped or was a dry run."
    value: ${{ steps.publish.outputs.published }}
  uri:
    description: The release's AT URI; empty when skipped or a dry run.
    value: ${{ steps.publish.outputs.uri }}
  status:
    description: The release's registry status.
    value: ${{ steps.publish.outputs.status }}
  hpy-version:
    description: The hpy that ran.
    value: ${{ steps.setup.outputs.version }}

runs:
  using: composite
  steps:
    # setup-hpy's own script, from this same ref: `uses: ./setup-hpy` would
    # resolve against the caller's checkout instead.
    - id: setup
      shell: bash
      env:
        VERSION: ${{ inputs.hpy-version }}
        CHANNEL: ${{ inputs.hpy-channel }}
        CREDENTIAL: ${{ inputs.credential }}
        GITHUB_TOKEN: ${{ inputs.github-token }}
      run: '"$GITHUB_ACTION_PATH/../setup-hpy/setup.sh"'
    - id: publish
      shell: bash
      env:
        VERSION: ${{ inputs.version }}
        CREDENTIAL: ${{ inputs.credential }}
        WORKING_DIRECTORY: ${{ inputs.working-directory }}
        WASM: ${{ inputs.wasm }}
        WAIT: ${{ inputs.wait }}
        DRY_RUN: ${{ inputs.dry-run }}
        SKIP_EXISTING: ${{ inputs.skip-existing }}
      run: '"$GITHUB_ACTION_PATH/publish.sh"'
```

Run: `ruby -ryaml -e 'YAML.load_file("plugin-publish/action.yml"); puts "ok"'`
Expected: `ok`. (A description containing `word: word` breaks YAML; this one avoids it.)

- [ ] **Step 6: Commit** (only with the user's go-ahead)

```bash
git add test/publish.test.sh plugin-publish/publish.sh plugin-publish/action.yml
git commit -m "feat: plugin-publish publishes a plugin release to the registry"
```

### Task 4: CI, releases and the README

**Files:**
- Create: `.github/workflows/ci.yml`, `package.json`, `package-lock.json` (by `npm install`), `.releaserc.json`, `.commitlintrc.json`, `.gitignore`
- Modify: `README.md` (replace the one-line placeholder)

**Interfaces:**
- Consumes: both actions (Tasks 2–3), by local path `./setup-hpy`, `./plugin-publish`.
- Produces: on push to `main`, tags `vX.Y.Z` and moves `v1`; `happyproto/actions/plugin-publish@v1` resolvable by Task 6.

- [ ] **Step 1: The workflow**

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Shellcheck
        run: shellcheck -x setup-hpy/*.sh plugin-publish/*.sh test/*.sh
      - name: Unit tests
        run: for t in test/*.test.sh; do echo "== $t"; bash "$t" || exit 1; done

  setup-hpy:
    needs: test
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4

      - name: Latest on the alpha channel
        id: latest
        uses: ./setup-hpy
        with:
          channel: alpha
      - name: hpy is on PATH for later steps
        env:
          VERSION: ${{ steps.latest.outputs.version }}
        run: |
          case "$VERSION" in *-alpha.*) ;; *) echo "::error::not an alpha: $VERSION"; exit 1 ;; esac
          test "$(hpy --version)" = "hpy $VERSION"

      - name: An exact version
        id: exact
        uses: ./setup-hpy
        with:
          version: v1.0.0-alpha.2
      - run: test "$(hpy --version)" = "hpy 1.0.0-alpha.2"

      - name: A malformed credential fails
        id: bad-credential
        continue-on-error: true
        uses: ./setup-hpy
        with:
          version: 1.0.0-alpha.2
          credential: not-a-credential
      - run: test "${{ steps.bad-credential.outcome }}" = failure

  plugin-publish:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # No real credential here: a bad one must stop the action before it
      # reaches the registry. Real publishes happen in happyproto/plugins.
      - name: A malformed credential stops before publishing
        id: publish
        continue-on-error: true
        uses: ./plugin-publish
        with:
          version: 0.0.1
          credential: not-a-credential
          dry-run: true
          hpy-version: 1.0.0-alpha.2
      - run: test "${{ steps.publish.outcome }}" = failure

  commitlint:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
      - run: npm ci
      - run: npx commitlint --from ${{ github.event.pull_request.base.sha }} --to ${{ github.event.pull_request.head.sha }} --verbose

  release:
    needs: [test, setup-hpy, plugin-publish]
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    permissions:
      contents: write
      issues: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
      - run: npm ci
      - name: Release
        id: release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: npx semantic-release
      # Consumers pin the major version, e.g. @v1.
      - name: Move the major version tag
        if: steps.release.outputs.new-release-published == 'true'
        env:
          VERSION: ${{ steps.release.outputs.new-release-version }}
        run: |
          major="v${VERSION%%.*}"
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git tag -fa "$major" -m "$major is v$VERSION"
          git push --force origin "$major"
```

Run: `actionlint .github/workflows/ci.yml`
Expected: no output.

Ruling (spec deviation): the spec's integration test mentions a fixture plugin in `test/fixture/`. The dry run with a malformed credential stops in setup, before any plugin is read, so no fixture is needed and none is added.

- [ ] **Step 2: Release tooling**

`package.json`:

```json
{
  "name": "happyproto-actions",
  "private": true,
  "description": "GitHub Actions for HappyProto",
  "license": "MIT",
  "devDependencies": {
    "@commitlint/cli": "^21.2.3",
    "@commitlint/config-conventional": "^21.2.3",
    "@semantic-release/changelog": "^7.0.0",
    "@semantic-release/git": "^11.0.1",
    "semantic-release": "^25.0.9",
    "semantic-release-export-data": "^1.2.0"
  }
}
```

`.releaserc.json`:

```json
{
  "branches": ["main"],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    ["@semantic-release/changelog", { "changelogFile": "CHANGELOG.md" }],
    ["@semantic-release/git", {
      "assets": ["CHANGELOG.md"],
      "message": "chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}"
    }],
    "@semantic-release/github",
    "semantic-release-export-data"
  ]
}
```

`.commitlintrc.json`:

```json
{ "extends": ["@commitlint/config-conventional"] }
```

`.gitignore`:

```
node_modules/
```

Run: `npm install && echo "feat: x" | npx commitlint && (echo "bad message" | npx commitlint >/dev/null 2>&1 || echo rejects)`
Expected: `package-lock.json` created, then `rejects`.

Run: `npx semantic-release --dry-run --no-ci --branches nonexistent 2>&1 | grep 'Loaded plugin' | wc -l`
Expected: 12 or more (every plugin loads; the run itself stops on the branch).

- [ ] **Step 3: The README**

`README.md`:

````markdown
# actions

GitHub Actions for [HappyProto](https://happyproto.at).

| Action | What it does |
| --- | --- |
| [`setup-hpy`](#setup-hpy) | Installs `hpy`, the HappyProto command line. |
| [`plugin-publish`](#plugin-publish) | Publishes a HappyView plugin release to the HappyProto registry. |

Both run on Linux and macOS runners. Pin the major version, e.g. `@v1`.

## Credentials

Publishing acts as your atproto account. Sign in once on your own machine and
store what it prints as a repository secret, e.g. `HPY_CREDENTIAL`:

```sh
hpy registry login --export
```

The credential is a session of its own: signing out locally doesn't break CI,
and you can revoke it with `HPY_CREDENTIAL=… hpy registry logout` or from the
HappyView dashboard. If it expires or is revoked, publishing fails with
`your session has expired or was revoked`; export a new one.

## `setup-hpy`

```yaml
- uses: happyproto/actions/setup-hpy@v1
  with:
    channel: alpha
```

| Input | Default | |
| --- | --- | --- |
| `version` | `latest` | An exact version (`1.0.0-alpha.2`), or `latest`. |
| `channel` | `stable` | `stable`, `beta` or `alpha`: which channel `latest` means. Channels are strict, as in `hpy` itself: `latest` on `alpha` is the newest alpha, never a newer stable. |
| `credential` | | Optional. Checked (a malformed secret fails here), never exported to later steps. |
| `github-token` | `github.token` | Only for looking up releases. |

Outputs: `version`, and `did` and `handle` when a credential was given.

## `plugin-publish`

Installs `hpy` (as `setup-hpy` does) and publishes the plugin in
`working-directory`. It does not build: build first.

```yaml
- uses: happyproto/actions/plugin-publish@v1
  with:
    version: 1.2.0
    credential: ${{ secrets.HPY_CREDENTIAL }}
    working-directory: plugins/my-plugin
    wasm: ../../target/wasm32-unknown-unknown/release/my_plugin.wasm
```

| Input | Default | |
| --- | --- | --- |
| `version` | | Required. The plugin version to publish. |
| `credential` | | Required. Passed to `hpy` alone. |
| `working-directory` | `.` | Where `hpy.toml` and `manifest.json` are. |
| `wasm` | | The built module, relative to `working-directory`. Omitted, `hpy` finds it. |
| `wait` | `true` | Wait until the registry has copied the artifact. Still `pending` after two minutes is a warning, not a failure. |
| `dry-run` | `false` | Validate and print the record without publishing. |
| `skip-existing` | `true` | When the registry already has this version, succeed with a notice. Versions are immutable, so the existing one is not compared with this build. |
| `hpy-version`, `hpy-channel` | `latest`, `stable` | Which `hpy` to use. |
| `github-token` | `github.token` | Only for looking up `hpy` releases. |

Outputs: `published` (`true`/`false`), `uri`, `status`, `hpy-version`.

### With semantic-release

Add [`semantic-release-export-data`](https://github.com/felipecrs/semantic-release-export-data)
to your release config, give the release step an `id`, and publish when it cut
a release:

```yaml
- id: release
  run: npx semantic-release
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
- if: steps.release.outputs.new-release-published == 'true'
  uses: happyproto/actions/plugin-publish@v1
  with:
    version: ${{ steps.release.outputs.new-release-version }}
    credential: ${{ secrets.HPY_CREDENTIAL }}
```

In a monorepo set up with `semantic-release-monorepo`, `new-release-version`
is the whole tag (`my-plugin-v1.2.0`), not the version: strip the prefix from
`new-release-git-tag` instead.

## Development

```sh
for t in test/*.test.sh; do bash "$t"; done   # unit tests
shellcheck -x setup-hpy/*.sh plugin-publish/*.sh test/*.sh
```

CI runs the unit tests, then the actions themselves on Ubuntu and macOS.
Releases are automatic on `main` from [Conventional Commits](https://www.conventionalcommits.org/)
(`fix:`, `feat:`, `feat!:`), and the major tag (`v1`) moves with each release.
````

- [ ] **Step 4: Full local check**

Run: `for t in test/*.test.sh; do bash "$t" || exit 1; done && shellcheck -x setup-hpy/*.sh plugin-publish/*.sh test/*.sh && actionlint`
Expected: fifteen `ok` lines, nothing else.

- [ ] **Step 5: Commit, push, and watch CI** (only with the user's go-ahead; pushing `main` cuts `v1.0.0`)

```bash
git add .github/workflows/ci.yml package.json package-lock.json .releaserc.json .commitlintrc.json .gitignore README.md docs/
git commit -m "feat: release the actions with semantic-release"
git push origin main
gh run watch --repo happyproto/actions --exit-status
```

Expected: `test`, both `setup-hpy` jobs, `plugin-publish` and `release` succeed; `gh release view v1.0.0 --repo happyproto/actions` exists and `git ls-remote --tags origin v1` shows the moved tag.

### Task 5: The plugins' release configs

**Files (in `happyproto/plugins`):**
- Create: `release/release-config.mjs`, `release/release-config.test.mjs`
- Modify: every `plugins/happyview/*/.releaserc.json` (18; `quickjs` has none), `package.json`, `package-lock.json`

**Interfaces:**
- Produces: `node release/release-config.mjs wasm DIR` → the `.wasm` asset path from the plugin's `.releaserc.json`, relative to `DIR`; `node release/release-config.mjs version DIR TAG` → the version the tag names. Exports `readConfig`, `wasmPath`, `versionOfTag`, `exportsData`.

Before starting: `git status --short` and leave every path it lists alone (Global Constraints). `package-lock.json` is already modified by the user: ask before running `npm install`, since it will add to that file.

- [ ] **Step 1: Write the helper and its tests**

`release/release-config.mjs`:

```js
// What the release workflows read from a plugin's `.releaserc.json`, so they
// and the tests share one reading of it.
//
//   node release/release-config.mjs wasm plugins/happyview/sql
//     prints the module `@semantic-release/github` uploads, relative to the
//     plugin's directory: ../../../target/wasm32-unknown-unknown/release/happyview_sql.wasm
//   node release/release-config.mjs version plugins/happyview/sql happyview-sql-v1.2.0
//     prints the version a release tag names: 1.2.0

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { argv, exit, stderr, stdout } from "node:process";

/** A plugin's `.releaserc.json`. */
export function readConfig(dir) {
  return JSON.parse(readFileSync(join(dir, ".releaserc.json"), "utf8"));
}

/** The configured plugins, each as `[name, options]`. */
function plugins(config) {
  return (config.plugins ?? []).map((p) => (Array.isArray(p) ? p : [p, {}]));
}

/** The one `.wasm` asset the GitHub release uploads. */
export function wasmPath(config) {
  const assets = plugins(config)
    .filter(([name]) => name === "@semantic-release/github")
    .flatMap(([, options]) => options.assets ?? [])
    .map((asset) => (typeof asset === "string" ? asset : asset.path))
    .filter((path) => path.endsWith(".wasm"));
  if (assets.length !== 1) {
    throw new Error(`expected one .wasm asset in the github plugin's assets, found ${assets.length}`);
  }
  return assets[0];
}

/** The version a release tag names, given the plugin's `tagFormat`. */
export function versionOfTag(config, tag) {
  const [prefix, suffix] = config.tagFormat.split("${version}");
  if (!tag.startsWith(prefix) || !tag.endsWith(suffix ?? "")) {
    throw new Error(`${tag} does not match the tag format ${config.tagFormat}`);
  }
  return tag.slice(prefix.length, tag.length - (suffix ?? "").length);
}

/** Whether the release exports its data for the workflow's later steps. */
export function exportsData(config) {
  return plugins(config).some(([name]) => name === "semantic-release-export-data");
}

if (import.meta.url === `file://${argv[1]}`) {
  const [command, dir, tag] = argv.slice(2);
  try {
    const config = readConfig(dir);
    if (command === "wasm") {
      stdout.write(`${wasmPath(config)}\n`);
    } else if (command === "version" && tag) {
      stdout.write(`${versionOfTag(config, tag)}\n`);
    } else {
      throw new Error("usage: release-config.mjs wasm DIR | version DIR TAG");
    }
  } catch (error) {
    stderr.write(`release-config: ${error.message}\n`);
    exit(1);
  }
}
```

`release/release-config.test.mjs`:

```js
// `node --test release/`: what the release workflows read from each plugin's
// `.releaserc.json`, and that every plugin is set up to be published.

import assert from "node:assert/strict";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";

import { exportsData, readConfig, versionOfTag, wasmPath } from "./release-config.mjs";

const ROOT = join(import.meta.dirname, "..", "plugins", "happyview");
const RELEASED = readdirSync(ROOT).filter((name) => {
  try {
    readConfig(join(ROOT, name));
    return true;
  } catch {
    return false; // a crate with no release of its own, e.g. quickjs
  }
});

test("every released plugin uploads exactly one module", () => {
  assert.ok(RELEASED.length > 0);
  for (const name of RELEASED) {
    assert.match(wasmPath(readConfig(join(ROOT, name))), /\.wasm$/, name);
  }
});

test("every released plugin exports its release data", () => {
  for (const name of RELEASED) {
    assert.ok(exportsData(readConfig(join(ROOT, name))), `${name} lacks semantic-release-export-data`);
  }
});

test("the version comes from the tag, not the plugin's name", () => {
  const config = { tagFormat: "happyview-sql-v${version}" };
  assert.equal(versionOfTag(config, "happyview-sql-v1.2.0"), "1.2.0");
  assert.equal(versionOfTag(config, "happyview-sql-v2.0.0-beta.1"), "2.0.0-beta.1");
  assert.throws(() => versionOfTag(config, "happyview-db-v1.2.0"), /does not match/);
});

test("a module path is read from string and object assets alike", () => {
  const config = (assets) => ({ plugins: [["@semantic-release/github", { assets }]] });
  assert.equal(wasmPath(config(["a/b.wasm", "manifest.json"])), "a/b.wasm");
  assert.equal(wasmPath(config([{ path: "a/b.wasm" }, { path: "manifest.json" }])), "a/b.wasm");
  assert.throws(() => wasmPath(config([{ path: "manifest.json" }])), /found 0/);
});
```

- [ ] **Step 2: Run them to see the export check fail**

Run: `node --test release/`
Expected: `every released plugin exports its release data` fails with `atproto lacks semantic-release-export-data`; the other three new tests and the existing `package-paths` tests pass.

- [ ] **Step 3: Add the plugin to every release config**

```bash
for f in plugins/happyview/*/.releaserc.json; do
  sed -i '' 's|^    "@semantic-release/release-notes-generator",$|    "@semantic-release/release-notes-generator",\n    "semantic-release-export-data",|' "$f"
done
for f in plugins/happyview/*/.releaserc.json; do jq empty "$f" || echo "bad $f"; done
```

Each now reads, e.g. `sql`:

```json
{
  "extends": "semantic-release-monorepo",
  "branches": ["main"],
  "tagFormat": "happyview-sql-v${version}",
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    "semantic-release-export-data",
    ["@semantic-release/exec", {
```

(On Linux, `sed -i` takes no `''`.)

Then: `npm install --save semantic-release-export-data@^1.2.0`

- [ ] **Step 4: Run the tests**

Run: `node --test release/ && node release/release-config.mjs wasm plugins/happyview/sql && node release/release-config.mjs version plugins/happyview/javascript happyview-javascript-v1.4.0`
Expected: all pass; then `../../../target/wasm32-unknown-unknown/release/happyview_sql.wasm` and `1.4.0`.

- [ ] **Step 5: Commit** (only with the user's go-ahead; stage these paths only)

```bash
git add release/release-config.mjs release/release-config.test.mjs package.json package-lock.json plugins/happyview/*/.releaserc.json
git commit -m "ci: export each release's data for the registry publish"
```

### Task 6: Publishing from the release job, and the recovery workflow

**Files (in `happyproto/plugins`):**
- Modify: `.github/workflows/release.yml` (the `release` job's last step)
- Create: `.github/workflows/publish-plugin.yml`

**Interfaces:**
- Consumes: `release/release-config.mjs` (Task 5); `happyproto/actions/plugin-publish@v1` (Task 4); repository secret `HPY_CREDENTIAL`.

- [ ] **Step 1: The release job**

In `release.yml`, give the `Release happyview/${{ matrix.plugin }}` step `id: release` and add the two steps after it, so the job ends:

```yaml
      - name: Release happyview/${{ matrix.plugin }}
        id: release
        working-directory: plugins/happyview/${{ matrix.plugin }}
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: npx --yes semantic-release

      # Not semantic-release-export-data's new-release-version: the monorepo
      # wrappers hand its generateNotes the tag in place of the version. The
      # tag is exact, and prepareCmd wrote the same version to manifest.json.
      - name: Read the released version
        id: version
        if: steps.release.outputs.new-release-published == 'true'
        env:
          DIR: plugins/happyview/${{ matrix.plugin }}
          TAG: ${{ steps.release.outputs.new-release-git-tag }}
        run: |
          version=$(node release/release-config.mjs version "$DIR" "$TAG")
          manifest=$(jq -r .version "$DIR/manifest.json")
          if [ "$version" != "$manifest" ]; then
            echo "::error::$TAG names $version, but manifest.json says $manifest"
            exit 1
          fi
          {
            echo "version=$version"
            echo "wasm=$(node release/release-config.mjs wasm "$DIR")"
          } >> "$GITHUB_OUTPUT"

      - name: Publish happyview/${{ matrix.plugin }} to the registry
        if: steps.release.outputs.new-release-published == 'true'
        uses: happyproto/actions/plugin-publish@v1
        with:
          version: ${{ steps.version.outputs.version }}
          credential: ${{ secrets.HPY_CREDENTIAL }}
          working-directory: plugins/happyview/${{ matrix.plugin }}
          wasm: ${{ steps.version.outputs.wasm }}
          hpy-channel: alpha
```

- [ ] **Step 2: The recovery workflow**

`.github/workflows/publish-plugin.yml`:

```yaml
# Publishes a plugin release that is already on GitHub to the registry, for
# when the release job cut the GitHub release but the registry publish
# failed: rerunning that job finds nothing new to release, so it would never
# try again. Builds the plugin from its release tag and publishes it; a
# version the registry already has is skipped, so running this twice is safe.
name: Publish a plugin release

on:
  workflow_dispatch:
    inputs:
      plugin:
        description: The plugin, as named under plugins/happyview/
        required: true
        type: choice
        options:
          - atproto
          - auth-itch
          - auth-microsoft
          - auth-steam
          - auth-xbox
          - backlinks
          - blobs
          - db
          - http
          - javascript
          - jobs
          - linked-repos
          - lua
          - record
          - spaces
          - sql
          - typescript
          - xrpc
      version:
        description: The version to publish, e.g. 1.2.0
        required: true
        type: string

permissions:
  contents: read

env:
  WASI_SDK_VERSION: "34.0"

jobs:
  publish:
    runs-on: ubuntu-24.04
    env:
      DIR: plugins/happyview/${{ inputs.plugin }}
    steps:
      - uses: actions/checkout@v4
        with:
          ref: happyview-${{ inputs.plugin }}-v${{ inputs.version }}

      - name: Find the module
        id: module
        run: |
          wasm=$(node release/release-config.mjs wasm "$DIR")
          # ../../../target/<triple>/release/<module>.wasm
          triple=$(basename "$(dirname "$(dirname "$wasm")")")
          {
            echo "wasm=$wasm"
            echo "triple=$triple"
            echo "crate=$(jq -r .id "$DIR/manifest.json")"
          } >> "$GITHUB_OUTPUT"

      - name: Add the target
        run: rustup target add ${{ steps.module.outputs.triple }}

      # The interpreters vendor C, compiled with clang from wasi-sdk.
      - name: Cache wasi-sdk
        if: steps.module.outputs.triple == 'wasm32-wasip1'
        id: wasi-sdk
        uses: actions/cache@v4
        with:
          path: /opt/wasi-sdk
          key: wasi-sdk-${{ env.WASI_SDK_VERSION }}-x86_64-linux

      - name: Install wasi-sdk
        if: steps.module.outputs.triple == 'wasm32-wasip1' && steps.wasi-sdk.outputs.cache-hit != 'true'
        run: |
          curl -fsSL -o /tmp/wasi-sdk.tar.gz \
            "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VERSION%%.*}/wasi-sdk-${WASI_SDK_VERSION}-x86_64-linux.tar.gz"
          mkdir -p /opt/wasi-sdk
          tar -xzf /tmp/wasi-sdk.tar.gz --strip-components=1 -C /opt/wasi-sdk

      - name: Build
        run: cargo build --release --target ${{ steps.module.outputs.triple }} -p ${{ steps.module.outputs.crate }}

      - uses: happyproto/actions/plugin-publish@v1
        with:
          version: ${{ inputs.version }}
          credential: ${{ secrets.HPY_CREDENTIAL }}
          working-directory: ${{ env.DIR }}
          wasm: ${{ steps.module.outputs.wasm }}
          hpy-channel: alpha
```

- [ ] **Step 3: Lint**

Run: `actionlint .github/workflows/release.yml .github/workflows/publish-plugin.yml`
Expected: no output.

Check the recovery workflow's plugin list against the released plugins:
`diff <(ls plugins/happyview | while read d; do [ -f plugins/happyview/$d/.releaserc.json ] && echo $d; done) <(sed -n '/options:/,/version:/p' .github/workflows/publish-plugin.yml | grep -- '- ' | sed 's/.*- //')`
Expected: no output.

- [ ] **Step 4: Commit** (only with the user's go-ahead)

```bash
git add .github/workflows/release.yml .github/workflows/publish-plugin.yml
git commit -m "ci: publish each plugin release to the registry"
```

Before this reaches `main`, the user must: commit the plugins' `hpy.toml` and profile files; add the `HPY_CREDENTIAL` secret (`hpy registry login --export`, as the account that owns the plugins' registry profiles); and have Task 4's `v1` tag published.

### Task 7: Point the CLI's CI docs at the action

**Files (in the CLI repo):**
- Modify: `README.md`, the `## Publishing from CI` section

- [ ] **Step 1: Edit**

After the paragraph ending `from the HappyView dashboard.` in `## Publishing from CI`, add:

````markdown
On GitHub Actions, [`happyproto/actions/plugin-publish`](https://github.com/happyproto/actions)
installs `hpy` and does the above in one step:

```yaml
- uses: happyproto/actions/plugin-publish@v1
  with:
    version: 1.2.0
    credential: ${{ secrets.HPY_CREDENTIAL }}
```
````

- [ ] **Step 2: Commit** (only with the user's go-ahead)

```bash
git add README.md
git commit -m "docs: point CI publishing at the plugin-publish action"
```
