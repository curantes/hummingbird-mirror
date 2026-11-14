#!/usr/bin/env bash
# Tests for stream-watch.sh and check-readme-tags.sh. Run from anywhere;
# needs bash and jq. The upstream data is made up here, not downloaded.
#
# The expected Markdown has backticks in single quotes, on purpose.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$HERE/../stream-watch.sh"
README_CHECK="$HERE/../check-readme-tags.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
CASES=0

# check <description> <command...>: the command must succeed
check() {
  local desc="$1"
  shift
  CASES=$((CASES + 1))
  if "$@" > "$WORK/check.out" 2>&1; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc"
    sed 's/^/       /' "$WORK/check.out"
    FAILED=$((FAILED + 1))
  fi
}
# exits <description> <expected exit code> <command...>; output in last.out
exits() {
  local desc="$1" want="$2" got
  shift 2
  CASES=$((CASES + 1))
  "$@" > "$WORK/last.out" 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc: exit code $got, expected $want"
    sed 's/^/       /' "$WORK/last.out"
    FAILED=$((FAILED + 1))
  fi
}
plan_has() { jq -e "$@" "$WORK/plan.json" > /dev/null; }
has() { grep -qF -- "$2" "$1"; }

digest() { printf 'sha256:%064d' "$1"; }
# tag <stream> <name> <variant> <digest number> [deprecated] [superseded] [architectures]
# CANONICAL=<version> tag ... sets the full version the tag stands for.
tag() {
  jq -nc --arg stream "$1" --arg name "$2" --arg variant "$3" --arg digest "$(digest "$4")" \
    --argjson deprecated "${5:-false}" --argjson superseded "${6:-false}" \
    --argjson archs "${7:-[\"amd64\",\"arm64\"]}" --arg canonical "${CANONICAL:-}" \
    '{name: $name, variant: $variant, digest: $digest, stream: $stream, deprecated: $deprecated,
      superseded: $superseded, architectures: $archs}
      + (if $canonical != "" then {canonical: $canonical} else {} end)'
}
catalog() { jq -sc '{tags: .}' > "$WORK/catalog/$1.json"; }

REG="registry.example/hi"
mkdir -p "$WORK/catalog" "$WORK/eol"
cat > "$WORK/images.yaml" <<EOF
# A comment that must survive
images:
  # --- Languages ---
  - name: go
    source: $REG/go:1.26@$(digest 126)
  - name: go
    source: $REG/go:1.26-builder@$(digest 1260)
  - name: go
    source: $REG/go:1.27@$(digest 127)
  - name: go
    source: $REG/go:1.27-builder@$(digest 1270)

  - name: nodejs
    source: $REG/nodejs:24@$(digest 24)

  - name: rust
    source: $REG/rust:1.99@$(digest 199)
  - name: rust
    source: $REG/rust:1.99-builder@$(digest 1990)

  - name: nginx
    source: $REG/nginx:1.30@$(digest 130)

  - name: etcd
    source: $REG/etcd:3@$(digest 37)

  - name: coredns
    source: $REG/coredns:1@$(digest 115)

  # --- Operating System ---
  - name: static
    source: $REG/static:latest@$(digest 1)

  - name: gone
    source: $REG/gone:1.0@$(digest 10)

  - name: offline
    source: $REG/offline:2.0@$(digest 20)

  - name: unnamed
    source: $REG/unnamed:1.0@$(digest 40)
EOF

# go: 1.28 is new, 1.26 is deprecated, 1.25 is unmirrored and deprecated.
# The stream 1.28 also holds the tags 1, 1.28.0 and latest.
{
  tag 1.28 1.28 default 128
  tag 1.28 1.28-builder builder 1280
  tag 1.28 1.28-fips fips 1281
  tag 1.28 1.28.0 default 128
  tag 1.28 1 default 128
  tag 1.28 latest default 128
  tag 1.27 1.27 default 127
  tag 1.27 1.27-builder builder 1270
  tag 1.27 1.27.4 default 127
  tag 1.26 1.26 default 126 true
  tag 1.26 1.26-builder builder 1260 true
  tag 1.25 1.25 default 125 true
} | catalog go
# nodejs: 22 is past its end of life, 26 is new, 25 is single-arch
{
  tag 26 26 default 26
  tag 26 26.13 default 26
  tag 25 25 default 25 false false '["amd64"]'
  tag 24 24 default 24
  tag 24 24.22 default 24
  tag 22 22 default 22
} | catalog nodejs
jq -n '{result: {releases: [{name: "26", isEol: false}, {name: "22", isEol: true, eolFrom: "2026-04-30"}]}}' \
  > "$WORK/eol/nodejs.json"
