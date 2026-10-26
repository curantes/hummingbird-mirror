#!/usr/bin/env bash
# Sanity tests for the Python images (default and builder variants).
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
fails() { ! "$ENGINE" run --rm --entrypoint "$1" "$IMAGE" "${@:2}" > /dev/null 2>&1; }

echo "Testing non-root user (65532)..."
USER_CONF="$("$ENGINE" inspect --format='{{.Config.User}}' "$IMAGE")"
if [ "$USER_CONF" != "65532" ]; then
  echo "Unexpected User configuration: $USER_CONF (expected 65532)"
  exit 1
fi

echo "Testing Python version ($STREAM)..."
OUT="$(run python3 --version)"
if [[ "$OUT" != "Python $STREAM."* ]]; then
  echo "Unexpected version: $OUT (expected Python $STREAM.x)"
  exit 1
fi

# The default context loads CAs lazily from the OpenSSL directory, so count
# the trust store on disk instead of the loaded certificates.
echo "Testing CA trust store..."
OUT="$(run python3 -c '
import os, ssl
p = ssl.get_default_verify_paths()
n = 0
if os.path.isfile(p.openssl_cafile):
    n += open(p.openssl_cafile).read().count("BEGIN CERTIFICATE")
if os.path.isdir(p.openssl_capath):
    n += len(os.listdir(p.openssl_capath))
print(n)')"
if [ "$OUT" -eq 0 ]; then
  echo "OpenSSL trust store is empty or unreadable"
  exit 1
fi

cat > "$WORKDIR/hello.py" <<'EOF'
import bz2, ctypes, decimal, hashlib, lzma, sqlite3, ssl, uuid, zlib

print("Hello World")
EOF
chmod -R a+rX "$WORKDIR"

echo "Testing script with common stdlib modules..."
OUT="$(run python3 /src/hello.py)"
[ "$OUT" = "Hello World" ] || { echo "Unexpected output: $OUT"; exit 1; }

echo "Testing venv with pip (offline, via ensurepip)..."
run python3 -c '
import subprocess, venv
venv.create("/tmp/venv", with_pip=True)
subprocess.run(["/tmp/venv/bin/python", "-m", "pip", "--version"], check=True)' > /dev/null

echo "Testing shell and package manager for variant '${VARIANT:-default}'..."
case "$VARIANT" in
  -builder)
    run sh -c 'command -v dnf' > /dev/null || { echo "builder variant must ship sh and dnf"; exit 1; }
    ;;
  *)
    fails /bin/sh -c true || { echo "Security check failed: default variant ships /bin/sh"; exit 1; }
    fails dnf --version || { echo "default variant must not ship dnf"; exit 1; }
    ;;
esac

echo "All python sanity tests passed successfully."
