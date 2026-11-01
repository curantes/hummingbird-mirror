#!/usr/bin/env bash
# Sanity tests for the OpenTofu images (default and builder variants).
# Usage: test.sh <image-ref> <tag>   (set CONTAINER_ENGINE=podman to run locally)
set -euo pipefail

IMAGE="${1:?usage: $0 <image-ref> <tag>}"
TAG="${2:?usage: $0 <image-ref> <tag>}"
ENGINE="${CONTAINER_ENGINE:-docker}"
STREAM="${TAG%%-*}"
VARIANT="${TAG#"$STREAM"}"
WORKDIR="$(mktemp -d)"
VOLUME="opentofu-test-$$"
cleanup() {
  "$ENGINE" volume rm -f "$VOLUME" > /dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Runs tofu on the read-only configuration in /work. Its data directory and
# state live in /tmp on the volume, so they persist between runs.
tofu() {
  "$ENGINE" run --rm -v "$WORKDIR/config:/work:ro,z" -v "$VOLUME:/tmp" \
    -e TF_DATA_DIR=/tmp/tf-data -e TF_IN_AUTOMATION=1 \
    "$IMAGE" -chdir=/work "$@"
}
fails() { ! "$ENGINE" run --rm --entrypoint "$1" "$IMAGE" "${@:2}" > /dev/null 2>&1; }

echo "Testing non-root user (65532)..."
USER_CONF="$("$ENGINE" inspect --format='{{.Config.User}}' "$IMAGE")"
if [ "$USER_CONF" != "65532" ]; then
  echo "Unexpected User configuration: $USER_CONF (expected 65532)"
  exit 1
fi

echo "Testing OpenTofu version ($STREAM.x)..."
OUT="$("$ENGINE" run --rm "$IMAGE" version | head -n 1)"
if [[ "$OUT" != "OpenTofu v$STREAM."* ]]; then
  echo "Unexpected version: $OUT (expected OpenTofu v$STREAM.x)"
  exit 1
fi
"$ENGINE" run --rm "$IMAGE" > /dev/null || { echo "Default command (tofu --help) failed"; exit 1; }

# Only built-in resources, so nothing is downloaded from a registry.
mkdir "$WORKDIR/config"
cat > "$WORKDIR/config/main.tf" <<'EOF'
terraform {
  backend "local" {
    path = "/tmp/terraform.tfstate"
  }
}

variable "name" {
  type    = string
  default = "World"
}

resource "terraform_data" "greeting" {
  input = "Hello ${var.name}"
}

output "greeting" {
  value = terraform_data.greeting.output
}
EOF
chmod -R a+rX "$WORKDIR"
"$ENGINE" volume create "$VOLUME" > /dev/null

echo "Testing init and validate..."
tofu init -input=false -no-color > /dev/null || { echo "tofu init failed"; exit 1; }
tofu validate -no-color > /dev/null || { echo "tofu validate failed"; exit 1; }

echo "Testing plan and apply..."
RC=0
tofu plan -input=false -no-color -detailed-exitcode > /dev/null || RC=$?
[ "$RC" -eq 2 ] || { echo "Expected a plan with changes (exit 2), got $RC"; exit 1; }
tofu apply -input=false -no-color -auto-approve > /dev/null || { echo "tofu apply failed"; exit 1; }
OUT="$(tofu output -raw greeting)"
[ "$OUT" = "Hello World" ] || { echo "Unexpected output: $OUT"; exit 1; }

echo "Testing the persisted state..."
tofu plan -input=false -no-color -detailed-exitcode > /dev/null || { echo "Expected no changes after apply"; exit 1; }

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

echo "All opentofu sanity tests passed successfully."
