#!/usr/bin/env bash
# Tests for verify-upstream.sh with a stub cosign that accepts one key.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../verify-upstream.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The stub succeeds when the --key file contains $GOOD_KEY and logs its
# arguments, so the tests can check which cosign command ran.
mkdir -p "$WORK/bin" "$WORK/one" "$WORK/two" "$WORK/none"
cat > "$WORK/bin/cosign" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$COSIGN_LOG"
key=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--key" ]; then key="$2"; fi
  shift
done
if grep -q "$GOOD_KEY" "$key"; then
  echo "verified payload"
  exit 0
fi
echo "Error: no matching signatures" >&2
exit 1
STUB
chmod +x "$WORK/bin/cosign"
echo "old-key" > "$WORK/one/a-old.pub"
echo "old-key" > "$WORK/two/a-old.pub"
echo "new-key" > "$WORK/two/b-new.pub"
export PATH="$WORK/bin:$PATH" COSIGN_LOG="$WORK/cosign.log"

FAILED=0
CASES=0
# run <description> <expected exit code> <good key> <arguments...>
run() {
  local desc="$1" want="$2" got
  export GOOD_KEY="$3"
  shift 3
  CASES=$((CASES + 1))
  DESC="$desc"
  : > "$COSIGN_LOG"
  "$SCRIPT" "$@" > "$WORK/out" 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc: exit code $got, expected $want"
    sed 's/^/       /' "$WORK/out"
    FAILED=$((FAILED + 1))
  fi
}
has() { # has <file> <text>
  if ! grep -qF -- "$2" "$1"; then
    echo "FAIL - $DESC: $(basename "$1") lacks '$2'"
    FAILED=$((FAILED + 1))
  fi
}

run "signature verifies with the only key" 0 old-key signature example.test/img@sha256:abc "$WORK/one"
has "$COSIGN_LOG" "verify --key $WORK/one/a-old.pub --insecure-ignore-tlog example.test/img@sha256:abc"

run "sbom uses verify-attestation with the spdx type" 0 old-key sbom example.test/img@sha256:abc "$WORK/one"
has "$COSIGN_LOG" "verify-attestation --type spdx --key"

run "a second key is enough after a rotation" 0 new-key signature example.test/img@sha256:abc "$WORK/two"
has "$WORK/out" "b-new.pub"

run "the old key still verifies older images" 0 old-key signature example.test/img@sha256:abc "$WORK/two"
has "$WORK/out" "a-old.pub"

run "fails when no key verifies and shows why" 1 other-key signature example.test/img@sha256:abc "$WORK/two"
has "$WORK/out" "verifies with none of"
has "$WORK/out" "no matching signatures"

run "an empty keys directory is an error" 2 old-key signature example.test/img@sha256:abc "$WORK/none"
run "an unknown check is a usage error" 2 old-key provenance example.test/img@sha256:abc "$WORK/one"
run "a missing reference is a usage error" 2 old-key signature

echo
if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED check(s) failed in $CASES cases"
  exit 1
fi
echo "All $CASES cases passed"
