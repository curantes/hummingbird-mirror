#!/usr/bin/env bash
# Checks that the public keys embedded in the Kyverno policy are exactly the
# keys in policy/keys/*.pub, which the pipeline verifies upstream images
# with. A key that is only in one place would make the cluster and the
# pipeline trust different signers.
set -euo pipefail

POLICY="${1:-policy/verify-hummingbird-mirror.yaml}"
KEYS_DIR="${2:-policy/keys}"

# Prints one line per PEM block: the SHA-256 of its base64 body.
fingerprints() {
  awk '
    /-----BEGIN PUBLIC KEY-----/ { inside = 1; body = ""; next }
    /-----END PUBLIC KEY-----/ { if (inside) print body; inside = 0; next }
    inside { gsub(/[[:space:]]/, ""); body = body $0 }
  ' "$@" | while read -r body; do
    printf '%s' "$body" | sha256sum | cut -d' ' -f1
  done
}

shopt -s nullglob
KEY_FILES=("$KEYS_DIR"/*.pub)
if [ ${#KEY_FILES[@]} -eq 0 ]; then
  echo "No keys (*.pub) in $KEYS_DIR"
  exit 1
fi

FAILED=0
declare -A IN_FILES=()
for file in "${KEY_FILES[@]}"; do
  mapfile -t prints < <(fingerprints "$file")
  if [ ${#prints[@]} -ne 1 ]; then
    echo "FAIL: $file must contain exactly one public key (found ${#prints[@]})"
    FAILED=1
    continue
  fi
  IN_FILES["${prints[0]}"]="$file"
done

declare -A IN_POLICY=()
while read -r print; do
  IN_POLICY["$print"]=1
done < <(fingerprints "$POLICY")
if [ ${#IN_POLICY[@]} -eq 0 ]; then
  echo "FAIL: no public key found in $POLICY"
  FAILED=1
fi

for print in "${!IN_FILES[@]}"; do
  if [ -z "${IN_POLICY[$print]:-}" ]; then
    echo "FAIL: ${IN_FILES[$print]} is not embedded in $POLICY"
    FAILED=1
  else
    echo "ok: ${IN_FILES[$print]} is embedded in $POLICY"
  fi
done
for print in "${!IN_POLICY[@]}"; do
  if [ -z "${IN_FILES[$print]:-}" ]; then
    echo "FAIL: $POLICY embeds a key (sha256 of body: $print) that is not in $KEYS_DIR"
    FAILED=1
  fi
done

exit "$FAILED"
