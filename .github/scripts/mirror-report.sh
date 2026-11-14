#!/usr/bin/env bash
# Turns the job reports of one run (see job-report.sh) into Markdown.
#
# Formats:
#   summary   a heading, the failures and one table row per entry; used for
#             the run summary and the PR comment
#   failures  only the list of failing jobs, empty when there is none; used
#             for the alert issue
#
# With --plan, the entries the run planned are known, so a job that left no
# report (runner lost, report step failed) shows as "no report" instead of
# being left out. Without it, the entries come from the reports alone.
#
# Values from the reports end up in a PR comment and an issue, so every one
# is reduced to a safe character set, and names go into code spans, where
# "@scope/package" does not mention anyone.
#
# Exit codes: 0 written (also when jobs failed), 2 usage or input error.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: mirror-report.sh --reports <directory> [--format <summary|failures>]
                        [--plan <json>] [--promotes <true|false>]
                        [--event <name>] [--run-url <url>] [--sha <commit>]

  --reports   directory with report-*.json files (may be missing or empty)
  --plan      the plan job's matrix as JSON
  --promotes  whether this run promotes (a run on main that is not a PR)
EOF
  exit 2
}

REPORTS_DIR="" FORMAT="summary" PLAN="[]" PROMOTES="false" EVENT="" RUN_URL="" SHA=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --reports) REPORTS_DIR="$2" ;;
    --format) FORMAT="$2" ;;
    --plan) PLAN="$2" ;;
    --promotes) PROMOTES="$2" ;;
    --event) EVENT="$2" ;;
    --run-url) RUN_URL="$2" ;;
    --sha) SHA="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$REPORTS_DIR" ] || usage
case "$FORMAT" in summary | failures) ;; *) usage ;; esac
# A skipped plan job leaves the matrix empty.
[ -n "$PLAN" ] || PLAN="[]"
if ! jq -e 'type == "array"' <<< "$PLAN" > /dev/null 2>&1; then
  echo "--plan must be a JSON array" >&2
  exit 2
fi

# One unreadable report must not hide the others.
REPORTS="$(
  if [ -d "$REPORTS_DIR" ]; then
    find "$REPORTS_DIR" -type f -name 'report-*.json' | sort | while read -r file; do
      jq -c 'select(type == "object" and (.image | type) == "string" and (.tag | type) == "string")' "$file" 2> /dev/null \
        || echo "Skipping unreadable report $file" >&2
    done
  fi | jq -sc .
)"

