#!/usr/bin/env bash
# Installs hpy and, given a credential, checks it. setup-hpy/action.yml runs
# it, and so does plugin-publish/action.yml, so both install hpy the same way.
#
# Environment (setup-hpy's inputs):
#   VERSION       an exact hpy version, or latest (default)
#   CHANNEL       stable (default), beta or alpha: what latest means
#   SOURCE        installer (default): the release's installer and binary;
#                 npm: the npm package `hpy` (needs Node 22.20 or newer, and
#                 works on Windows runners too)
#   CREDENTIAL    optional HPY_CREDENTIAL; checked, never exported
#   GITHUB_TOKEN  for the GitHub API call that resolves latest
# Writes version, did and handle to $GITHUB_OUTPUT and hpy's directory to
# $GITHUB_PATH.
set -euo pipefail

source="${SOURCE:-installer}"
case "$source" in
  installer | npm) ;;
  *) echo "::error::\`$source\` is not a source; choose installer or npm"; exit 1 ;;
esac
if [[ "${RUNNER_OS:-}" == Windows && "$source" != npm ]]; then
  echo "::error::on Windows runners, set \`source: npm\`: the installer runs on Linux and macOS"
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

# hpy's musl build (Alpine job containers) needs libstdc++, and the installer
# refuses it when it is missing. As root with apk, add it here instead.
musl_runtime() {
  [[ "$(uname -s)" == Linux ]] || return 0
  # musl's ldd exits 1 for --version; pipefail must not take that as no match.
  { ldd --version 2>&1 || true; } | grep -q musl || return 0
  local d
  for d in /usr/lib /lib /usr/local/lib; do
    [[ -e "$d/libstdc++.so.6" ]] && return 0
  done
  if [[ "$(id -u)" == 0 ]] && command -v apk >/dev/null; then
    echo "::notice::installing libstdc++, which hpy's musl build needs"
    apk add --no-cache libstdc++ >/dev/null
  fi
}

from_installer() {
  musl_runtime
  installer="$(mktemp)"
  trap 'rm -f "$installer"' EXIT
  url="https://github.com/$repo/releases/download/v$version/hpy-cli-installer.sh"
  if ! curl -fsSL --retry 3 -o "$installer" "$url"; then
    echo "::error::hpy $version does not exist (no installer at $url)"
    exit 1
  fi
  HPY_CLI_NO_MODIFY_PATH=1 sh "$installer" --quiet
  bin="${CARGO_HOME:-$HOME/.cargo}/bin"
}

from_npm() {
  if ! command -v npm >/dev/null; then
    echo "::error::\`source: npm\` needs Node 22.20 or newer and npm on PATH (actions/setup-node)"
    exit 1
  fi
  if ! npm install -g --no-fund --no-audit "hpy@$version" >&2; then
    echo "::error::could not install hpy $version from npm"
    exit 1
  fi
  bin="$(npm prefix -g)"
  # npm puts global commands in <prefix>/bin, except on Windows.
  if [[ "${RUNNER_OS:-}" != Windows ]]; then bin="$bin/bin"; fi
}

if [[ "$source" == npm ]]; then from_npm; else from_installer; fi
echo "$bin" >> "$GITHUB_PATH"
if [[ "${RUNNER_OS:-}" == Windows ]]; then
  PATH="$(cygpath -u "$bin"):$PATH"
  export PATH
else
  export PATH="$bin:$PATH"
fi

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
