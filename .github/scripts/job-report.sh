#!/usr/bin/env bash
# Writes the result of one pipeline job as a small JSON report.
#
# Every verify, test-scan and promote job of verify-promote.yml runs this as
# its last step and uploads the file as an artifact. mirror-report.sh turns
# the reports of a run into the run summary, the PR comment and the alert
# issue. The reports are informational: the promotion reads the gate result,
# never these files.
#
# The failing step is the first step in the `steps` context whose outcome is
# "failure". Only steps with an `id` appear there, and the id is what the
# report shows.
#
# Prints the path of the report. With GITHUB_OUTPUT set, also writes the
# outputs `path` and `artifact` (the artifact name).
#
# Exit codes: 0 written, 2 usage error.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: job-report.sh --job <verify|test-scan|promote> --name <name>
                     --source <repo>:<tag>@<digest> --status <job status>
                     --out-dir <directory> [--steps <json>] [--arch <arch>]
                     [--mode <mode>] [--gate <gate-result.json>]
                     [--tags <text>] [--approved <true|false>]

  --status    job status: success, failure or cancelled
  --steps     the `steps` context as JSON (toJSON(steps))
  --arch      architecture of a test-scan job
  --mode      gate mode, if known
  --gate      result file of vuln-gate.sh, if the gate ran
  --tags      tags a promote job moved, separated by spaces
  --approved  whether the digest was already approved before a promote job
EOF
  exit 2
}

JOB="" NAME="" SOURCE="" STATUS="" OUT_DIR="" STEPS="" ARCH="" MODE="" GATE="" TAGS="" APPROVED=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --job) JOB="$2" ;;
    --name) NAME="$2" ;;
    --source) SOURCE="$2" ;;
    --status) STATUS="$2" ;;
    --out-dir) OUT_DIR="$2" ;;
    --steps) STEPS="$2" ;;
    --arch) ARCH="$2" ;;
    --mode) MODE="$2" ;;
    --gate) GATE="$2" ;;
    --tags) TAGS="$2" ;;
    --approved) APPROVED="$2" ;;
    *) usage ;;
  esac
  shift 2
done

case "$JOB" in
  verify | promote) SUFFIX="$JOB" ;;
  test-scan)
    [ -n "$ARCH" ] || usage
    SUFFIX="$ARCH"
    ;;
  *) usage ;;
esac
[ -n "$NAME" ] && [ -n "$SOURCE" ] && [ -n "$STATUS" ] && [ -n "$OUT_DIR" ] || usage

# A report must be written even when the job failed early, so unreadable
# inputs become "nothing known" instead of an error.
if ! jq -e 'type == "object"' <<< "$STEPS" > /dev/null 2>&1; then STEPS='{}'; fi
GATE_JSON='null'
if [ -n "$GATE" ] && [ -s "$GATE" ] && jq -e 'type == "object"' "$GATE" > /dev/null 2>&1; then
  GATE_JSON="$(jq -c . "$GATE")"
fi

# Same parsing as the plan job in mirror.yml, so the keys match.
TAG="$(jq -rn --arg s "$SOURCE" '$s | split("@")[0] | split(":") | last')"
# Artifact names must not contain " : < > | * ? \ / or line breaks.
safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
ARTIFACT="report-$(safe "$NAME")--$(safe "$TAG")--$SUFFIX"

mkdir -p "$OUT_DIR"
FILE="$OUT_DIR/$ARTIFACT.json"
jq -n --arg job "$JOB" --arg name "$NAME" --arg source "$SOURCE" --arg tag "$TAG" \
  --arg status "$STATUS" --arg arch "$ARCH" --arg mode "$MODE" --arg tags "$TAGS" \
  --arg approved "$APPROVED" --argjson steps "$STEPS" --argjson gate "$GATE_JSON" '
  # What stopped the gate: regressions on a refresh, every finding on a new stream.
  (if $gate == null or $gate.pass != false then []
   elif $gate.mode == "refresh" then $gate.regressions // []
   else $gate.findings // [] end) as $blocking
  | {
      image: $name,
      tag: $tag,
      digest: ($source | split("@") | if length > 1 then last else null end),
      job: $job,
      architecture: (if $arch == "" then null else $arch end),
      mode: ($gate.mode // (if $mode == "" then null else $mode end)),
      status: $status,
      failedStep: ([$steps | to_entries[] | select(.value.outcome == "failure") | .key] | first),
      counts: ($gate.counts // null),
      blocking: ($blocking[:20] | map({id, package, type, severity, version})),
      blockingTotal: ($blocking | length)
    }
    + (if $job == "promote" then {
        tags: ($tags | split(" ") | map(select(. != ""))),
        alreadyApproved: ($approved == "true")
      } else {} end)' > "$FILE"

echo "$FILE"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "path=$FILE"
    echo "artifact=$ARTIFACT"
  } >> "$GITHUB_OUTPUT"
fi
