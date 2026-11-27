#!/usr/bin/env bash
# Tests for rollback-guard.sh. Run from anywhere; needs bash, jq and GNU date.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/../rollback-guard.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
CASES=0
OLD="sha256:$(printf '%064d' 1)"
NEW="sha256:$(printf '%064d' 2)"
OTHER="sha256:$(printf '%064d' 3)"

# image <file> <created label>: what `docker image inspect` prints
image() {
  jq -n --arg t "$2" '[{Config: {Labels: {"org.opencontainers.image.created": $t}}}]' > "$WORK/$1"
}
fail() {
  echo "FAIL - $1"
  sed 's/^/       /' "$WORK/out"
  FAILED=$((FAILED + 1))
}
# run <description> <expected exit code> <new file> <baseline file> [arguments...]
run() {
  local desc="$1" want="$2" new="$3" base="$4" got
  shift 4
  CASES=$((CASES + 1))
  DESC="$desc"
  "$GUARD" --new "$WORK/$new" --new-digest "$NEW" \
    --baseline "$WORK/$base" --baseline-digest "$OLD" "$@" > "$WORK/out" 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then echo "ok   - $desc"; else fail "$desc: exit code $got, expected $want"; fi
}
output_has() {
  grep -qF -- "$1" "$WORK/out" || fail "$DESC: output lacks '$1'"
}

image early 2026-11-21T17:14:53Z
image late 2026-11-21T21:20:04Z
image second-later 2026-11-21T17:14:54Z
image year-later 2027-01-01T00:00:00Z
image early-offset 2026-11-21T19:14:53+02:00
image looks-later 2026-11-21T18:00:00+02:00
image looks-earlier 2026-11-21T16:00:00-02:00
image fraction 2026-11-21T17:14:53.123456789Z
image empty-time ""
image relative yesterday
image date-only 2026-11-21
image impossible 2026-02-31T00:00:00Z
echo '[{"Config": {"Labels": {}}}]' > "$WORK/no-label"
echo '[{"Config": {"Labels": null}}]' > "$WORK/null-labels"
echo '[{"Config": {"Labels": {"org.opencontainers.image.created": 1795328399}}}]' > "$WORK/number"
echo '[]' > "$WORK/empty-array"
echo 'not json' > "$WORK/not-json"
: > "$WORK/empty-file"
jq -s 'add' "$WORK/late" "$WORK/late" > "$WORK/two-images"

# --- the comparison ---
run "a newer build passes" 0 late early
run "one second newer passes" 0 second-later early
run "the next year passes" 0 year-later late
run "the same time passes" 0 early early
run "the same instant in another offset passes" 0 early-offset early
run "fractional seconds are accepted" 0 fraction early
run "an offset that looks earlier and is later passes" 0 looks-earlier early
run "an older build fails" 1 early late
output_has "2026-11-21T17:14:53Z"
output_has "$OLD $NEW"
run "one second older fails" 1 early second-later
run "the previous year fails" 1 late year-later
run "an offset that looks later and is earlier fails" 1 looks-later early

# --- an unknown time must not read as a pass ---
for bad in empty-time relative date-only impossible no-label null-labels number empty-array not-json empty-file two-images missing-file; do
  run "new digest with $bad is an error" 2 "$bad" early
  run "baseline with $bad is an error" 2 late "$bad"
done

# --- the override allows exactly one step ---
echo "$OLD $NEW  # upstream withdrew the build" > "$WORK/allowed"
run "an allowed rollback passes" 0 early late --allow "$WORK/allowed"
output_has "ALLOWED"
run "an allowed step passes without a build time" 0 no-label late --allow "$WORK/allowed"
echo "$OLD $NEW" > "$WORK/no-reason"
run "the reason is optional" 0 early late --allow "$WORK/no-reason"

echo "$OTHER $NEW" > "$WORK/other-baseline"
run "another baseline is not allowed" 1 early late --allow "$WORK/other-baseline"
echo "$OLD $OTHER" > "$WORK/other-new"
run "another new digest is not allowed" 1 early late --allow "$WORK/other-new"
echo "$NEW $OLD" > "$WORK/reversed"
run "the reverse step is not allowed" 1 early late --allow "$WORK/reversed"
echo "# $OLD $NEW" > "$WORK/commented"
run "a commented line allows nothing" 1 early late --allow "$WORK/commented"
echo "$OLD $NEW $OTHER" > "$WORK/third-field"
run "a line with a third digest allows nothing" 1 early late --allow "$WORK/third-field"
run "a missing allow file allows nothing" 1 early late --allow "$WORK/does-not-exist"
run "an empty allow file allows nothing" 1 early late --allow "$WORK/empty-file"

# --- usage and summary ---
run "a malformed digest is a usage error" 2 late early --new-digest latest
run "an unknown option is a usage error" 2 late early --force yes
run "the summary names the image" 1 early late --summary "$WORK/summary" --label "haproxy:3.0 (amd64)"
grep -qF 'haproxy:3.0 (amd64)' "$WORK/summary" || fail "$DESC: summary lacks the label"

echo
if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED check(s) failed in $CASES cases"
  exit 1
fi
echo "All $CASES cases passed"
