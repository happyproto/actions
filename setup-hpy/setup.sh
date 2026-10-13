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
