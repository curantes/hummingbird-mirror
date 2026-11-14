#!/usr/bin/env bash
# Checks that the image tables in the README list exactly the tags in
# mirror/images.yaml. Entries are added and removed by hand or by the
# stream watcher's pull requests, and the tables are not generated, so
# without this check they go stale.
#
# It reads the tables between the "## Available Images" heading and the
# next "## " heading. The first cell of a row holds the image name and the
# second its tags, each in backticks. A range `3.11`–`3.15` (en dash)
# stands for every tag between the two whose last number counts up, with
# the same suffix on both ends: `3.11-builder`–`3.13-builder`.
#
# Exit codes: 0 identical, 1 they differ, 2 usage or input error.
#
# The patterns match Markdown backticks in single quotes, on purpose.
# shellcheck disable=SC2016
set -euo pipefail
# sort and comm must agree on the order whatever the caller's locale is.
export LC_ALL=C

README="${1:-README.md}"
IMAGES="${2:-mirror/images.yaml}"
for file in "$README" "$IMAGES"; do
  if [ ! -s "$file" ]; then
    echo "'$file' is missing or empty" >&2
    exit 2
  fi
done

indent() { while read -r line; do echo "  $line"; done; }

# <start>–<end> as one tag per line
expand() {
  local name="$1" first="$2" last="$3" version suffix prefix from to
  version="${first%%-*}"
  suffix="${first#"$version"}"
  prefix="${version%.*}"
  from="${version##*.}"
  to="${last%%-*}"
  if [ "${last#"$to"}" != "$suffix" ] || [ "${to%.*}" != "$prefix" ] || [ "$version" = "$prefix" ] \
      || ! [[ "$from" =~ ^[0-9]+$ && "${to##*.}" =~ ^[0-9]+$ ]] || [ "$from" -ge "${to##*.}" ]; then
    echo "README: cannot expand the range \`$first\`–\`$last\` of $name" >&2
    return 2
  fi
  for ((i = from; i <= ${to##*.}; i++)); do
    echo "$name:$prefix.$i$suffix"
  done
}

readme_tags() {
  local name tags item
  awk '/^## Available Images/ { on = 1; next } /^## / { on = 0 } on && /^\| / { print }' "$README" \
    | while IFS='|' read -r _ name tags _; do
        # The name is the first backticked word, also inside a link.
        name="$(grep -oE '`[^`]+`' <<< "$name" | head -n 1 | tr -d '`' || true)"
        [ -n "$name" ] || continue
        while read -r item; do
          item="${item//\`/}"
          if [[ "$item" == *–* ]]; then
            # Explicit: errexit is off inside a command substitution with ||.
            expand "$name" "${item%%–*}" "${item##*–}" || exit 2
          else
            echo "$name:$item"
          fi
        done < <(grep -oE '`[^`]+`(–`[^`]+`)?' <<< "$tags" || true)
      done
}

IN_README="$(readme_tags | sort)" || exit 2
IN_IMAGES="$(sed -nE 's|^[[:space:]]*source:[[:space:]]*[^[:space:]:@]*/([^/[:space:]:@]+):([^[:space:]@]+)@sha256:[a-f0-9]{64}[[:space:]]*$|\1:\2|p' "$IMAGES" | sort)"
if [ -z "$IN_IMAGES" ]; then
  echo "No entries found in $IMAGES" >&2
  exit 2
fi

DUPLICATES="$(uniq -d <<< "$IN_README")"
MISSING="$(comm -13 <(sort -u <<< "$IN_README") <(sort -u <<< "$IN_IMAGES"))"
EXTRA="$(comm -23 <(sort -u <<< "$IN_README") <(sort -u <<< "$IN_IMAGES"))"
if [ -z "$DUPLICATES$MISSING$EXTRA" ]; then
  echo "The README tables list the $(wc -l <<< "$IN_IMAGES") tags in $IMAGES"
  exit 0
fi
if [ -n "$MISSING" ]; then
  echo "In $IMAGES but not in the README tables:"
  indent <<< "$MISSING"
fi
if [ -n "$EXTRA" ]; then
  echo "In the README tables but not in $IMAGES:"
  indent <<< "$EXTRA"
fi
if [ -n "$DUPLICATES" ]; then
  echo "Listed more than once in the README tables:"
  indent <<< "$DUPLICATES"
fi
exit 1
