#!/usr/bin/env bash
# Verifies the upstream signature or SBOM attestation of an image against
# the upstream keys. Every policy/keys/*.pub is tried and one that verifies
# is enough, so a new key can be added before upstream starts signing with
# it and the old one removed afterwards.
#
# Upstream signs with long-lived keys and does not upload to the public
# Rekor log, hence --insecure-ignore-tlog (as documented upstream).
#
# Exit codes: 0 verified, 1 no key verifies, 2 usage error or no keys.
set -euo pipefail

usage() {
  echo "Usage: verify-upstream.sh <signature|sbom> <image reference> [keys directory]" >&2
  exit 2
}

[ $# -ge 2 ] && [ $# -le 3 ] || usage
WHAT="$1"
REF="$2"
KEYS_DIR="${3:-policy/keys}"

case "$WHAT" in
  signature) CMD=(cosign verify) ;;
  sbom) CMD=(cosign verify-attestation --type spdx) ;;
  *) usage ;;
esac

shopt -s nullglob
KEYS=("$KEYS_DIR"/*.pub)
if [ ${#KEYS[@]} -eq 0 ]; then
  echo "No upstream keys (*.pub) in $KEYS_DIR" >&2
  exit 2
fi

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
for key in "${KEYS[@]}"; do
  if "${CMD[@]}" --key "$key" --insecure-ignore-tlog "$REF" > /dev/null 2>> "$LOG"; then
    echo "Upstream $WHAT of $REF verifies with $key"
    exit 0
  fi
  echo "--- not verified with $key" >> "$LOG"
done

echo "Upstream $WHAT of $REF verifies with none of: ${KEYS[*]}" >&2
cat "$LOG" >&2
exit 1
