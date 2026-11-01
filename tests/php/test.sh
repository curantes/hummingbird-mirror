#!/usr/bin/env bash
# Sanity tests for the PHP images (CLI and FPM, default and builder variants).
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

# The CLI images' entrypoint is php and the FPM images' is php-fpm, so name
# the executable explicitly.
run() { "$ENGINE" run --rm -v "$WORKDIR:/src:ro,z" -e HOME=/tmp --entrypoint "$1" "$IMAGE" "${@:2}"; }
fails() { ! "$ENGINE" run --rm --entrypoint "$1" "$IMAGE" "${@:2}" > /dev/null 2>&1; }

# Sends one FastCGI request for SCRIPT_FILENAME=$2 to 127.0.0.1:$1 and prints
# the response with the record framing's NUL bytes stripped.
fcgi_get() {
  local port="$1" script="$2" params len
  params="$WORKDIR/params"
  : > "$params"
  for kv in "SCRIPT_FILENAME=$script" "REQUEST_METHOD=GET" "SERVER_PROTOCOL=HTTP/1.1"; do
    local k="${kv%%=*}" v="${kv#*=}"
    printf "\\x$(printf %02x "${#k}")\\x$(printf %02x "${#v}")%s%s" "$k" "$v" >> "$params"
  done
  len="$(wc -c < "$params")"
  exec 3<> "/dev/tcp/127.0.0.1/$port"
  {
    printf '\x01\x01\x00\x01\x00\x08\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00' # BEGIN_REQUEST, responder
    printf "\\x01\\x04\\x00\\x01\\x$(printf %02x $((len >> 8)))\\x$(printf %02x $((len & 255)))\\x00\\x00"
    cat "$params"
    printf '\x01\x04\x00\x01\x00\x00\x00\x00' # end of PARAMS
    printf '\x01\x05\x00\x01\x00\x00\x00\x00' # empty STDIN
  } >&3
  timeout 10 cat <&3 | tr -d '\0'
  exec 3<&-
}

# Exercises common extensions and the CA trust store; runs under CLI and FPM.
cat > "$WORKDIR/hello.php" <<'EOF'
<?php
$certs = openssl_get_cert_locations();
$n = is_file($certs['default_cert_file'])
    ? substr_count(file_get_contents($certs['default_cert_file']), 'BEGIN CERTIFICATE') : 0;
$n += count(glob($certs['default_cert_dir'] . '/*') ?: []);
if ($n === 0) {
    exit("OpenSSL trust store is empty or unreadable\n");
}
$db = new PDO('sqlite::memory:');
$db->exec('CREATE TABLE t (s TEXT)');
$db->exec("INSERT INTO t VALUES ('Hello World')");
$s = $db->query('SELECT s FROM t')->fetchColumn();
hash('sha256', gzcompress(json_encode([mb_strtoupper($s)])));
echo $s, "\n";
EOF
chmod -R a+rX "$WORKDIR"

case "$VARIANT" in
  -fpm*)
    echo "Testing non-root user (65532)..."
    USER_CONF="$("$ENGINE" inspect --format='{{.Config.User}}' "$IMAGE")"
    if [ "$USER_CONF" != "65532" ]; then
      echo "Unexpected User configuration: $USER_CONF (expected 65532)"
      exit 1
    fi

    echo "Testing PHP-FPM version ($STREAM.x)..."
    OUT="$(run php-fpm -v | sed -n 1p)"
    if [[ "$OUT" != "PHP $STREAM."*"(fpm-fcgi)"* ]]; then
      echo "Unexpected version: $OUT (expected PHP $STREAM.x fpm-fcgi)"
      exit 1
    fi

    echo "Testing PHP-FPM configuration..."
    run php-fpm -t > /dev/null 2>&1 || { echo "php-fpm -t failed"; exit 1; }

    echo "Testing FastCGI request against the default entrypoint..."
    CONTAINER="$("$ENGINE" run -d -p 127.0.0.1::9000 -v "$WORKDIR:/src:ro,z" "$IMAGE")"
    PORT="$("$ENGINE" port "$CONTAINER" 9000/tcp | sed -n 1p)"
    PORT="${PORT##*:}"
    for _ in $(seq 1 20); do
      "$ENGINE" logs "$CONTAINER" 2>&1 | grep 'ready to handle connections' > /dev/null && break
      sleep 0.5
    done
    OUT="$(fcgi_get "$PORT" /src/hello.php)"
    if [[ "$OUT" != *$'\r\n\r\n'"Hello World"* ]]; then
      echo "Unexpected FastCGI response: $OUT"
      "$ENGINE" logs "$CONTAINER"
      exit 1
    fi
    ;;
  *)
    echo "Testing PHP version ($STREAM.x)..."
    OUT="$(run php -r 'echo PHP_VERSION;')"
    if [[ "$OUT" != "$STREAM."* ]]; then
      echo "Unexpected version: $OUT (expected $STREAM.x)"
      exit 1
    fi

    echo "Testing script with common extensions..."
    OUT="$(run php /src/hello.php)"
    [ "$OUT" = "Hello World" ] || { echo "Unexpected output: $OUT"; exit 1; }
    ;;
esac

echo "Testing shell, Composer and package manager for variant '${VARIANT:-default}'..."
case "$VARIANT" in
  *-builder)
    run sh -c 'command -v dnf' > /dev/null || { echo "builder variant must ship sh and dnf"; exit 1; }
    run sh -c 'cd /tmp && composer init -q -n --name test/app --autoload src/ \
      && composer dump-autoload -q && test -f vendor/autoload.php' \
      || { echo "Composer failed to set up a project"; exit 1; }
    ;;
  -fpm)
    fails /bin/sh -c true || { echo "Security check failed: fpm variant ships /bin/sh"; exit 1; }
    fails dnf --version || { echo "fpm variant must not ship dnf"; exit 1; }
    ;;
  *)
    fails dnf --version || { echo "default variant must not ship dnf"; exit 1; }
    ;;
esac

echo "All php sanity tests passed successfully."
