#!/usr/bin/env bash
# Sanity tests for the nginx images (default and builder variants).
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

run() { "$ENGINE" run --rm "$IMAGE" "$@"; }
fails() { ! "$ENGINE" run --rm --entrypoint "$1" "$IMAGE" "${@:2}" > /dev/null 2>&1; }

# Replaces the running container with one started with extra run arguments.
start() {
  [ -z "$CONTAINER" ] || "$ENGINE" rm -f "$CONTAINER" > /dev/null
  CONTAINER="$("$ENGINE" run -d -p 127.0.0.1::8080 "$@" "$IMAGE")"
  PORT="$("$ENGINE" port "$CONTAINER" 8080/tcp | sed -n 1p)"
  PORT="${PORT##*:}"
}

# Waits for HTTP on the published port and prints the body for path $1.
fetch() {
  for _ in $(seq 1 20); do
    curl -fsS "http://127.0.0.1:$PORT$1" 2> /dev/null && return 0
    sleep 0.5
  done
  echo "nginx did not answer on port 8080" >&2
  "$ENGINE" logs "$CONTAINER" >&2
  return 1
}

echo "Testing non-root user (65532)..."
USER_CONF="$("$ENGINE" inspect --format='{{.Config.User}}' "$IMAGE")"
if [ "$USER_CONF" != "65532" ]; then
  echo "Unexpected User configuration: $USER_CONF (expected 65532)"
  exit 1
fi

echo "Testing nginx version ($STREAM.x)..."
OUT="$(run -v 2>&1)"
if [[ "$OUT" != "nginx version: nginx/$STREAM."* ]]; then
  echo "Unexpected version: $OUT (expected nginx/$STREAM.x)"
  exit 1
fi

echo "Testing default configuration..."
run -t > /dev/null 2>&1 || { echo "nginx -t failed"; exit 1; }

echo "Testing default page on port 8080..."
start
OUT="$(fetch /)"
[[ "$OUT" == *"<html"* ]] || { echo "Unexpected default page: $OUT"; exit 1; }

echo "Testing a mounted server configuration..."
cat > "$WORKDIR/default.conf" <<'EOF'
server {
    listen 8080;
    location = /hello {
        default_type text/plain;
        return 200 "Hello World\n";
    }
}
EOF
chmod -R a+rX "$WORKDIR"
start -v "$WORKDIR/default.conf:/etc/nginx/conf.d/default.conf:ro,z"
OUT="$(fetch /hello)"
[ "$OUT" = "Hello World" ] || { echo "Unexpected response: $OUT"; exit 1; }

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

echo "All nginx sanity tests passed successfully."