jq -rn --argjson reports "$REPORTS" --argjson plan "$PLAN" --arg format "$FORMAT" \
  --arg promotes "$PROMOTES" --arg event "$EVENT" --arg run "$RUN_URL" --arg sha "$SHA" '
  def safe: tostring | gsub("[^A-Za-z0-9 ._:/+~,()=-]"; "?");
  def code: "`" + (tostring | gsub("[^A-Za-z0-9 ._:/+~,()=@-]"; "?")) + "`";

  # state of one job: pass, failed, cancelled, missing (expected, but no
  # report) or none (did not run)
  def state($report; $expected):
    if $report == null then {state: (if $expected then "missing" else "none" end)}
    elif $report.status == "success" then {state: "pass"}
    elif $report.status == "cancelled" then {state: "cancelled"}
    else {state: "failed", step: $report.failedStep} end;
  def bad: .state | IN("failed", "cancelled", "missing");

  def findings($report):
    if $report == null or $report.counts == null then ""
    elif $report.mode == "refresh" then
      "\($report.counts.regressions | safe) new, \($report.counts.fixed | safe) fixed, \($report.counts.remaining | safe) remaining"
    else "\($report.counts.findings | safe) fixable HIGH/CRITICAL" end;

  def cell($extra):
    (if .state == "pass" then "pass"
     elif .state == "failed" then "**FAILED**" + (if .step then " at " + (.step | code) else "" end)
     elif .state == "cancelled" then "cancelled"
     elif .state == "missing" then "**no report**"
     else "–" end)
    + (if $extra != "" and (.state | IN("pass", "failed")) then ": " + $extra else "" end);

  def failure($title):
    if .state == "failed" then
      "\($title): failed" + (if .step then " at " + (.step | code) else "" end)
    elif .state == "cancelled" then "\($title): cancelled"
    else "\($title): no report, the job did not finish or could not write one" end;

  ($reports | map(. + {key: (.image + ":" + .tag)})) as $all
  | ($plan | map({key: (.name + ":" + .tag), promote: (.promote == true)})) as $planned
  | ([$planned[].key, $all[].key] | reduce .[] as $k ([]; if index($k) then . else . + [$k] end)) as $keys
  | [ $keys[] as $k
      | ($all | map(select(.key == $k))) as $mine
      | ($mine | map(select(.job == "verify")) | first) as $verify
      | ($mine | map(select(.job == "test-scan" and .architecture == "amd64")) | first) as $amd64
      | ($mine | map(select(.job == "test-scan" and .architecture == "arm64")) | first) as $arm64
      | ($mine | map(select(.job == "promote")) | first) as $promote
      | ($planned | map(select(.key == $k)) | first) as $entry
      | state($verify; true) as $v
      | state($amd64; $v.state == "pass") as $a
      | state($arm64; $v.state == "pass") as $b
      | state($promote; $promotes == "true" and ($entry.promote // false)
          and $v.state == "pass" and $a.state == "pass" and $b.state == "pass") as $p
      | {
          key: $k,
          mode: ($verify.mode // $amd64.mode // $arm64.mode // "?"),
          verify: $v, amd64: $a, arm64: $b, promote: $p,
          amd64Report: $amd64, arm64Report: $arm64, promoteReport: $promote,
          failed: ([$v, $a, $b, $p] | any(bad))
        } ] as $entries

  | [ $entries[] | select(.failed) | . as $e
      | ( ($e.verify | select(bad) | {text: failure("Verify Upstream"), report: null}),
          ($e.amd64 | select(bad) | {text: failure("Test & Scan (amd64)"), report: $e.amd64Report}),
          ($e.arm64 | select(bad) | {text: failure("Test & Scan (arm64)"), report: $e.arm64Report}),
          ($e.promote | select(bad) | {text: failure("Promote to Mirror"), report: null}) )
      | "- \($e.key | code) \(.text)",
        ( .report | select(. != null) | (.blocking // [])[]
          | "  - \(.severity | safe) \(.id | code) in \(.package | code) \(.version | safe) (\(.type | safe))" ),
        ( .report | select(. != null and ((.blockingTotal // 0) > ((.blocking // []) | length)))
          | "  - and \((.blockingTotal - (.blocking | length)) | safe) more" )
    ] as $failures

  | if $format == "failures" then $failures[]
    else
      "### Mirror Report",
      "",
      ( ($entries | length) as $n | ($entries | map(select(.failed)) | length) as $f
        | (if $n == 0 then "No entry was checked."
           elif $f == 0 then "All \($n) checked entries passed."
           else "**\($f) of \($n) checked entries failed.**" end)
          + (if $event != "" then " Event: \($event | code)." else "" end)
          + (if $sha != "" then " Commit: \($sha[:7] | code)." else "" end)
          + (if $run != "" then " [Run](\($run | gsub("[^A-Za-z0-9._:/-]"; "")))" else "" end) ),
      ( if ($failures | length) > 0 then "", "#### Failures", "", $failures[] else empty end ),
      ( if ($entries | length) > 0 then
          "",
          "| Image | Mode | Verify | Test & Scan (amd64) | Test & Scan (arm64) |"
            + (if $promotes == "true" then " Promote |" else "" end),
          "|---|---|---|---|---|" + (if $promotes == "true" then "---|" else "" end),
          ( $entries[] | . as $e
            | "| \(.key | code) | \(.mode | safe) | \(.verify | cell("")) | "
              + "\(.amd64 | cell(findings($e.amd64Report))) | \(.arm64 | cell(findings($e.arm64Report))) |"
              + (if $promotes == "true" then
                   " " + ( .promote
                           | if .state == "pass" then
                               (if $e.promoteReport.alreadyApproved == true then "tags refreshed" else "promoted" end)
                             else cell("") end ) + " |"
                 else "" end) ),
          "",
          "Findings are fixable HIGH and CRITICAL vulnerabilities. In `refresh` mode they are compared with the digest the mirror serves; `audit` reports them without failing."
        else empty end )
    end'
