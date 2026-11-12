#!/usr/bin/env bash
# Vulnerability gate for the mirror pipeline.
#
# Reads Grype JSON reports and decides whether a digest may be promoted.
# A finding is a match with severity High or Critical whose fix state is
# "fixed", keyed by (vulnerability ID, package name, package type). The
# package version is not part of the key, so a version bump that still
# carries the same CVE is not a new finding.
#
# Modes:
#   new-stream  no baseline; fail on any finding
#   refresh     fail on findings that the baseline does not have
#   audit       report findings; never fail on them
#
# Exit codes: 0 pass, 1 gate failed, 2 usage or input error.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: vuln-gate.sh --mode <new-stream|refresh|audit> --new <grype.json>
                    [--baseline <grype.json>] [--result <file>]
                    [--summary <file>] [--label <text>]

  --baseline  Grype JSON of the baseline image (required for refresh)
  --result    write the gate result as JSON
  --summary   append a Markdown summary (e.g. $GITHUB_STEP_SUMMARY)
  --label     name shown in the summary (e.g. "go:1.27 (amd64)")
EOF
  exit 2
}

MODE="" NEW="" BASELINE="" RESULT="" SUMMARY="" LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode | --new | --baseline | --result | --summary | --label)
      [ $# -ge 2 ] || usage
      case "$1" in
        --mode) MODE="$2" ;;
        --new) NEW="$2" ;;
        --baseline) BASELINE="$2" ;;
        --result) RESULT="$2" ;;
        --summary) SUMMARY="$2" ;;
        --label) LABEL="$2" ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

case "$MODE" in
  new-stream | audit) ;;
  refresh)
    if [ -z "$BASELINE" ]; then
      echo "refresh mode needs --baseline" >&2
      exit 2
    fi
    ;;
  *) usage ;;
esac
[ -n "$NEW" ] || usage

# A report that is missing or isn't Grype JSON must never read as "clean".
findings() {
  local file="$1"
  if [ ! -s "$file" ]; then
    echo "Grype report '$file' is missing or empty" >&2
    return 2
  fi
  jq -e '
    if (type == "object" and (.matches | type) == "array") then . else
      error("not a Grype JSON report (no .matches array)")
    end
    | [ .matches[]
        | select((.vulnerability.severity // "" | ascii_downcase) | IN("high", "critical"))
        | select(.vulnerability.fix.state == "fixed")
        | {
            id: .vulnerability.id,
            package: .artifact.name,
            type: .artifact.type,
            severity: .vulnerability.severity,
            version: .artifact.version,
            fixedIn: ((.vulnerability.fix.versions // []) | join(", "))
          } ]
    | group_by([.id, .package, .type])
    | map(.[0] + { version: (map(.version) | unique | join(", ")) })
  ' "$file" || {
    echo "Could not read Grype report '$file'" >&2
    return 2
  }
}

NEW_SET="$(findings "$NEW")" || exit 2
if [ "$MODE" = "refresh" ]; then
  BASE_SET="$(findings "$BASELINE")" || exit 2
else
  BASE_SET="[]"
fi

OUT="$(jq -n --arg mode "$MODE" --argjson new "$NEW_SET" --argjson base "$BASE_SET" '
  def key: [.id, .package, .type];
  ($base | map(key)) as $bk
  | ($new | map(key)) as $nk
  | (if $mode == "refresh" then $new | map(select(key | IN($bk[]) | not)) else [] end) as $regressions
  | (if $mode == "refresh" then $base | map(select(key | IN($nk[]) | not)) else [] end) as $fixed
  | (if $mode == "refresh" then $new | map(select(key | IN($bk[]))) else [] end) as $remaining
  | {
      mode: $mode,
      pass: (if $mode == "audit" then true
             elif $mode == "refresh" then ($regressions | length) == 0
             else ($new | length) == 0 end),
      counts: {
        findings: ($new | length),
        critical: ($new | map(select(.severity | ascii_downcase == "critical")) | length),
        high: ($new | map(select(.severity | ascii_downcase == "high")) | length),
        baseline: ($base | length),
        regressions: ($regressions | length),
        fixed: ($fixed | length),
        remaining: ($remaining | length)
      },
      findings: $new,
      regressions: $regressions,
      fixed: $fixed,
      remaining: $remaining
    }')"

if [ -n "$RESULT" ]; then
  printf '%s\n' "$OUT" > "$RESULT"
fi

list() { # list <title> <jq path>
  local n
  n="$(jq "$2 | length" <<< "$OUT")"
  echo "$1: $n"
  jq -r "$2[] | \"  \(.severity)\t\(.id)\t\(.package) \(.version) (\(.type))\tfixed in: \(.fixedIn)\"" <<< "$OUT"
}

PASS="$(jq -r '.pass' <<< "$OUT")"
echo "Gate mode: $MODE"
case "$MODE" in
  refresh)
    list "Regressions (new fixable HIGH/CRITICAL findings)" .regressions
    list "Fixed by this refresh" .fixed
    list "Remaining from the baseline" .remaining
    if [ "$PASS" = "true" ]; then
      VERDICT="no vulnerability regression against the baseline"
    else
      VERDICT="the new digest adds fixable HIGH/CRITICAL findings that the baseline does not have"
    fi
    ;;
  new-stream)
    list "Fixable HIGH/CRITICAL findings" .findings
    if [ "$PASS" = "true" ]; then
      VERDICT="no fixable HIGH/CRITICAL findings"
    else
      VERDICT="a new stream must have no fixable HIGH/CRITICAL findings"
    fi
    ;;
  audit)
    list "Fixable HIGH/CRITICAL findings (reported, not gated)" .findings
    VERDICT="audit only; findings do not fail the run"
    ;;
esac

if [ "$PASS" = "true" ]; then STATUS="PASS"; else STATUS="FAIL"; fi
echo "$STATUS: $VERDICT"

if [ -n "$SUMMARY" ]; then
  {
    case "$MODE" in
      refresh)
        jq -r --arg l "${LABEL:-image}" --arg s "$STATUS" \
          '"**\($l)** `refresh` \($s): \(.counts.regressions) regressions, \(.counts.fixed) fixed, \(.counts.remaining) remaining"' <<< "$OUT"
        jq -r '.regressions[] | "- regression: \(.severity) `\(.id)` in `\(.package)` \(.version) (\(.type))"' <<< "$OUT"
        ;;
      *)
        jq -r --arg l "${LABEL:-image}" --arg s "$STATUS" --arg m "$MODE" \
          '"**\($l)** `\($m)` \($s): \(.counts.findings) fixable HIGH/CRITICAL (\(.counts.critical) critical, \(.counts.high) high)"' <<< "$OUT"
        ;;
    esac
    echo
  } >> "$SUMMARY"
fi

[ "$PASS" = "true" ] || exit 1
