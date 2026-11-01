#!/usr/bin/env bash
# Sanity tests for the etcd images (default and builder variants).
# Usage: test.sh <image-ref> <tag>   (set CONTAINER_ENGINE=podman to run locally)
set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref> <tag>}"
TAG="${2:?usage: $0 <image-ref> <tag>}"
ENGINE="${CONTAINER_ENGINE:-docker}"
STREAM="${TAG%%-*}"
VARIANT="${TAG#"$STREAM"}"
VOLUME="etcd-test-$$"
CONTAINER=""
cleanup() {
  [ -z "$CONTAINER" ] || "$ENGINE" rm -f "$CONTAINER" > /dev/null 2>&1 || true
  "$ENGINE" volume rm -f "$VOLUME" > /dev/null 2>&1 || true
}
trap cleanup EXIT

run() { "$ENGINE" run --rm "$IMAGE" "$@"; }
fails() { ! "$ENGINE" run --rm --entrypoint "$1" "$IMAGE" "${@:2}" > /dev/null 2>&1; }
ctl() { "$ENGINE" exec "$CONTAINER" etcdctl "$@"; }

# Replaces the running container with a single-member cluster on the data
# volume (default data dir under the /var/lib/etcd working directory),
# publishes the client port and waits until it reports healthy.
start() {
  [ -z "$CONTAINER" ] || "$ENGINE" rm -f "$CONTAINER" > /dev/null
  CONTAINER="$("$ENGINE" run -d -p 127.0.0.1::2379 -v "$VOLUME:/var/lib/etcd" "$IMAGE" \
    --listen-client-urls http://0.0.0.0:2379 \
    --advertise-client-urls http://127.0.0.1:2379)"
  PORT="$("$ENGINE" port "$CONTAINER" 2379/tcp | head -n 1)"
  PORT="${PORT##*:}"
  for _ in $(seq 1 20); do
    curl -fsS "http://127.0.0.1:$PORT/health" 2> /dev/null | grep -q '"health":"true"' && return 0
    sleep 0.5
  done
  echo "etcd did not become healthy"
  "$ENGINE" logs "$CONTAINER"
  return 1
}

echo "Testing non-root user (65532)..."
USER_CONF="$("$ENGINE" inspect --format='{{.Config.User}}' "$IMAGE")"
if [ "$USER_CONF" != "65532" ]; then
  echo "Unexpected User configuration: $USER_CONF (expected 65532)"
  exit 1
fi

echo "Testing etcd version ($STREAM.x)..."
OUT="$(run --version | head -n 1)"
if [[ "$OUT" != "etcd Version: $STREAM."* ]]; then
  echo "Unexpected version: $OUT (expected $STREAM.x)"
  exit 1
fi
for tool in etcdctl etcdutl; do
  OUT="$("$ENGINE" run --rm --entrypoint "$tool" "$IMAGE" version | head -n 1)"
  if [[ "$OUT" != "$tool version: $STREAM."* ]]; then
    echo "Unexpected $tool version: $OUT (expected $STREAM.x)"
    exit 1
  fi
done

echo "Testing a single-member cluster through the default entrypoint..."
"$ENGINE" volume create "$VOLUME" > /dev/null
start
ctl endpoint health > /dev/null || { echo "etcdctl endpoint health failed"; exit 1; }
[ "$(ctl put greeting 'Hello World')" = "OK" ] || { echo "put failed"; exit 1; }
OUT="$(ctl get greeting --print-value-only)"
[ "$OUT" = "Hello World" ] || { echo "Unexpected get response: $OUT"; exit 1; }

echo "Testing the published client port..."
# The v3 JSON gateway takes base64 keys: "greeting" is Z3JlZXRpbmc=.
OUT="$(curl -fsS "http://127.0.0.1:$PORT/v3/kv/range" -d '{"key":"Z3JlZXRpbmc="}')"
[[ "$OUT" == *'"value":"SGVsbG8gV29ybGQ="'* ]] || { echo "Unexpected gateway response: $OUT"; exit 1; }

echo "Testing persistence in /var/lib/etcd across restarts..."
start
OUT="$(ctl get greeting --print-value-only)"
[ "$OUT" = "Hello World" ] || { echo "Data not persisted: ${OUT:-none}"; exit 1; }

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

echo "All etcd sanity tests passed successfully."
