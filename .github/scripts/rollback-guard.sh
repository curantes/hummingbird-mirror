#!/usr/bin/env bash
# Rollback guard for the mirror pipeline.
#
# A refresh must not replace the baseline, the digest the mirror serves, with
# an older build. Nothing else catches that: an older build has a valid
# signature, the right version stream and often no new findings, and
# Renovate proposes whatever the upstream tag points at.
#
# The build time is the label org.opencontainers.image.created, read from
# `docker image inspect` output. The same time passes. A time that can't be
# read fails, so it never reads as "not older".
#
# An intended rollback needs a line in the --allow file:
#   <baseline digest> <new digest>  # reason
# It allows that one step and nothing else.
#
# Exit codes: 0 pass, 1 rollback, 2 usage or input error.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: rollback-guard.sh --new <inspect.json> --new-digest <digest>
                         --baseline <inspect.json> --baseline-digest <digest>
                         [--allow <file>] [--summary <file>] [--label <text>]

  --allow    allowed rollbacks, one "<baseline digest> <new digest>" per line
  --summary  append a Markdown summary of a rollback (e.g. $GITHUB_STEP_SUMMARY)
  --label    name shown in the output (e.g. "go:1.27 (amd64)")
USAGE
  exit 2
}

NEW="" NEW_DIGEST="" BASELINE="" BASELINE_DIGEST="" ALLOW="" SUMMARY="" LABEL="image"
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --new) NEW="$2" ;;
    --new-digest) NEW_DIGEST="$2" ;;
    --baseline) BASELINE="$2" ;;
    --baseline-digest) BASELINE_DIGEST="$2" ;;
    --allow) ALLOW="$2" ;;
    --summary) SUMMARY="$2" ;;
    --label) LABEL="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$NEW" ] && [ -n "$BASELINE" ] || usage
for digest in "$NEW_DIGEST" "$BASELINE_DIGEST"; do
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
done

report() { # report <text>
  echo "$LABEL: $1"
  if [ -n "$SUMMARY" ]; then
    printf '**%s** rollback guard: %s\n\n' "$LABEL" "$1" >> "$SUMMARY"
  fi
}

# Checked first, so that it also covers a build without a readable time.
if [ -n "$ALLOW" ] && [ -f "$ALLOW" ] \
    && awk -v from="$BASELINE_DIGEST" -v to="$NEW_DIGEST" '
         $1 == from && $2 == to && ($3 == "" || $3 ~ /^#/) { found = 1 }
         END { exit !found }' "$ALLOW"; then
  report "ALLOWED by $ALLOW, $BASELINE_DIGEST to $NEW_DIGEST"
  exit 0
fi

created() { # created <inspect.json>
  jq -er '
    if type == "array" and length == 1 then .[0] else empty end
    | .Config.Labels["org.opencontainers.image.created"]
    | strings' "$1" 2> /dev/null
}
seconds() { # seconds <RFC 3339 time>
  # date alone would also accept "yesterday" or an empty string.
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] \
    && date -u -d "$1" +%s 2> /dev/null
}

if ! NEW_TIME="$(created "$NEW")" || ! NEW_SECONDS="$(seconds "$NEW_TIME")"; then
  echo "$LABEL: cannot read the build time of the new digest $NEW_DIGEST" >&2
  exit 2
fi
if ! BASELINE_TIME="$(created "$BASELINE")" || ! BASELINE_SECONDS="$(seconds "$BASELINE_TIME")"; then
  echo "$LABEL: cannot read the build time of the baseline $BASELINE_DIGEST" >&2
  exit 2
fi

if [ "$NEW_SECONDS" -lt "$BASELINE_SECONDS" ]; then
  report "FAIL, the new digest was built $NEW_TIME, before the mirrored one ($BASELINE_TIME)"
  echo "If the rollback is intended, add this line to ${ALLOW:-the allow file}:"
  echo "  $BASELINE_DIGEST $NEW_DIGEST  # <reason>"
  exit 1
fi
echo "$LABEL: PASS, built $NEW_TIME, not before the mirrored digest ($BASELINE_TIME)"
