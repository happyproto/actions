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
