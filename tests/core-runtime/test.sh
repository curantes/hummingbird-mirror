#!/usr/bin/env bash
# Sanity tests for the core-runtime image.
# Usage: test.sh <image-ref> [tag]   (set CONTAINER_ENGINE=podman to run locally)
set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref> [tag]}"
ENGINE="${CONTAINER_ENGINE:-docker}"

run() { "$ENGINE" run --rm "$IMAGE" "$@"; }

# Upstream runs as UID 65532 with GID 0 (OpenShift arbitrary-UID convention);
# the root group grants no root privileges.
echo "Testing non-root user (UID 65532)..."
USER_ID="$(run id -u)"
if [ "$USER_ID" != "65532" ]; then
  echo "Unexpected UID: $USER_ID (expected 65532)"
  exit 1
fi

echo "Testing shell execution..."
# shellcheck disable=SC2116 # echo runs inside the container
OUT="$(run echo hello)"
if [ "$OUT" != "hello" ]; then
  echo "Unexpected output: $OUT (expected 'hello')"
  exit 1
fi

echo "Testing dynamic linking (libc.so)..."
run ldconfig -p | grep 'libc.so' > /dev/null || {
  echo "libc.so not found in ldconfig cache"
  exit 1
}

echo "Testing locale C.UTF-8..."
run locale | grep 'C.UTF-8' > /dev/null || {
  echo "Locale C.UTF-8 not configured"
  exit 1
}

echo "All core-runtime sanity tests passed successfully."
