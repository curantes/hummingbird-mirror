#!/usr/bin/env bash
# Sanity tests for the Node.js images (default and builder variants).
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

echo "Testing non-root user (65532)..."
USER_CONF="$("$ENGINE" inspect --format='{{.Config.User}}' "$IMAGE")"
if [ "$USER_CONF" != "65532" ]; then
  echo "Unexpected User configuration: $USER_CONF (expected 65532)"
  exit 1
fi

echo "Testing Node.js version (v$STREAM.x)..."
OUT="$(run node --version)"
if [[ "$OUT" != "v$STREAM."* ]]; then
  echo "Unexpected version: $OUT (expected v$STREAM.x)"
  exit 1
fi

echo "Testing system CA trust store..."
OUT="$(run node -e 'console.log(require("tls").getCACertificates("system").length)')"
if [ "$OUT" -eq 0 ]; then
  echo "System CA trust store is empty or unreadable"
  exit 1
fi

cat > "$WORKDIR/hello.js" <<'EOF'
const crypto = require("node:crypto");
const zlib = require("node:zlib");

crypto.createHash("sha256").update(zlib.gzipSync("x")).digest("hex");
console.log("Hello World");
EOF
chmod -R a+rX "$WORKDIR"

# The image's docker-entrypoint.sh prefixes `node` for script arguments.
echo "Testing script via the entrypoint..."
OUT="$(run /src/hello.js)"
[ "$OUT" = "Hello World" ] || { echo "Unexpected output: $OUT"; exit 1; }

echo "Testing npm (offline)..."
run sh -c 'cd /tmp && npm init -y > /dev/null && npm pack --dry-run > /dev/null'

echo "Testing package manager presence for variant '${VARIANT:-default}'..."
if run sh -c 'command -v dnf' > /dev/null; then HAS_DNF=yes; else HAS_DNF=no; fi
case "$VARIANT" in
  -builder) [ "$HAS_DNF" = yes ] || { echo "builder variant must ship dnf"; exit 1; } ;;
  *)        [ "$HAS_DNF" = no ]  || { echo "default variant must not ship dnf"; exit 1; } ;;
esac

echo "All nodejs sanity tests passed successfully."
