#!/usr/bin/env bash
# Sanity tests for the Rust toolchain images.
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

echo "Testing Rust version (rustc/cargo $STREAM.x)..."
OUT="$(run rustc --version)"
if [[ "$OUT" != "rustc $STREAM."* ]]; then
  echo "Unexpected version: $OUT (expected rustc $STREAM.x)"
  exit 1
fi
OUT="$(run cargo --version)"
if [[ "$OUT" != "cargo $STREAM."* ]]; then
  echo "Unexpected version: $OUT (expected cargo $STREAM.x)"
  exit 1
fi

echo "Testing cargo project build (offline, release)..."
OUT="$(run sh -c 'cd /tmp && cargo new -q hello && cd hello \
  && cargo build -q --release --offline && ./target/release/hello')"
if [ "$OUT" != "Hello, world!" ]; then
  echo "Unexpected output: $OUT"
  exit 1
fi

# -sys crates compile C code with cc and link it into the Rust binary.
cat > "$WORKDIR/add.c" <<'EOF'
int add(int a, int b) { return a + b; }
EOF
cat > "$WORKDIR/main.rs" <<'EOF'
extern "C" {
    fn add(a: i32, b: i32) -> i32;
}

fn main() {
    println!("{}", unsafe { add(40, 2) });
}
EOF
chmod -R a+rX "$WORKDIR"

echo "Testing C interop (cc + static library)..."
OUT="$(run sh -c 'cd /tmp && cc -c /src/add.c -o add.o && ar rcs libadd.a add.o \
  && rustc -L . -l static=add /src/main.rs -o main && ./main')"
if [ "$OUT" != "42" ]; then
  echo "Unexpected output: $OUT"
  exit 1
fi

echo "Testing package manager presence for variant '${VARIANT:-default}'..."
if run sh -c 'command -v dnf' > /dev/null; then HAS_DNF=yes; else HAS_DNF=no; fi
case "$VARIANT" in
  -builder) [ "$HAS_DNF" = yes ] || { echo "builder variant must ship dnf"; exit 1; } ;;
  *)        [ "$HAS_DNF" = no ]  || { echo "default variant must not ship dnf"; exit 1; } ;;
esac

echo "All rust sanity tests passed successfully."
