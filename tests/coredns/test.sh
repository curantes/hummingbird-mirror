#!/usr/bin/env bash
# Sanity tests for the CoreDNS images (default and builder variants).
# Usage: test.sh <image-ref> <tag>   (set CONTAINER_ENGINE=podman to run locally)
# Requires dig on the host.
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

command -v dig > /dev/null || { echo "dig is required on the host"; exit 1; }

run() { "$ENGINE" run --rm "$IMAGE" "$@"; }
fails() { ! "$ENGINE" run --rm --entrypoint "$1" "$IMAGE" "${@:2}" > /dev/null 2>&1; }

# Replaces the running container with one started with extra run arguments,
# publishing DNS on 53/udp and 53/tcp and the health and readiness endpoints.
# The binary has no file capabilities, so binding port 53 as 65532 needs the
# engine to allow unprivileged low ports: Docker does by default, Podman not.
start() {
  [ -z "$CONTAINER" ] || "$ENGINE" rm -f "$CONTAINER" > /dev/null
  CONTAINER="$("$ENGINE" run -d --sysctl net.ipv4.ip_unprivileged_port_start=0 \
    -p 127.0.0.1::53/udp -p 127.0.0.1::53/tcp \
    -p 127.0.0.1::8080 -p 127.0.0.1::8181 "$@")"
  port() { local p; p="$("$ENGINE" port "$CONTAINER" "$1" | head -n 1)"; echo "${p##*:}"; }
  UDP_PORT="$(port 53/udp)"
  TCP_PORT="$(port 53/tcp)"
  HEALTH_PORT="$(port 8080/tcp)"
  READY_PORT="$(port 8181/tcp)"
}

# Queries the running server until dig prints an answer; arguments go to dig
# (default output: +short).
query() {
  local out
  for _ in $(seq 1 20); do
    out="$(dig @127.0.0.1 -p "$UDP_PORT" +tries=1 +time=1 "$@" 2> /dev/null)" && [ -n "$out" ] \
      && { echo "$out"; return 0; }
    sleep 0.5
  done
  echo "CoreDNS did not answer: dig $*" >&2
  "$ENGINE" logs "$CONTAINER" >&2
  return 1
}

echo "Testing non-root user (65532)..."
USER_CONF="$("$ENGINE" inspect --format='{{.Config.User}}' "$IMAGE")"
if [ "$USER_CONF" != "65532" ]; then
  echo "Unexpected User configuration: $USER_CONF (expected 65532)"
  exit 1
fi

echo "Testing CoreDNS version ($STREAM.x)..."
OUT="$(run -version | head -n 1)"
if [[ "$OUT" != "CoreDNS-$STREAM."* ]]; then
  echo "Unexpected version: $OUT (expected CoreDNS-$STREAM.x)"
  exit 1
fi

echo "Testing the default configuration (whoami on port 53)..."
# Without a Corefile, CoreDNS serves the whoami plugin on port 53.
start "$IMAGE"
# whoami reports the client address in the additional section.
OUT="$(query +noall +additional whoami.example A)"
[[ "$OUT" =~ ^whoami\.example\.[[:space:]].*[[:space:]]A[[:space:]] ]] || { echo "Unexpected whoami answer: $OUT"; exit 1; }

echo "Testing a mounted Corefile..."
cat > "$WORKDIR/Corefile" <<'EOF'
example.test:53 {
    hosts {
        192.0.2.10 hello.example.test
        fallthrough
    }
    template IN TXT example.test {
        answer "{{ .Name }} 60 IN TXT \"Hello World\""
    }
    errors
}

.:53 {
    health :8080
    ready :8181
    errors
}
EOF
chmod -R a+rX "$WORKDIR"
start -v "$WORKDIR/Corefile:/etc/coredns/Corefile:ro,z" "$IMAGE" -conf /etc/coredns/Corefile
OUT="$(query +short hello.example.test A)"
[ "$OUT" = "192.0.2.10" ] || { echo "Unexpected A answer: $OUT"; exit 1; }
OUT="$(query +short greeting.example.test TXT)"
[ "$OUT" = '"Hello World"' ] || { echo "Unexpected TXT answer: $OUT"; exit 1; }
OUT="$(dig @127.0.0.1 -p "$TCP_PORT" +tcp +short +tries=1 +time=2 hello.example.test A)"
[ "$OUT" = "192.0.2.10" ] || { echo "Unexpected answer over TCP: ${OUT:-none}"; exit 1; }

echo "Testing the health and readiness endpoints..."
OUT="$(curl -fsS "http://127.0.0.1:$HEALTH_PORT/health")"
[ "$OUT" = "OK" ] || { echo "Unexpected health response: $OUT"; exit 1; }
OUT="$(curl -fsS "http://127.0.0.1:$READY_PORT/ready")"
[ "$OUT" = "OK" ] || { echo "Unexpected ready response: $OUT"; exit 1; }

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

echo "All coredns sanity tests passed successfully."
