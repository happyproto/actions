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
