#!/usr/bin/env bash
# Sanity tests for the git images (default and builder variants).
# Usage: test.sh <image-ref> <tag>   (set CONTAINER_ENGINE=podman to run locally)
# Requires git and python3 on the host.
set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref> <tag>}"
TAG="${2:?usage: $0 <image-ref> <tag>}"
ENGINE="${CONTAINER_ENGINE:-docker}"
STREAM="${TAG%%-*}"
VARIANT="${TAG#"$STREAM"}"
WORKDIR="$(mktemp -d)"
VOLUME="git-test-$$"
SERVER=""
cleanup() {
  [ -z "$SERVER" ] || kill "$SERVER" 2> /dev/null || true
  "$ENGINE" volume rm -f "$VOLUME" > /dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Runs git in /git on the data volume, with a committer identity.
git_in() {
  "$ENGINE" run --rm --network host -v "$VOLUME:/git" \
    -e GIT_AUTHOR_NAME=Test -e GIT_AUTHOR_EMAIL=test@example.com \
    -e GIT_COMMITTER_NAME=Test -e GIT_COMMITTER_EMAIL=test@example.com \
    "$IMAGE" "$@"
}
fails() { ! "$ENGINE" run --rm --entrypoint "$1" "$IMAGE" "${@:2}" > /dev/null 2>&1; }

echo "Testing non-root user (65532)..."
USER_CONF="$("$ENGINE" inspect --format='{{.Config.User}}' "$IMAGE")"
if [ "$USER_CONF" != "65532" ]; then
  echo "Unexpected User configuration: $USER_CONF (expected 65532)"
  exit 1
fi

echo "Testing git version ($STREAM.x)..."
OUT="$("$ENGINE" run --rm "$IMAGE" --version)"
if [[ "$OUT" != "git version $STREAM."* ]]; then
  echo "Unexpected version: $OUT (expected git version $STREAM.x)"
  exit 1
fi
"$ENGINE" run --rm "$IMAGE" > /dev/null || { echo "Default command (git --help) failed"; exit 1; }

echo "Testing a repository in the /git volume..."
"$ENGINE" volume create "$VOLUME" > /dev/null
git_in init -q -b main repo
git_in -C repo commit -q --allow-empty -m "Hello World"
OUT="$(git_in -C repo log -1 --format=%s)"
[ "$OUT" = "Hello World" ] || { echo "Unexpected commit message: $OUT"; exit 1; }
git_in clone -q repo copy
OUT="$(git_in -C copy log -1 --format=%s)"
[ "$OUT" = "Hello World" ] || { echo "Local clone failed: $OUT"; exit 1; }

echo "Testing a clone over HTTP..."
# The host serves a bare repository with the dumb HTTP protocol.
git -c init.defaultBranch=main init -q "$WORKDIR/src"
echo "Hello World" > "$WORKDIR/src/hello.txt"
git -C "$WORKDIR/src" add hello.txt
git -C "$WORKDIR/src" -c user.name=Test -c user.email=test@example.com commit -q -m "Add hello"
git clone -q --bare "$WORKDIR/src" "$WORKDIR/www/hello.git"
git -C "$WORKDIR/www/hello.git" update-server-info
cat > "$WORKDIR/server.py" <<'EOF'
import functools, http.server, sys
work = sys.argv[1]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=f"{work}/www")
httpd = http.server.HTTPServer(("127.0.0.1", 0), handler)
with open(f"{work}/port", "w") as f:
    f.write(str(httpd.server_address[1]))
httpd.serve_forever()
EOF
python3 "$WORKDIR/server.py" "$WORKDIR" 2> /dev/null &
SERVER=$!
for _ in $(seq 1 20); do [ -s "$WORKDIR/port" ] && break; sleep 0.25; done
PORT="$(cat "$WORKDIR/port")"
git_in clone -q "http://127.0.0.1:$PORT/hello.git" http-clone
OUT="$(git_in -C http-clone show HEAD:hello.txt)"
[ "$OUT" = "Hello World" ] || { echo "Unexpected file from HTTP clone: ${OUT:-none}"; exit 1; }

echo "Testing the HTTPS remote helper..."
# Nothing listens on port 1: the clone must fail on the connection, which
# shows that git-remote-https exists.
OUT="$(git_in ls-remote https://127.0.0.1:1/none.git 2>&1 || true)"
[[ "$OUT" == *"Failed to connect"* ]] || { echo "Unexpected HTTPS error: $OUT"; exit 1; }

echo "Testing the ssh client..."
OUT="$("$ENGINE" run --rm --entrypoint ssh "$IMAGE" -V 2>&1)"
[[ "$OUT" == OpenSSH_* ]] || { echo "Unexpected ssh -V output: $OUT"; exit 1; }

echo "Testing shell and package manager for variant '${VARIANT:-default}'..."
case "$VARIANT" in
  -builder)
    fails sh -c 'command -v dnf' && { echo "builder variant must ship sh and dnf"; exit 1; }
    ;;
  *)
    # The default variant ships bash for git's hooks and aliases; it must not
    # ship a package manager.
    fails dnf --version || { echo "default variant must not ship dnf"; exit 1; }
    ;;
esac

echo "All git sanity tests passed successfully."