# rust: one stream, "1". Upstream is moving from 1.99 to 1.100; the new
# builder is not the current one yet, and the old builder still is.
{
  tag 1 1 default 1100
  tag 1 1-builder builder 1990
  tag 1 latest default 1100
  tag 1 1.100 default 1100
  CANONICAL=1.100.0 tag 1 1.100.0 default 1100
  tag 1 1.100-builder builder 11000 false true
  tag 1 1.99 default 199 false true
  tag 1 1.99-builder builder 1990
} | catalog rust
# nginx: the streams are not named after tags. "mainline" floats as 1 and
# 1.30; "1.28" has a full version only, so nothing to follow.
{
  tag mainline 1 default 130
  tag mainline 1.30 default 130
  CANONICAL=1.30.6 tag mainline 1.30.6 default 130
  tag mainline latest default 130
  CANONICAL=1.30.0 tag 1.28 1.30.0 default 1300
} | catalog nginx
# etcd: the stream is still called 3.6 but holds 3.7
{
  tag 3.6 3 default 37
  tag 3.6 3.7 default 37
  tag 3.6 latest default 37
} | catalog etcd
# coredns: the stream is called latest; the entry follows it as 1
{
  tag latest latest default 115
  tag latest 1 default 115
  tag latest 1.15 default 115
} | catalog coredns
tag latest latest default 1 | catalog static
tag 2.0 2.0 default 30 | catalog gone
echo 'not json' > "$WORK/catalog/offline.json"
# A catalog answer without streams cannot be judged
jq -nc --arg d "$(digest 40)" '{tags: [{name: "1.0", variant: "default", digest: $d, architectures: ["amd64", "arm64"]}]}' \
  > "$WORK/catalog/unnamed.json"
jq -n '{result: {releases: [{name: "1.0", isEol: true, eolFrom: null}]}}' > "$WORK/eol/gone.json"

# --- names ---
"$WATCH" names --images "$WORK/images.yaml" > "$WORK/names"
check "names lists every image once" test "$(tr '\n' ' ' < "$WORK/names")" = "coredns etcd go gone nginx nodejs offline rust static unnamed "

# --- plan ---
"$WATCH" plan --images "$WORK/images.yaml" --catalog "$WORK/catalog" --eol "$WORK/eol" > "$WORK/plan.json"
check "a new stream is added with the mirrored variants only" plan_has \
  '.add | map(select(.name == "go")) | length == 1 and .[0].stream == "1.28"
    and ([.[0].entries[].tag] == ["1.28", "1.28-builder"]) and .[0].unavailable == []'
check "an added entry is pinned to the upstream digest" plan_has \
  --arg s "$REG/go:1.28-builder@$(digest 1280)" '.add[] | select(.name == "go") | .entries[1].source == $s'
check "deprecated streams and the other tags of a stream are not new streams" plan_has \
  '[.add[] | select(.name == "go") | .stream] == ["1.28"]'
check "a deprecated mirrored stream is to be retired" plan_has \
  '[.retire[] | select(.name == "go") | "\(.tag): \(.reason)"]
    == ["1.26: deprecated upstream", "1.26-builder: deprecated upstream"]'
check "a stream past its end of life is skipped, not added" plan_has \
  '(.add | map(select(.name == "nodejs" and .stream == "22")) | length == 0)
    and (.skipped == [{name: "nodejs", stream: "22", reason: "end of life since 2026-04-30 (endoflife.date)"}])'
check "a stream without amd64 and arm64 is not added" plan_has \
  '[.add[] | select(.name == "nodejs") | .stream] == ["26"]'
check "a new version in a mirrored stream is not a new stream" plan_has \
  '[.add[] | select(.name == "rust")] == []'
