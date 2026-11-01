#!/usr/bin/env bash
# Sanity tests for the curl images (default and builder variants).
# Usage: test.sh <image-ref> <tag>   (set CONTAINER_ENGINE=podman to run locally)
# Requires openssl and python3 on the host.
set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref> <tag>}"
TAG="${2:?usage: $0 <image-ref> <tag>}"
ENGINE="${CONTAINER_ENGINE:-docker}"
STREAM="${TAG%%-*}"
VARIANT="${TAG#"$STREAM"}"
WORKDIR="$(mktemp -d)"
SERVER=""
cleanup() {
  [ -z "$SERVER" ] || kill "$SERVER" 2> /dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

run() { "$ENGINE" run --rm "$IMAGE" "$@"; }
# Runs curl on the host network, with the test CA mounted at /tmp/ca.crt.
run_host() { "$ENGINE" run --rm --network host -v "$WORKDIR/ca.crt:/tmp/ca.crt:ro,z" "$IMAGE" "$@"; }
fails() { ! "$ENGINE" run --rm --entrypoint "$1" "$IMAGE" "${@:2}" > /dev/null 2>&1; }

echo "Testing non-root user (65532)..."
USER_CONF="$("$ENGINE" inspect --format='{{.Config.User}}' "$IMAGE")"
if [ "$USER_CONF" != "65532" ]; then
  echo "Unexpected User configuration: $USER_CONF (expected 65532)"
  exit 1
fi

echo "Testing curl version ($STREAM.x) and features..."
OUT="$(run --version)"
if [[ "$(head -n 1 <<< "$OUT")" != "curl $STREAM."* ]]; then
  echo "Unexpected version: $(head -n 1 <<< "$OUT") (expected curl $STREAM.x)"
  exit 1
fi
for want in "Protocols:.* https( |$)" "Features:.* HTTP2( |$)" "Features:.* SSL( |$)"; do
  grep -Eq "$want" <<< "$OUT" || { echo "Missing in curl --version: $want"; echo "$OUT"; exit 1; }
done

echo "Testing the system CA bundle..."
COUNT="$(run -fsS file:///etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem | grep -c 'BEGIN CERTIFICATE')"
[ "$COUNT" -gt 50 ] || { echo "CA bundle has only $COUNT certificates"; exit 1; }

echo "Testing HTTPS against a local server..."
# A throwaway CA signs a certificate for 127.0.0.1; python serves it on the
# host, and curl reaches it through the host network.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Test CA' \
  -keyout "$WORKDIR/ca.key" -out "$WORKDIR/ca.crt" 2> /dev/null
openssl req -newkey rsa:2048 -nodes -subj '/CN=127.0.0.1' \
  -keyout "$WORKDIR/server.key" -out "$WORKDIR/server.csr" 2> /dev/null
openssl x509 -req -days 1 -in "$WORKDIR/server.csr" -CA "$WORKDIR/ca.crt" -CAkey "$WORKDIR/ca.key" \
  -CAcreateserial -extfile <(printf 'subjectAltName=IP:127.0.0.1\n') -out "$WORKDIR/server.crt" 2> /dev/null
mkdir "$WORKDIR/www"
echo "Hello World" > "$WORKDIR/www/hello.txt"
cat > "$WORKDIR/server.py" <<'EOF'
import functools, http.server, ssl, sys
work = sys.argv[1]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=f"{work}/www")
httpd = http.server.HTTPServer(("127.0.0.1", 0), handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(f"{work}/server.crt", f"{work}/server.key")
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
with open(f"{work}/port", "w") as f:
    f.write(str(httpd.server_address[1]))
httpd.serve_forever()
EOF
python3 "$WORKDIR/server.py" "$WORKDIR" 2> /dev/null &
SERVER=$!
for _ in $(seq 1 20); do [ -s "$WORKDIR/port" ] && break; sleep 0.25; done
PORT="$(cat "$WORKDIR/port")"
chmod -R a+rX "$WORKDIR"
OUT="$(run_host -fsS --cacert /tmp/ca.crt "https://127.0.0.1:$PORT/hello.txt")"
[ "$OUT" = "Hello World" ] || { echo "Unexpected HTTPS response: ${OUT:-none}"; exit 1; }

echo "Testing certificate verification..."
RC=0
run_host -fsS "https://127.0.0.1:$PORT/hello.txt" > /dev/null 2>&1 || RC=$?
[ "$RC" -eq 60 ] || { echo "Expected an untrusted certificate to fail with exit 60, got $RC"; exit 1; }

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

echo "All curl sanity tests passed successfully."
