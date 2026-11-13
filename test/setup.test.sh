#!/usr/bin/env bash
# setup-hpy/setup.sh's choice of source, against a stub `npm` whose global
# install writes a stub `hpy`. The installer source is tested for real in CI.
#
# Each test runs in a subshell of its own, with its own $WORK, by design.
# shellcheck disable=SC2031
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/lib.sh
. "$here/lib.sh"
setup="$here/../setup-hpy/setup.sh"

# A stub npm in $WORK/bin: `npm install -g hpy@V` puts an `hpy` printing
# `hpy V` in $WORK/prefix/bin, and `npm prefix -g` prints $WORK/prefix. Each
# call is logged to npm.log.
stub_npm() {
  mkdir -p "$WORK/bin" "$WORK/prefix/bin"
  cat > "$WORK/bin/npm" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$WORK/npm.log"
case "\$1" in
  prefix) echo "$WORK/prefix" ;;
  install)
    for a in "\$@"; do
      case "\$a" in
        hpy@*) printf '#!/bin/sh\necho "hpy %s"\n' "\${a#hpy@}" > "$WORK/prefix/bin/hpy"
               chmod +x "$WORK/prefix/bin/hpy" ;;
      esac
    done ;;
esac
STUB
  chmod +x "$WORK/bin/npm"
}

# Runs setup.sh for an exact version, overridden by NAME=value args.
run_setup() {
  env PATH="$WORK/bin:$PATH" GITHUB_OUTPUT="$WORK/output" GITHUB_PATH="$WORK/path" \
    VERSION=1.0.0-alpha.40 CHANNEL=alpha CREDENTIAL= GITHUB_TOKEN= RUNNER_OS=Linux "$@" "$setup"
}

test_npm_installs_that_version_of_the_hpy_package() {
  stub_npm
  run_setup SOURCE=npm >/dev/null 2>&1 || fail "setup failed"
  assert_contains "$(cat "$WORK/npm.log")" "install -g --no-fund --no-audit hpy@1.0.0-alpha.40"
  assert_eq "$WORK/prefix/bin" "$(cat "$WORK/path")" GITHUB_PATH
  assert_contains "$(cat "$WORK/output")" "version=1.0.0-alpha.40"
}

test_npm_needs_npm() {
  local out tool
  # A PATH with only what setup.sh needs before it looks for npm.
  mkdir -p "$WORK/only"
  for tool in bash env dirname; do ln -s "$(command -v "$tool")" "$WORK/only/$tool"; done
  out=$(env PATH="$WORK/only" GITHUB_OUTPUT="$WORK/output" GITHUB_PATH="$WORK/path" \
    VERSION=1.0.0 SOURCE=npm RUNNER_OS=Linux bash "$setup" 2>&1) && fail "setup succeeded without npm"
  assert_contains "$out" "needs Node 22.20 or newer"
}

test_windows_needs_the_npm_source() {
  local out
  out=$(run_setup SOURCE=installer RUNNER_OS=Windows 2>&1) && fail "setup succeeded"
  assert_contains "$out" "set \`source: npm\`"
}

test_an_unknown_source_is_refused() {
  local out
  out=$(run_setup SOURCE=cargo 2>&1) && fail "setup succeeded"
  assert_contains "$out" "\`cargo\` is not a source"
}

run_tests
