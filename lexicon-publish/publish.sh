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

# Every lexicon's NSID. A JSON file without a lexicon `id` is not one.
nsids=""
if [[ -d "$dir" ]]; then
  nsids=$(find "$dir" -name '*.json' -type f -exec jq -r 'select(.lexicon != null) | .id // empty' {} + | sort -u)
fi
if [[ -z "$nsids" ]]; then
  echo "::error::no lexicons under $dir"
  exit 1
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
  goat lex status --lexicons-dir "$dir"
else
  GOAT_USERNAME="$IDENTIFIER" GOAT_PASSWORD="$PASSWORD" \
    goat lex publish --update --lexicons-dir "$dir"
fi
