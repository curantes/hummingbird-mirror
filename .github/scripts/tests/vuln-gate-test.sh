#!/usr/bin/env bash
# Fixture tests for vuln-gate.sh. Run from anywhere; needs bash and jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../vuln-gate.sh"
FIX="$HERE/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
CASES=0

# run <description> <expected exit code> <gate arguments...>
# Leaves the output in $WORK/out and the result JSON in $WORK/result.json.
run() {
  local desc="$1" want="$2" got
  shift 2
  CASES=$((CASES + 1))
  DESC="$desc"
  rm -f "$WORK/result.json"
  "$GATE" "$@" --result "$WORK/result.json" > "$WORK/out" 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc: exit code $got, expected $want"
    sed 's/^/       /' "$WORK/out"
    FAILED=$((FAILED + 1))
  fi
}

# expect <jq filter that must be true for the last result>
expect() {
  if ! jq -e "$1" "$WORK/result.json" > /dev/null 2>&1; then
    echo "FAIL - $DESC: result does not satisfy: $1"
    FAILED=$((FAILED + 1))
  fi
}

# output_has <text that the last output must contain>
output_has() {
  if ! grep -qF -- "$1" "$WORK/out"; then
    echo "FAIL - $DESC: output lacks '$1'"
    FAILED=$((FAILED + 1))
  fi
}

# --- new-stream: absolute gate ---
run "new-stream passes without findings" 0 --mode new-stream --new "$FIX/empty.json"
expect '.pass and .counts.findings == 0'

run "new-stream ignores unfixed and below-HIGH matches" 0 --mode new-stream --new "$FIX/clean.json"
expect '.pass and .counts.findings == 0'

run "new-stream fails on fixable HIGH/CRITICAL findings" 1 --mode new-stream --new "$FIX/baseline.json"
expect '(.pass | not) and .counts.findings == 3 and .counts.critical == 1 and .counts.high == 2'
output_has "CVE-2026-1002"

run "new-stream ignores a baseline" 1 --mode new-stream --new "$FIX/baseline.json" --baseline "$FIX/baseline.json"

# --- refresh: regression gate ---
run "refresh passes when findings are fixed and none added" 0 \
  --mode refresh --new "$FIX/refresh-fewer.json" --baseline "$FIX/baseline.json"
expect '.pass and .counts.regressions == 0 and .counts.fixed == 1 and .counts.remaining == 2'
expect '.fixed[0].id == "CVE-2026-1002"'

run "refresh treats a version bump with the same CVE as remaining" 0 \
  --mode refresh --new "$FIX/refresh-version-bump.json" --baseline "$FIX/baseline.json"
expect '.pass and .counts.regressions == 0 and .counts.fixed == 0 and .counts.remaining == 3'

run "refresh fails on a new finding and names it" 1 \
  --mode refresh --new "$FIX/refresh-regression.json" --baseline "$FIX/baseline.json"
expect '(.pass | not) and .counts.regressions == 1 and .regressions[0].id == "CVE-2026-1003" and .regressions[0].package == "zlib"'
expect '.counts.fixed == 1 and .counts.remaining == 2'
output_has "CVE-2026-1003"

run "refresh against an empty baseline fails on any finding" 1 \
  --mode refresh --new "$FIX/refresh-fewer.json" --baseline "$FIX/empty.json"
expect '(.pass | not) and .counts.regressions == 2 and .counts.remaining == 0'

run "refresh against an empty baseline passes without findings" 0 \
  --mode refresh --new "$FIX/clean.json" --baseline "$FIX/empty.json"
expect '.pass and .counts.regressions == 0'

run "refresh to a clean digest reports everything fixed" 0 \
  --mode refresh --new "$FIX/empty.json" --baseline "$FIX/baseline.json"
expect '.pass and .counts.fixed == 3 and .counts.findings == 0'

# --- audit: report only ---
run "audit never fails on findings" 0 --mode audit --new "$FIX/baseline.json"
expect '.pass and .counts.findings == 3'
output_has "GHSA-aaaa-bbbb-cccc"

run "audit passes without findings" 0 --mode audit --new "$FIX/empty.json"
expect '.pass and .counts.findings == 0'

# --- input errors must not read as a pass ---
run "refresh without a baseline is a usage error" 2 --mode refresh --new "$FIX/empty.json"
run "unknown mode is a usage error" 2 --mode strict --new "$FIX/empty.json"
run "missing report is an error" 2 --mode audit --new "$FIX/does-not-exist.json"
run "missing baseline report is an error" 2 \
  --mode refresh --new "$FIX/empty.json" --baseline "$FIX/does-not-exist.json"
run "a file that isn't a Grype report is an error" 2 --mode new-stream --new "$FIX/not-grype.json"
run "a baseline that isn't a Grype report is an error" 2 \
  --mode refresh --new "$FIX/empty.json" --baseline "$FIX/not-grype.json"

# --- summary output ---
run "summary names the image and the regression" 1 --mode refresh --label "go:1.27 (amd64)" \
  --new "$FIX/refresh-regression.json" --baseline "$FIX/baseline.json" --summary "$WORK/summary.md"
if ! grep -qF 'go:1.27 (amd64)' "$WORK/summary.md" || ! grep -qF 'CVE-2026-1003' "$WORK/summary.md"; then
  echo "FAIL - $DESC: summary lacks the label or the regression"
  FAILED=$((FAILED + 1))
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED check(s) failed in $CASES cases"
  exit 1
fi
echo "All $CASES cases passed"
