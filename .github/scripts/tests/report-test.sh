#!/usr/bin/env bash
# Tests for job-report.sh and mirror-report.sh. Run from anywhere; needs
# bash and jq. The gate results come from vuln-gate.sh and its fixtures.
#
# The expected Markdown has backticks in single quotes, on purpose.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOB_REPORT="$HERE/../job-report.sh"
MIRROR_REPORT="$HERE/../mirror-report.sh"
GATE="$HERE/../vuln-gate.sh"
FIX="$HERE/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
CASES=0

DIGEST="sha256:$(printf '%064d' 1)"
OK_STEPS='{"checkout":{"outcome":"success","conclusion":"success","outputs":{}}}'

# check <description> <command...>: the command must succeed
check() {
  local desc="$1"
  shift
  CASES=$((CASES + 1))
  if "$@" > "$WORK/check.out" 2>&1; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc"
    sed 's/^/       /' "$WORK/check.out"
    FAILED=$((FAILED + 1))
  fi
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }
field() { jq -e "$2" "$1" > /dev/null; }

# report <directory> <job-report arguments...>
report() {
  local dir="$1"
  shift
  "$JOB_REPORT" --out-dir "$dir" "$@" > /dev/null
}
# entry <directory> <name> <tag>: passing verify and test-scan reports
entry() {
  local dir="$1" name="$2" tag="$3" src
  src="registry.example/hi/$name:$tag@$DIGEST"
  report "$dir" --job verify --name "$name" --source "$src" --status success --steps "$OK_STEPS" --mode audit
  for arch in amd64 arm64; do
    report "$dir" --job test-scan --arch "$arch" --name "$name" --source "$src" --status success \
      --steps "$OK_STEPS" --gate "$WORK/audit.json"
  done
}

"$GATE" --mode audit --new "$FIX/baseline.json" --result "$WORK/audit.json" > /dev/null
"$GATE" --mode refresh --new "$FIX/refresh-regression.json" --baseline "$FIX/baseline.json" \
  --result "$WORK/regression.json" > /dev/null
"$GATE" --mode new-stream --new "$FIX/baseline.json" --result "$WORK/new-stream.json" > /dev/null

# --- job-report.sh ---
R="$WORK/single"
GITHUB_OUTPUT="$WORK/output" "$JOB_REPORT" --out-dir "$R" --job test-scan --arch arm64 --name php \
  --source "registry.example/hi/php:8.5-fpm@$DIGEST" --status failure --gate "$WORK/regression.json" \
  --steps '{"pull-image":{"outcome":"success"},"vulnerability-gate":{"outcome":"failure"},"report":{"outcome":"skipped"}}' \
  > /dev/null
F="$R/report-php--8.5-fpm--arm64.json"
check "job report is named after name, tag and architecture" test -s "$F"
check "job report sets the artifact output" has "$WORK/output" "artifact=report-php--8.5-fpm--arm64"
check "job report records image, tag, digest and job" field "$F" \
  ".image == \"php\" and .tag == \"8.5-fpm\" and .digest == \"$DIGEST\" and .job == \"test-scan\" and .architecture == \"arm64\""
check "job report names the failing step" field "$F" '.status == "failure" and .failedStep == "vulnerability-gate"'
check "job report takes mode, counts and regressions from the gate" field "$F" \
  '.mode == "refresh" and .counts.regressions == 1 and .blockingTotal == 1 and .blocking[0].id == "CVE-2026-1003"'

report "$R" --job test-scan --arch amd64 --name go --source "registry.example/hi/go:1.27@$DIGEST" \
  --status failure --gate "$WORK/new-stream.json" --steps '{"vulnerability-gate":{"outcome":"failure"}}'
check "a failed new stream lists every finding as blocking" field "$R/report-go--1.27--amd64.json" \
  '.mode == "new-stream" and .blockingTotal == 3 and (.blocking | length) == 3'

report "$R" --job test-scan --arch amd64 --name nginx --source "registry.example/hi/nginx:1.30@$DIGEST" \
  --status success --gate "$WORK/audit.json" --steps "$OK_STEPS"
check "a passing audit has counts but nothing blocking" field "$R/report-nginx--1.30--amd64.json" \
  '.failedStep == null and .counts.findings == 3 and .blocking == [] and .blockingTotal == 0'

report "$R" --job verify --name go --source "not a reference" --status failure --steps 'not json' \
  --gate "$WORK/missing.json"
