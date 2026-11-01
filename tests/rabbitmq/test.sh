#!/usr/bin/env bash
# Sanity tests for the RabbitMQ images (default and builder variants).
# Usage: test.sh <image-ref> <tag>   (set CONTAINER_ENGINE=podman to run locally)
set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref> <tag>}"
TAG="${2:?usage: $0 <image-ref> <tag>}"
ENGINE="${CONTAINER_ENGINE:-docker}"
STREAM="${TAG%%-*}"
VARIANT="${TAG#"$STREAM"}"
WORKDIR="$(mktemp -d)"
VOLUME="rabbitmq-test-$$"
CONTAINER=""
cleanup() {
  [ -z "$CONTAINER" ] || "$ENGINE" rm -f "$CONTAINER" > /dev/null 2>&1 || true
  "$ENGINE" volume rm -f "$VOLUME" > /dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

fails() { ! "$ENGINE" run --rm --entrypoint "$1" "$IMAGE" "${@:2}" > /dev/null 2>&1; }
ctl() { "$ENGINE" exec "$CONTAINER" "$@"; }

# /etc/rabbitmq is not writable by the server user, so plugins are enabled by
# mounting an enabled_plugins file.
echo '[rabbitmq_management].' > "$WORKDIR/enabled_plugins"
chmod -R a+rX "$WORKDIR"

# Replaces the running container with a broker on the data volume and waits
# until it accepts connections. The node name, and with it the data directory
# under /var/lib/rabbitmq/mnesia, comes from the hostname, so it is fixed.
start() {
  [ -z "$CONTAINER" ] || "$ENGINE" rm -f "$CONTAINER" > /dev/null
  CONTAINER="$("$ENGINE" run -d --hostname rabbitmq-test \
    -p 127.0.0.1::5672 -p 127.0.0.1::15672 \
    -v "$VOLUME:/var/lib/rabbitmq" \
    -v "$WORKDIR/enabled_plugins:/etc/rabbitmq/enabled_plugins:ro,z" \
    "$IMAGE")"
  for _ in $(seq 1 60); do
    ctl rabbitmq-diagnostics -q check_port_connectivity > /dev/null 2>&1 && break
    sleep 1
  done
  ctl rabbitmq-diagnostics -q check_port_connectivity > /dev/null 2>&1 || {
    echo "RabbitMQ did not start"
    "$ENGINE" logs "$CONTAINER"
    return 1
  }
  AMQP_PORT="$("$ENGINE" port "$CONTAINER" 5672/tcp | sed -n 1p)"
  AMQP_PORT="${AMQP_PORT##*:}"
  HTTP_PORT="$("$ENGINE" port "$CONTAINER" 15672/tcp | sed -n 1p)"
  HTTP_PORT="${HTTP_PORT##*:}"
}

# Calls the management HTTP API as the test user.
api() {
  curl -fsS -u "tester:$PASSWORD" -H 'content-type: application/json' \
    "http://127.0.0.1:$HTTP_PORT/api/$1" "${@:2}"
}

echo "Testing non-root user (65532)..."
USER_CONF="$("$ENGINE" inspect --format='{{.Config.User}}' "$IMAGE")"
if [ "$USER_CONF" != "65532" ]; then
  echo "Unexpected User configuration: $USER_CONF (expected 65532)"
  exit 1
fi

echo "Testing RabbitMQ version ($STREAM.x)..."
OUT="$("$ENGINE" run --rm --entrypoint rabbitmqctl "$IMAGE" version)"
if [[ "$OUT" != "$STREAM."* ]]; then
  echo "Unexpected version: $OUT (expected $STREAM.x)"
  exit 1
fi

echo "Testing the broker through the default entrypoint..."
"$ENGINE" volume create "$VOLUME" > /dev/null
start
ctl rabbitmq-diagnostics -q ping > /dev/null || { echo "rabbitmq-diagnostics ping failed"; exit 1; }
OUT="$(ctl rabbitmq-plugins -q list -E)"
[[ "$OUT" == *rabbitmq_management* ]] || { echo "Management plugin not enabled: $OUT"; exit 1; }

echo "Testing the AMQP handshake on the published port..."
# A client's protocol header must be answered with a connection.start method
# frame: type 1, channel 0, then class 10 method 10 after the frame size.
exec 3<> "/dev/tcp/127.0.0.1/$AMQP_PORT"
printf 'AMQP\x00\x00\x09\x01' >&3
OUT="$(timeout 5 head -c 11 <&3 | od -An -tx1 | tr -d ' \n' || true)"
exec 3>&-
[[ "$OUT" == 010000????????000a000a ]] || { echo "Unexpected AMQP response: ${OUT:-none}"; exit 1; }

echo "Testing the guest user is refused for remote clients..."
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -u guest:guest "http://127.0.0.1:$HTTP_PORT/api/overview")"
[ "$CODE" = "401" ] || { echo "Expected guest to be refused remotely, got HTTP $CODE"; exit 1; }

echo "Testing a durable queue through the management API..."
PASSWORD="test-$$"
ctl rabbitmqctl -q add_user tester "$PASSWORD" > /dev/null
ctl rabbitmqctl -q set_user_tags tester management > /dev/null
ctl rabbitmqctl -q set_permissions -p / tester '.*' '.*' '.*' > /dev/null
api queues/%2F/greetings -X PUT -d '{"durable":true}' > /dev/null
OUT="$(api exchanges/%2F/amq.default/publish \
  -d '{"properties":{"delivery_mode":2},"routing_key":"greetings","payload":"Hello World","payload_encoding":"string"}')"
[[ "$OUT" == *'"routed":true'* ]] || { echo "Message not routed: $OUT"; exit 1; }

echo "Testing persistence in /var/lib/rabbitmq across restarts..."
start
OUT="$(api queues/%2F/greetings/get -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}')"
[[ "$OUT" == *'"payload":"Hello World"'* ]] || { echo "Message not persisted: $OUT"; exit 1; }

echo "Testing shell and package manager for variant '${VARIANT:-default}'..."
case "$VARIANT" in
  -builder)
    fails sh -c 'command -v dnf' && { echo "builder variant must ship sh and dnf"; exit 1; }
    ;;
  *)
    # The default variant ships bash for the RabbitMQ CLI scripts; it must not
    # ship a package manager.
    fails dnf --version || { echo "default variant must not ship dnf"; exit 1; }
    ;;
esac

echo "All rabbitmq sanity tests passed successfully."
