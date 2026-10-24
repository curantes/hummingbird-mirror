#!/usr/bin/env bash
# Sanity tests for the distroless static image.
# Usage: test.sh <image-ref> [tag]   (set CONTAINER_ENGINE=podman to run locally)
set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref> [tag]}"
ENGINE="${CONTAINER_ENGINE:-docker}"
WORKDIR="$(mktemp -d)"

echo "Testing non-root execution context (65532)..."
USER_CONF="$("$ENGINE" inspect --format='{{.Config.User}}' "$IMAGE")"
if [ "$USER_CONF" != "65532" ]; then
  echo "Unexpected User configuration: $USER_CONF (expected 65532)"
  exit 1
fi

# Pass a dummy command (true) so create succeeds on a distroless/commandless image
CID="$("$ENGINE" create "$IMAGE" true)"
trap '"$ENGINE" rm "$CID" >/dev/null; rm -rf "$WORKDIR"' EXIT

echo "Testing CA trust store presence..."
"$ENGINE" cp "$CID:/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem" "$WORKDIR/tls-ca-bundle.pem"
test -s "$WORKDIR/tls-ca-bundle.pem" || {
  echo "CA bundle not found or empty"
  exit 1
}

echo "Testing timezone data presence (UTC)..."
"$ENGINE" cp "$CID:/usr/share/zoneinfo/UTC" "$WORKDIR/UTC"
test -s "$WORKDIR/UTC" || {
  echo "UTC timezone file not found or empty"
  exit 1
}

echo "Verifying absence of shell binaries (/bin/sh and /bin/bash)..."
for shell in /bin/sh /bin/bash; do
  if "$ENGINE" cp "$CID:$shell" "$WORKDIR/shell" 2>/dev/null; then
    echo "Security check failed: $shell exists in distroless static image"
    exit 1
  fi
done

echo "Verifying absence of the C library (/lib64/libc.so.6)..."
if "$ENGINE" cp "$CID:/lib64/libc.so.6" "$WORKDIR/libc" 2>/dev/null; then
  echo "Security check failed: libc.so.6 exists in static image"
  exit 1
fi

echo "All static sanity tests passed successfully."
