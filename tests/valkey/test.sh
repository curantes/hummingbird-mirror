#!/usr/bin/env bash
# Sanity tests for the Valkey images (default and builder variants).
# Usage: test.sh <image-ref> <tag>   (set CONTAINER_ENGINE=podman to run locally)
set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref> <tag>}"
TAG="${2:?usage: $0 <image-ref> <tag>}"
ENGINE="${CONTAINER_ENGINE:-docker}"
STREAM="${TAG%%-*}"
VARIANT="${TAG#"$STREAM"}"
VOLUME="valkey-test-$$"
CONTAINER=""
cleanup() {
  [ -z "$CONTAINER" ] || "$ENGINE" rm -f "$CONTAINER" > /dev/null 2>&1 || true
  "$ENGINE" volume rm -f "$VOLUME" > /dev/null 2>&1 || true
}
trap cleanup EXIT

run() { "$ENGINE" run --rm "$IMAGE" "$@"; }
fails() { ! "$ENGINE" run --rm --entrypoint "$1" "$IMAGE" "${@:2}" > /dev/null 2>&1; }

# valkey-cli authenticates from VALKEYCLI_AUTH once a password is set.
PASSWORD=""
cli() { "$ENGINE" exec ${PASSWORD:+-e "VALKEYCLI_AUTH=$PASSWORD"} "$CONTAINER" valkey-cli "$@"; }

# Sends raw RESP commands to the published port and prints the first $1
# reply bytes without carriage returns.
remote() {
  local port
  port="$("$ENGINE" port "$CONTAINER" 6379/tcp | sed -n 1p)"
  exec 3<> "/dev/tcp/127.0.0.1/${port##*:}"
  printf '%s' "$2" >&3
  { timeout 5 head -c "$1" <&3 || true; } | tr -d '\r'
  exec 3>&-
}

# Replaces the running container with a server on the data volume, publishes
# 6379 and waits until it answers PING.
start() {
  [ -z "$CONTAINER" ] || "$ENGINE" rm -f "$CONTAINER" > /dev/null
  CONTAINER="$("$ENGINE" run -d -p 127.0.0.1::6379 -v "$VOLUME:/data" "$IMAGE" "$@")"
  for _ in $(seq 1 20); do
    [ "$(cli ping 2> /dev/null)" = "PONG" ] && return 0
    sleep 0.5
  done
  echo "valkey-server did not answer PING"
  "$ENGINE" logs "$CONTAINER"
  return 1
}

echo "Testing non-root user (65532)..."
USER_CONF="$("$ENGINE" inspect --format='{{.Config.User}}' "$IMAGE")"
if [ "$USER_CONF" != "65532" ]; then
  echo "Unexpected User configuration: $USER_CONF (expected 65532)"
  exit 1
fi

echo "Testing Valkey version ($STREAM.x)..."
OUT="$(run --version)"
if [[ "$OUT" != "Valkey server v=$STREAM."* ]]; then
  echo "Unexpected version: $OUT (expected v=$STREAM.x)"
  exit 1
fi
OUT="$("$ENGINE" run --rm --entrypoint valkey-cli "$IMAGE" --version)"
if [[ "$OUT" != "valkey-cli $STREAM."* ]]; then
  echo "Unexpected valkey-cli version: $OUT (expected $STREAM.x)"
  exit 1
fi

echo "Testing commands through the default entrypoint..."
"$ENGINE" volume create "$VOLUME" > /dev/null
start
[ "$(cli set greeting 'Hello World')" = "OK" ] || { echo "SET failed"; exit 1; }
OUT="$(cli get greeting)"
[ "$OUT" = "Hello World" ] || { echo "Unexpected GET response: $OUT"; exit 1; }
[ "$(cli incrby counter 41)" = "41" ] || { echo "INCRBY failed"; exit 1; }

echo "Testing persistence in /data across restarts..."
[ "$(cli save)" = "OK" ] || { echo "SAVE failed (is /data writable?)"; exit 1; }
start
OUT="$(cli get greeting)"
[ "$OUT" = "Hello World" ] || { echo "Data not persisted: ${OUT:-none}"; exit 1; }

echo "Testing protected mode on the published port..."
# Without a configuration or password, Valkey only serves loopback clients.
OUT="$(remote 7 $'PING\r\n')"
[ "$OUT" = "-DENIED" ] || { echo "Expected protected mode to deny remote clients, got: ${OUT:-none}"; exit 1; }

echo "Testing a password-protected server on the published port..."
PASSWORD="test-$$"
start --requirepass "$PASSWORD"
OUT="$(cli get greeting)"
[ "$OUT" = "Hello World" ] || { echo "Unexpected GET response: ${OUT:-none}"; exit 1; }
OUT="$(remote 12 "AUTH $PASSWORD"$'\r\nPING\r\n')"
[ "$OUT" = $'+OK\n+PONG' ] || { echo "Unexpected remote response: ${OUT:-none}"; exit 1; }

echo "Testing shell and package manager for variant '${VARIANT:-default}'..."
case "$VARIANT" in
  -builder)
    fails sh -c 'command -v dnf' && { echo "builder variant must ship sh and dnf"; exit 1; }
    ;;
  *)
    # The default variant ships bash; it must not ship a package manager.
    fails dnf --version || { echo "default variant must not ship dnf"; exit 1; }
    ;;
esac

echo "All valkey sanity tests passed successfully."
