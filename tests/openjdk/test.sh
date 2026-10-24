#!/usr/bin/env bash
# Sanity tests for the OpenJDK images (JDK, runtime and builder variants).
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

echo "Testing Java version ($STREAM)..."
OUT="$(run java -version 2>&1)"
if [[ "$OUT" != *"version \"$STREAM."* ]]; then
  echo "Unexpected version: $OUT"
  exit 1
fi

echo "Testing CA trust store..."
OUT="$(run keytool -list -cacerts -storepass changeit)"
grep -Eq 'contains [1-9][0-9]* entries' <<< "$OUT" || {
  echo "Java cacerts trust store is empty or unreadable"
  exit 1
}

cat > "$WORKDIR/Hello.java" <<'EOF'
public class Hello {
    public static void main(String[] args) { System.out.println("Hello World"); }
}
EOF
chmod -R a+rX "$WORKDIR"

case "$VARIANT" in
  -runtime)
    echo "Testing source launcher on the JRE..."
    OUT="$(run java /src/Hello.java)"
    [ "$OUT" = "Hello World" ] || { echo "Unexpected output: $OUT"; exit 1; }

    echo "Verifying distroless runtime (no shell, no javac)..."
    fails /bin/sh -c true || { echo "Security check failed: runtime ships /bin/sh"; exit 1; }
    fails javac -version || { echo "runtime variant must not ship javac"; exit 1; }
    ;;
  *)
    echo "Testing javac compile and run..."
    OUT="$(run sh -c 'cd /tmp && javac -d . /src/Hello.java && java -cp . Hello')"
    [ "$OUT" = "Hello World" ] || { echo "Unexpected output: $OUT"; exit 1; }

    echo "Testing package manager presence for variant '${VARIANT:-default}'..."
    if run sh -c 'command -v dnf' > /dev/null; then HAS_DNF=yes; else HAS_DNF=no; fi
    case "$VARIANT" in
      -builder) [ "$HAS_DNF" = yes ] || { echo "builder variant must ship dnf"; exit 1; } ;;
      *)        [ "$HAS_DNF" = no ]  || { echo "JDK variant must not ship dnf"; exit 1; } ;;
    esac
    ;;
esac

echo "All openjdk sanity tests passed successfully."