check "job report survives unreadable inputs" field "$R/report-go--not_a_reference--verify.json" \
  '.status == "failure" and .failedStep == null and .digest == null and .counts == null'

report "$R" --job promote --name go --source "registry.example/hi/go:1.27@$DIGEST" --status success \
  --steps "$OK_STEPS" --mode refresh --tags "1.27 1.27.3 1.27.3-20261114T000000Z" --approved false
check "promote report records tags and approval" field "$R/report-go--1.27--promote.json" \
  '.mode == "refresh" and (.tags | length) == 3 and .alreadyApproved == false'

CASES=$((CASES + 1))
"$JOB_REPORT" --job test-scan --name go --source x --status success --out-dir "$R" > /dev/null 2>&1
if [ $? -eq 2 ]; then
  echo "ok   - test-scan without --arch is a usage error"
else
  echo "FAIL - test-scan without --arch is a usage error"
  FAILED=$((FAILED + 1))
fi

# --- mirror-report.sh: a PR run where everything passes ---
D="$WORK/pass"
entry "$D" go 1.27
entry "$D" go 1.27-builder
PLAN='[{"name":"go","tag":"1.27","promote":false},{"name":"go","tag":"1.27-builder","promote":false}]'
"$MIRROR_REPORT" --reports "$D" --plan "$PLAN" --event pull_request --sha 0123456789abcdef \
  --run-url https://github.com/o/r/actions/runs/1 > "$WORK/pass.md"
check "summary says that every entry passed" has "$WORK/pass.md" "All 2 checked entries passed."
check "summary has one row per entry" has "$WORK/pass.md" '| `go:1.27-builder` | audit | pass | pass: 3 fixable HIGH/CRITICAL | pass: 3 fixable HIGH/CRITICAL |'
check "summary names the event, commit and run" has "$WORK/pass.md" 'Event: `pull_request`. Commit: `0123456`. [Run](https://github.com/o/r/actions/runs/1)'
check "summary of a PR run has no promote column" lacks "$WORK/pass.md" "Promote"
check "summary without failures has no failures section" lacks "$WORK/pass.md" "Failures"
"$MIRROR_REPORT" --reports "$D" --plan "$PLAN" --format failures > "$WORK/pass-failures.md"
check "failures format is empty when everything passed" test ! -s "$WORK/pass-failures.md"

# --- mirror-report.sh: a run on main with failures ---
D="$WORK/fail"
SRC="registry.example/hi"
# go:1.27 fails the gate on arm64
report "$D" --job verify --name go --source "$SRC/go:1.27@$DIGEST" --status success --steps "$OK_STEPS" --mode refresh
report "$D" --job test-scan --arch amd64 --name go --source "$SRC/go:1.27@$DIGEST" --status success \
  --steps "$OK_STEPS" --gate "$WORK/audit.json"
report "$D" --job test-scan --arch arm64 --name go --source "$SRC/go:1.27@$DIGEST" --status failure \
  --steps '{"vulnerability-gate":{"outcome":"failure"}}' --gate "$WORK/regression.json"
# python:3.14 fails its signature check, so nothing else runs
report "$D" --job verify --name python --source "$SRC/python:3.14@$DIGEST" --status failure \
  --steps '{"parse":{"outcome":"success"},"upstream-signature":{"outcome":"failure"}}' --mode refresh
# nginx:1.30 passes and is promoted
entry "$D" nginx 1.30
report "$D" --job promote --name nginx --source "$SRC/nginx:1.30@$DIGEST" --status success \
  --steps "$OK_STEPS" --tags "1.30 1.30.1" --approved false
# php:8.5 passes, but its promotion fails
entry "$D" php 8.5
report "$D" --job promote --name php --source "$SRC/php:8.5@$DIGEST" --status failure \
  --steps '{"copy-image":{"outcome":"success"},"verification-summary":{"outcome":"failure"}}'
# rust:1.99 passes and was approved before
entry "$D" rust 1.99
report "$D" --job promote --name rust --source "$SRC/rust:1.99@$DIGEST" --status success \
  --steps "$OK_STEPS" --tags "1.99" --approved true
