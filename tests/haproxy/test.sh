#!/usr/bin/env bash
# Sanity tests for the HAProxy images (default and builder variants).
# Usage: test.sh <image-ref> <tag>   (set CONTAINER_ENGINE=podman to run locally)
set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref> <tag>}"
TAG="${2:?usage: $0 <image-ref> <tag>}"
ENGINE="${CONTAINER_ENGINE:-docker}"
STREAM="${TAG%%-*}"
VARIANT="${TAG#"$STREAM"}"
WORKDIR="$(mktemp -d)"
CONTAINER=""
cleanup() {
  [ -z "$CONTAINER" ] || "$ENGINE" rm -f "$CONTAINER" > /dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# The image ships no configuration; its default command reads one from
# /usr/local/etc/haproxy/haproxy.cfg, which users mount.
CFG=/usr/local/etc/haproxy/haproxy.cfg
run() { "$ENGINE" run --rm -v "$WORKDIR/haproxy.cfg:$CFG:ro,z" "$IMAGE" "$@"; }
fails() { ! "$ENGINE" run --rm --entrypoint "$1" "$IMAGE" "${@:2}" > /dev/null 2>&1; }

# A frontend on 8080 that proxies to a second, local frontend answering
# directly, so the request passes through a real backend.
cat > "$WORKDIR/haproxy.cfg" <<'EOF'
global
    log stderr format raw local0

defaults
    mode http
    log global
    timeout connect 5s
    timeout client 30s
    timeout server 30s

frontend public
    bind :8080
    default_backend app

backend app
    server local 127.0.0.1:8081

frontend local
    bind 127.0.0.1:8081
    http-request return status 200 content-type text/plain string "Hello World"
EOF
chmod -R a+rX "$WORKDIR"

echo "Testing non-root user (haproxy)..."
USER_CONF="$("$ENGINE" inspect --format='{{.Config.User}}' "$IMAGE")"
if [ "$USER_CONF" != "haproxy" ]; then
  echo "Unexpected User configuration: $USER_CONF (expected haproxy)"
  exit 1
fi

echo "Testing HAProxy version ($STREAM.x)..."
OUT="$(run -v | sed -n 1p)"
if [[ "$OUT" != "HAProxy version $STREAM."* ]]; then
  echo "Unexpected version: $OUT (expected $STREAM.x)"
  exit 1
fi

echo "Testing configuration check..."
run -c -f "$CFG" > /dev/null 2>&1 || { echo "haproxy -c failed"; exit 1; }

echo "Testing proxied request through the default entrypoint..."
CONTAINER="$("$ENGINE" run -d -p 127.0.0.1::8080 -v "$WORKDIR/haproxy.cfg:$CFG:ro,z" "$IMAGE")"
PORT="$("$ENGINE" port "$CONTAINER" 8080/tcp | sed -n 1p)"
PORT="${PORT##*:}"
OUT=""
for _ in $(seq 1 20); do
  OUT="$(curl -fsS "http://127.0.0.1:$PORT/" 2> /dev/null)" && break
  sleep 0.5
done
if [ "$OUT" != "Hello World" ]; then
  echo "Unexpected response: ${OUT:-none}"
  "$ENGINE" logs "$CONTAINER"
  exit 1
fi

echo "Testing shell and package manager for variant '${VARIANT:-default}'..."
case "$VARIANT" in
  -builder)
    fails sh -c 'command -v dnf' && { echo "builder variant must ship sh and dnf"; exit 1; }
    ;;
  *)
    fails /bin/sh -c true || { echo "Security check failed: default variant ships /bin/sh"; exit 1; }
    fails dnf --version || { echo "default variant must not ship dnf"; exit 1; }
    ;;
esac

echo "All haproxy sanity tests passed successfully."
