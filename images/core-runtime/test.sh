#!/usr/bin/env bash
# Sanity tests for the core-runtime image.
# Usage: test.sh <image-ref>   (set CONTAINER_ENGINE=podman to run locally)
set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref>}"
ENGINE="${CONTAINER_ENGINE:-docker}"

run() { "$ENGINE" run --rm "$IMAGE" "$@"; }

echo "Testing non-root UID and GID (10001:10001)..."
USER_GID="$(run id -u):$(run id -g)"
if [ "$USER_GID" != "10001:10001" ]; then
  echo "Unexpected UID:GID: $USER_GID (expected 10001:10001)"
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
run ldconfig -p | grep -q 'libc.so' || {
  echo "libc.so not found in ldconfig cache"
  exit 1
}

echo "Testing locale C.UTF-8..."
run locale | grep -q 'C.UTF-8' || {
  echo "Locale C.UTF-8 not configured"
  exit 1
}

echo "All core-runtime sanity tests passed successfully."
