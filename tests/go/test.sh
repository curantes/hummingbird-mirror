#!/usr/bin/env bash
# Sanity tests for the Go toolchain images.
# Usage: test.sh <image-ref> <tag>   (set CONTAINER_ENGINE=podman to run locally)
set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref> <tag>}"
TAG="${2:?usage: $0 <image-ref> <tag>}"
ENGINE="${CONTAINER_ENGINE:-docker}"
STREAM="${TAG%%-*}"
VARIANT="${TAG#"$STREAM"}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

run() { "$ENGINE" run --rm -v "$WORKDIR:/src:ro,z" "$IMAGE" "$@"; }

echo "Testing Go version (go$STREAM.x)..."
OUT="$(run go version)"
if [[ "$OUT" != "go version go$STREAM."* ]]; then
  echo "Unexpected version: $OUT (expected go$STREAM.x)"
  exit 1
fi

cat > "$WORKDIR/hello.go" <<'EOF'
package main

import "fmt"

func main() { fmt.Println("Hello World") }
EOF
chmod -R a+rX "$WORKDIR"

echo "Testing static build (CGO_ENABLED=0)..."
OUT="$(run sh -c 'cd /tmp && CGO_ENABLED=0 go build -o hello /src/hello.go && ./hello')"
if [ "$OUT" != "Hello World" ]; then
  echo "Unexpected output: $OUT"
  exit 1
fi

echo "Testing cgo build (CGO_ENABLED=1)..."
OUT="$(run sh -c 'cd /tmp && CGO_ENABLED=1 go build -o hello /src/hello.go && ./hello')"
if [ "$OUT" != "Hello World" ]; then
  echo "Unexpected output: $OUT"
  exit 1
fi

echo "Testing package manager presence for variant '${VARIANT:-default}'..."
if run sh -c 'command -v dnf' > /dev/null; then HAS_DNF=yes; else HAS_DNF=no; fi
case "$VARIANT" in
  -builder) [ "$HAS_DNF" = yes ] || { echo "builder variant must ship dnf"; exit 1; } ;;
  *)        [ "$HAS_DNF" = no ]  || { echo "default variant must not ship dnf"; exit 1; } ;;
esac

echo "All go sanity tests passed successfully."