check "a superseded tag names the tag its stream continues as" plan_has \
  '[.retire[] | select(.name == "rust")] == [{name: "rust", tag: "1.99", stream: "1",
    reason: "superseded upstream, its stream 1 continues as 1", follow: "1"}]'
check "a current tag that is not the floating tag of its stream is narrow" plan_has \
  '[.narrow[] | select(.name == "rust")] == [{name: "rust", tag: "1.99-builder", stream: "1", follow: "1-builder"}]'
check "a stream that is not named after a tag floats as its shortest version tag" plan_has \
  '[.narrow[] | select(.name == "nginx")] == [{name: "nginx", tag: "1.30", stream: "mainline", follow: "1"}]'
check "a stream with a full version only is not proposed" plan_has \
  '[.add[], .skipped[] | select(.name == "nginx")] == []'
check "an entry on the floating tag of a renamed stream is left alone" plan_has \
  '[.add[], .retire[], .narrow[], .skipped[] | select(.name == "etcd")] == []'
check "a version tag that floats with a stream called latest is left alone" plan_has \
  '[.add[], .retire[], .narrow[], .skipped[] | select(.name == "coredns")] == []'
check "an image on latest gets no new streams and is not retired" plan_has \
  '([.add[], .retire[] | select(.name == "static")] | length) == 0'
check "a tag that is gone upstream and past its end of life names both reasons" plan_has \
  '[.retire[] | select(.name == "gone") | .reason] == ["no longer in the upstream catalog, end of life (endoflife.date)"]'
check "an image without readable catalog data is an error, not a retirement" plan_has \
  '.errors == ["offline", "unnamed"] and ([.add[], .retire[] | select(.name == "offline" or .name == "unnamed")] | length) == 0'
check "added streams are in version order" plan_has '[.add[] | "\(.name) \(.stream)"] == ["go 1.28", "gone 2.0", "nodejs 26"]'

"$WATCH" plan --images "$WORK/images.yaml" --catalog "$WORK/catalog" > "$WORK/plan.json"
check "without end of life data the catalog decides" plan_has \
  '([.add[] | select(.name == "nodejs") | .stream] == ["22", "26"]) and .skipped == []'

# A mirrored stream that lacks a variant gets it, and a new stream is added
# without a variant that upstream doesn't have for both architectures yet.
sed 'N;/go:1.27-builder@/d;P;D' "$WORK/images.yaml" > "$WORK/partial.yaml"
{
  tag 1.28 1.28 default 128
  tag 1.28 1.28-builder builder 1280 false false '["amd64"]'
  tag 1.27 1.27 default 127
  tag 1.27 1.27-builder builder 1270
  tag 1.26 1.26 default 126
  tag 1.26 1.26-builder builder 1260
} | catalog go
"$WATCH" plan --images "$WORK/partial.yaml" --catalog "$WORK/catalog" > "$WORK/plan.json"
check "a missing variant of a mirrored stream is added" plan_has \
  --arg s "$REG/go:1.27-builder@$(digest 1270)" \
  '.add[] | select(.name == "go" and .stream == "1.27") | [.entries[].source] == [$s] and .unavailable == []'
check "a variant that is not usable upstream yet is left out and named" plan_has \
  '.add[] | select(.name == "go" and .stream == "1.28") | [.entries[].tag] == ["1.28"] and .unavailable == ["1.28-builder"]'

# --- apply ---
ENTRIES="$(jq -nc --arg a "$REG/go:1.28@$(digest 128)" --arg b "$REG/go:1.28-builder@$(digest 1280)" \
  '[{name: "go", tag: "1.28", source: $a}, {name: "go", tag: "1.28-builder", source: $b}]')"
"$WATCH" apply --images "$WORK/images.yaml" --entries "$ENTRIES" > "$WORK/applied.yaml"
check "apply adds the entries after the last entry of the image" test \
  "$(grep -n 'source:' "$WORK/applied.yaml" | grep -A2 'go:1.27-builder@' | sed -E 's|.*/hi/([^@]+)@.*|\1|' | tr '\n' ' ')" \
  = "go:1.27-builder go:1.28 go:1.28-builder "
check "apply keeps every other line" test \
  "$(diff "$WORK/images.yaml" "$WORK/applied.yaml" | grep -c '^<')" -eq 0
