#!/usr/bin/env bash
# Installs a pinned goat, Bluesky's atproto CLI, checked against the release's
# own checksums, and puts it on $GITHUB_PATH.
#
# Environment:
#   GOAT_VERSION  e.g. 0.2.6 (a leading v is allowed)
set -euo pipefail

version="${GOAT_VERSION:?the goat-version input is required}"
version="${version#v}"

case "$(uname -s)" in
  Linux) os=Linux ;;
  Darwin) os=Darwin ;;
  *) echo "::error::lexicon-publish runs on Linux and macOS runners, not $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "::error::no goat build for $(uname -m)"; exit 1 ;;
esac

asset="goat_${os}_${arch}.tar.gz"
base="https://github.com/bluesky-social/goat/releases/download/v$version"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if ! curl -fsSL --retry 3 -o "$tmp/$asset" "$base/$asset" \
  || ! curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$base/goat_${version}_checksums.txt"; then
  echo "::error::goat $version does not exist (no $asset at $base)"
  exit 1
fi

expected=$(awk -v f="$asset" '$2 == f { print $1 }' "$tmp/checksums.txt")
if command -v sha256sum >/dev/null; then
  actual=$(sha256sum "$tmp/$asset" | cut -d' ' -f1)
else
  actual=$(shasum -a 256 "$tmp/$asset" | cut -d' ' -f1)
fi
if [[ -z "$expected" || "$actual" != "$expected" ]]; then
  echo "::error::$asset does not match goat $version's checksums (expected ${expected:-none}, got $actual)"
  exit 1
fi

bin="${RUNNER_TEMP:-$tmp}/goat-$version"
mkdir -p "$bin"
tar -xzf "$tmp/$asset" -C "$bin" goat
echo "$bin" >> "$GITHUB_PATH"
"$bin/goat" --version