# etcd:3.7 is planned for promotion, but its promote job left no report;
# static:latest is planned, but left no report at all
entry "$D" etcd 3.7
# core-runtime:latest passes and is not due for promotion
entry "$D" core-runtime latest
echo 'not json' > "$D/report-broken--1--verify.json"
PLAN='[
  {"name":"go","tag":"1.27","promote":true},
  {"name":"python","tag":"3.14","promote":true},
  {"name":"nginx","tag":"1.30","promote":true},
  {"name":"php","tag":"8.5","promote":true},
  {"name":"rust","tag":"1.99","promote":true},
  {"name":"etcd","tag":"3.7","promote":true},
  {"name":"static","tag":"latest","promote":true},
  {"name":"core-runtime","tag":"latest","promote":false}
]'
"$MIRROR_REPORT" --reports "$D" --plan "$PLAN" --promotes true --event push > "$WORK/fail.md" 2> "$WORK/fail.err"
M="$WORK/fail.md"
check "summary counts the failed entries" has "$M" "**5 of 8 checked entries failed.**"
check "an unreadable report is skipped with a note" has "$WORK/fail.err" "report-broken--1--verify.json"
check "gate failure names the job, the step and the regression" has "$M" '- `go:1.27` Test & Scan (arm64): failed at `vulnerability-gate`'
check "gate failure lists the regression" has "$M" '  - Critical `CVE-2026-1003` in `zlib` 1.3.2-1 (rpm)'
check "gate failure row shows the regression count" has "$M" '**FAILED** at `vulnerability-gate`: 1 new, '
check "signature failure is listed" has "$M" '- `python:3.14` Verify Upstream: failed at `upstream-signature`'
check "jobs after a failed verify show as not run" has "$M" '| `python:3.14` | refresh | **FAILED** at `upstream-signature` | – | – | – |'
check "promotion failure is listed" has "$M" '- `php:8.5` Promote to Mirror: failed at `verification-summary`'
check "a promotion is shown" has "$M" '| `nginx:1.30` | audit | pass | pass: 3 fixable HIGH/CRITICAL | pass: 3 fixable HIGH/CRITICAL | promoted |'
check "an earlier approval shows as refreshed tags" has "$M" 'HIGH/CRITICAL | tags refreshed |'
check "a missing promote report is a failure" has "$M" '- `etcd:3.7` Promote to Mirror: no report'
check "a planned entry without any report is a failure" has "$M" '| `static:latest` | ? | **no report** | – | – | – |'
check "an entry not due for promotion has no promote result" has "$M" '| `core-runtime:latest` | audit | pass | pass: 3 fixable HIGH/CRITICAL | pass: 3 fixable HIGH/CRITICAL | – |'
check "failures come before the table" test "$(grep -n 'Failures' "$M" | cut -d: -f1)" -lt "$(grep -n '^| Image' "$M" | cut -d: -f1)"

"$MIRROR_REPORT" --reports "$D" --plan "$PLAN" --promotes true --format failures > "$WORK/fail-failures.md" 2> /dev/null
check "failures format lists only the failures" test "$(grep -c '^- ' "$WORK/fail-failures.md")" -eq 5
check "failures format has no table" lacks "$WORK/fail-failures.md" "| Image"

# --- mirror-report.sh: inputs ---
"$MIRROR_REPORT" --reports "$D" --promotes true > "$WORK/noplan.md" 2> /dev/null
check "without a plan the entries come from the reports" has "$WORK/noplan.md" "**3 of 7 checked entries failed.**"

"$MIRROR_REPORT" --reports "$WORK/does-not-exist" --plan "" > "$WORK/none.md"
check "no reports and no plan give an empty report" has "$WORK/none.md" "No entry was checked."

E="$WORK/evil"
report "$E" --job verify --name 'x`|<b>' --source "$SRC/x:1@$DIGEST" --status failure \
  --steps '{"a|b`@team\n":{"outcome":"failure"}}'
"$MIRROR_REPORT" --reports "$E" > "$WORK/evil.md"
check "values are reduced to safe characters" has "$WORK/evil.md" '| `x???b?:1` | ? | **FAILED** at `a?b?@team?` |'

CASES=$((CASES + 1))
"$MIRROR_REPORT" --reports "$D" --plan '{"not":"an array"}' > /dev/null 2>&1
if [ $? -eq 2 ]; then
  echo "ok   - a plan that is not an array is an input error"
else
  echo "FAIL - a plan that is not an array is an input error"
  FAILED=$((FAILED + 1))
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED check(s) failed in $CASES cases"
  exit 1
fi
echo "All $CASES cases passed"
