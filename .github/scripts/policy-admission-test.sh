#!/usr/bin/env bash
# Checks the Kyverno policy against a running cluster (kubectl's current
# context) with server-side dry runs, so no pod is started:
#   - a mirrored image is admitted, by tag and by digest
#   - an image under the same path without signature and VSA is rejected
#   - an image outside the mirror is not affected by the policy
set -uo pipefail

POLICY="${POLICY:-verify-hummingbird-mirror}"
ADMIT_IMAGE="${ADMIT_IMAGE:-ghcr.io/curantes/hummingbird-mirror/core-runtime:latest}"
CONTROL_IMAGE="${CONTROL_IMAGE:-registry.k8s.io/pause:3.10}"

REPO="${ADMIT_IMAGE%:*}"
DIGEST="$(docker buildx imagetools inspect "$ADMIT_IMAGE" --format '{{json .Manifest}}' | jq -r '.digest')"
if [[ ! "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "Cannot resolve the digest of $ADMIT_IMAGE"
  exit 1
fi
# The cosign signature artifact of the mirrored image: it exists under the
# mirror path but is not an approved image, so it has no signature or VSA
# of its own.
REJECT_IMAGE="${REJECT_IMAGE:-$REPO:sha256-${DIGEST#sha256:}.sig}"
if ! docker buildx imagetools inspect "$REJECT_IMAGE" > /dev/null 2>&1; then
  echo "The image for the rejection test does not exist: $REJECT_IMAGE"
  exit 1
fi

FAILED=0
N=0
dry_run() { # dry_run <image>; output in $OUT
  N=$((N + 1))
  OUT="$(kubectl run "policy-test-$N" --image="$1" --restart=Never --dry-run=server -o name 2>&1)"
}

expect_admitted() { # expect_admitted <description> <image>
  # The first verification fetches signatures and the Sigstore trust root
  # and can exceed the webhook timeout, so retry.
  for attempt in 1 2 3; do
    if dry_run "$2"; then
      echo "ok   - $1: admitted $2"
      return 0
    fi
    echo "       attempt $attempt: $OUT"
    sleep 10
  done
  echo "FAIL - $1: $2 was rejected"
  FAILED=$((FAILED + 1))
}

expect_rejected() { # expect_rejected <description> <image>
  if dry_run "$2"; then
    echo "FAIL - $1: $2 was admitted"
    FAILED=$((FAILED + 1))
  elif grep -qF "$POLICY" <<< "$OUT"; then
    echo "ok   - $1: $POLICY rejected $2"
  else
    echo "FAIL - $1: $2 was rejected, but not by $POLICY:"
    echo "       $OUT"
    FAILED=$((FAILED + 1))
  fi
}

expect_admitted "mirrored image by tag" "$ADMIT_IMAGE"
expect_admitted "mirrored image by digest" "$REPO@$DIGEST"
expect_rejected "image under the mirror path without signature and VSA" "$REJECT_IMAGE"
expect_admitted "image outside the mirror (policy does not apply)" "$CONTROL_IMAGE"

if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED admission check(s) failed"
  exit 1
fi
echo "All admission checks passed"
