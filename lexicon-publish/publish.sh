#!/usr/bin/env bash
# Publishes a directory of lexicons as com.atproto.lexicon.schema records in
# one account's repo, with goat (lexicon-publish/action.yml installs it).
#
# A PDS finds a lexicon through DNS: `_lexicon.<authority>` TXT names the DID
# whose repo holds it. goat publishes only the NSIDs whose DNS already names
# the account, and skips the rest with a warning and a zero exit, so a missing
# record would go unnoticed. This checks every authority first and fails
# naming each TXT record to add.
#
# Environment (the action's inputs):
#   IDENTIFIER    handle or DID of the account the lexicons belong to
#   PASSWORD      an app password for it; not needed for a dry run
#   LEXICONS_DIR  the lexicon files, laid out by NSID (default lexicons)
#   DRY_RUN       true: report what would change (goat lex status) instead
#   INCLUDE       NSID prefixes to publish, comma or newline separated; empty
#                 means all of them
#   EXCLUDE       NSID prefixes to leave out, applied after INCLUDE
#
# A prefix matches whole segments: dev.happyview matches dev.happyview and
# dev.happyview.adminFull, never dev.happyviewer.thing. With either filter set,
# the selected files are copied to a temporary directory and goat is given that
# copy, so it never sees a lexicon that wasn't checked.
set -euo pipefail

: "${IDENTIFIER:?the identifier input is required}"
dir="${LEXICONS_DIR:-lexicons}"
dry_run="${DRY_RUN:-false}"

if [[ -n "${PASSWORD:-}" ]]; then
  echo "::add-mask::$PASSWORD"
elif [[ "$dry_run" != true ]]; then
  echo "::error::publishing needs the password input: an app password for $IDENTIFIER"
  exit 1
fi

# One prefix a line, without blanks or surrounding spaces.
prefixes() {
  tr ',' '\n' <<<"$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true
}
include=$(prefixes "${INCLUDE:-}")
exclude=$(prefixes "${EXCLUDE:-}")

matches() { # nsid prefixes
  local prefix
  while read -r prefix; do
    [[ -n "$prefix" ]] || continue
    if [[ "$1" == "$prefix" || "$1" == "$prefix".* ]]; then return 0; fi
  done <<<"$2"
  return 1
}

selected() { # nsid
  if [[ -n "$include" ]] && ! matches "$1" "$include"; then return 1; fi
  if [[ -n "$exclude" ]] && matches "$1" "$exclude"; then return 1; fi
  return 0
}

# Every selected lexicon, as "<nsid> <file>". A JSON file without a lexicon
# `id` is not one.
lexicons=""
if [[ -d "$dir" ]]; then
  while IFS= read -r file; do
    nsid=$(jq -r 'select(.lexicon != null) | .id // empty' "$file")
    if [[ -n "$nsid" ]] && selected "$nsid"; then
      lexicons+="$nsid $file"$'\n'
    fi
  done < <(find "$dir" -name '*.json' -type f | sort)
fi
nsids=$(cut -d' ' -f1 <<<"$lexicons" | grep -v '^$' | sort -u || true)
if [[ -z "$nsids" ]]; then
  filters="${include:+ include: $(tr '\n' ' ' <<<"$include")}${exclude:+ exclude: $(tr '\n' ' ' <<<"$exclude")}"
  echo "::error::no lexicons under $dir${filters:+ match${filters}}"
  exit 1
fi

# goat publishes a whole directory, so a filtered run gives it a copy holding
# only the selected files, laid out as they were.
publish_dir="$dir"
if [[ -n "$include$exclude" ]]; then
  publish_dir=$(mktemp -d)
  trap 'rm -rf "$publish_dir"' EXIT
  while read -r _ file; do
    [[ -n "$file" ]] || continue
    rel="${file#"$dir"/}"
    mkdir -p "$publish_dir/$(dirname "$rel")"
    cp "$file" "$publish_dir/$rel"
  done <<<"$lexicons"
  echo "Publishing $(wc -l <<<"$nsids" | tr -d ' ') of the lexicons under $dir"
fi

# An NSID's authority is its domain: every segment but the name, reversed.
# com.example.thing.record -> thing.example.com
authorities=$(while read -r nsid; do
  echo "$nsid" | awk -F. '{ out = $(NF-1); for (i = NF-2; i >= 1; i--) out = out "." $i; print out }'
done <<<"$nsids" | sort -u)

did=$(goat resolve "$IDENTIFIER" | jq -r '.id // empty') || did=""
if [[ -z "$did" ]]; then
  echo "::error::$IDENTIFIER did not resolve to a DID"
  exit 1
fi

missing=""
while read -r authority; do
  name="_lexicon.$authority"
  found=$(dig +short TXT "$name" | tr -d '"')
  if [[ "$found" != "did=$did" ]]; then
    missing+="  $name TXT \"did=$did\"${found:+  (now: $found)}"$'\n'
  fi
done <<<"$authorities"
if [[ -n "$missing" ]]; then
  echo "::error::lexicon DNS does not name $did for every authority; add these TXT records:"
  printf '%s' "$missing"
  exit 1
fi
echo "Every authority's DNS names $did: $(echo "$authorities" | tr '\n' ' ')"

if [[ "$dry_run" == true ]]; then
  goat lex status --lexicons-dir "$publish_dir"
else
  GOAT_USERNAME="$IDENTIFIER" GOAT_PASSWORD="$PASSWORD" \
    goat lex publish --update --lexicons-dir "$publish_dir"
fi