check "apply adds a name line for each entry" test "$(grep -c '^  - name: go$' "$WORK/applied.yaml")" -eq 6

ENTRIES="$(jq -nc --arg a "$REG/go:1.28@$(digest 999)" '[{name: "go", tag: "1.28", source: $a}]')"
"$WATCH" apply --images "$WORK/applied.yaml" --entries "$ENTRIES" > "$WORK/refreshed.yaml"
check "apply replaces the digest of an entry that exists" has "$WORK/refreshed.yaml" "source: $REG/go:1.28@$(digest 999)"
check "apply does not add an existing entry again" test "$(grep -c 'go:1.28@' "$WORK/refreshed.yaml")" -eq 1
check "a refresh leaves the entry of a longer tag alone" has "$WORK/refreshed.yaml" "source: $REG/go:1.28-builder@$(digest 1280)"

ENTRIES="$(jq -nc --arg a "$REG/ruby:3.4@$(digest 34)" '[{name: "ruby", tag: "3.4", source: $a}]')"
exits "apply refuses an image without any entry" 2 "$WATCH" apply --images "$WORK/images.yaml" --entries "$ENTRIES"
exits "apply refuses entries without a digest" 2 "$WATCH" apply --images "$WORK/images.yaml" \
  --entries '[{"name":"go","tag":"1.28","source":"registry.example/hi/go:1.28"}]'
exits "plan needs a catalog directory" 2 "$WATCH" plan --images "$WORK/images.yaml"
exits "a missing allowlist is an input error" 2 "$WATCH" names --images "$WORK/none.yaml"

# --- check-readme-tags.sh ---
cat > "$WORK/README.md" <<'EOF'
# Mirror

| Image | Tags |
|---|---|
| `not-a-mirror-table` | `9.9` |

## Available Images

| Image | Tags | Contents | User |
|---|---|---|---|
| [`go`](https://example.com/go) | `1.26`–`1.27` | Go with `gcc` | root |
| `go` | `1.26-builder`, `1.27-builder` | the above plus dnf | root |
| `nodejs` | `24` | Node.js | 65532 |
| `rust` | `1.99`, `1.99-builder` | Rust | root |
| `nginx` | `1.30` | | |
| `etcd` | `3` | | |
| `coredns` | `1` | | |
| `static` | `latest` | no shell | 65532 |
| `gone` | `1.0` | | |
| `offline` | `2.0` | | |
| `unnamed` | `1.0` | | |

## Usage

| `go` | `0.1` | a table outside the section | |
EOF
exits "a README that lists every tag passes" 0 "$README_CHECK" "$WORK/README.md" "$WORK/images.yaml"

"$WATCH" apply --images "$WORK/images.yaml" \
  --entries "$(jq -nc --arg a "$REG/go:1.28@$(digest 128)" '[{name: "go", tag: "1.28", source: $a}]')" > "$WORK/more.yaml"
exits "an entry that the README lacks fails" 1 "$README_CHECK" "$WORK/README.md" "$WORK/more.yaml"
check "the missing tag is named" has "$WORK/last.out" "  go:1.28"

sed 's/| `nodejs` | `24` |/| `nodejs` | `24`, `26` |/' "$WORK/README.md" > "$WORK/extra.md"
exits "a README tag without an entry fails" 1 "$README_CHECK" "$WORK/extra.md" "$WORK/images.yaml"
check "the extra tag is named" has "$WORK/last.out" "  nodejs:26"

sed 's/| `static` | `latest` |/| `static` | `latest`, `latest` |/' "$WORK/README.md" > "$WORK/twice.md"
exits "a tag listed twice fails" 1 "$README_CHECK" "$WORK/twice.md" "$WORK/images.yaml"

sed 's/`1.26`–`1.27`/`1.27`–`1.26-builder`/' "$WORK/README.md" > "$WORK/range.md"
exits "a range that cannot be expanded is an input error" 2 "$README_CHECK" "$WORK/range.md" "$WORK/images.yaml"
exits "a missing README is an input error" 2 "$README_CHECK" "$WORK/none.md" "$WORK/images.yaml"

echo
if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED check(s) failed in $CASES cases"
  exit 1
fi
echo "All $CASES cases passed"
