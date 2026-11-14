#!/usr/bin/env bash
# Compares the streams in mirror/images.yaml with the upstream catalog.
#
# Renovate only refreshes the digest of an entry, so nothing else notices
# when upstream publishes a new stream or stops maintaining a mirrored one.
#
# Commands:
#   names  print the image names in the allowlist, one per line
#   plan   print what to add and what to retire, as JSON
#   apply  print the allowlist with entries added, or their digests replaced
#
# A stream is the part of a tag before the first "-" (1.27 in 1.27-builder),
# the rest is the variant. For each mirrored image, `plan` looks at the
# upstream tags that are shaped like its mirrored streams (1.27 has two
# components, 24 has one; "latest" has no shape and gets no new streams):
#
#   add     an upstream stream that is not deprecated or superseded
#           upstream and not past its end of life, and that is not mirrored
#           yet, or not with every variant the image is mirrored with
#           (upstream can publish a variant later). It gets one entry per
#           missing variant that is available.
#   retire  a mirrored tag that is gone, deprecated or superseded upstream,
#           or whose stream is past its end of life.
#   skipped an unmirrored upstream stream that is past its end of life.
#   errors  images whose catalog data is missing or unreadable. They are
#           left out, so a failed download never reads as "gone upstream".
#
# Upstream data: <catalog>/<name>.json is the catalog API's tag list for an
# image (/v1/images/<name>/tags). <eol>/<name>.json is the endoflife.date
# product (/api/v1/products/<name>/); it is optional, and images without
# one are judged by the catalog alone.
#
# Exit codes: 0 done, 2 usage or input error.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: stream-watch.sh names --images <images.yaml>
       stream-watch.sh plan  --images <images.yaml> --catalog <dir> [--eol <dir>]
       stream-watch.sh apply --images <images.yaml> --entries <json>

  --entries  JSON array of {name, tag, source}, as in the plan's `add[].entries`
EOF
  exit 2
}

[ $# -ge 1 ] || usage
COMMAND="$1"
shift
IMAGES="" CATALOG="" EOL="" ENTRIES=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --images) IMAGES="$2" ;;
    --catalog) CATALOG="$2" ;;
    --eol) EOL="$2" ;;
    --entries) ENTRIES="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$IMAGES" ] || usage
if [ ! -s "$IMAGES" ]; then
  echo "Allowlist '$IMAGES' is missing or empty" >&2
  exit 2
fi

# The entries as JSON, read from the `source:` lines the same way Renovate
# reads them. The name is the last component of the repository.
mirrored() {
  sed -nE 's|^[[:space:]]*source:[[:space:]]*([^[:space:]:@]+):([^[:space:]@]+)@(sha256:[a-f0-9]{64})[[:space:]]*$|\1 \2 \3|p' "$IMAGES" \
    | jq -Rn '[inputs | split(" ") | {repo: .[0], name: (.[0] | split("/") | last), tag: .[1], digest: .[2]}]'
}

# One object keyed by image name from the readable <dir>/<name>.json files.
load() {
  local dir="$1" name file
  while read -r name; do
    file="$dir/$name.json"
    if [ -n "$dir" ] && [ -s "$file" ] && jq -e 'type == "object"' "$file" > /dev/null 2>&1; then
      jq -c --arg name "$name" '{($name): .}' "$file"
    fi
  done | jq -sc 'add // {}'
}

case "$COMMAND" in
  names)
    mirrored | jq -r '[.[].name] | unique[]'
    ;;

  plan)
    [ -n "$CATALOG" ] || usage
    MIRRORED="$(mirrored)"
    NAMES="$(jq -r '[.[].name] | unique[]' <<< "$MIRRORED")"
    # The catalog is too large for a command line argument.
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    load "$CATALOG" <<< "$NAMES" > "$WORK/catalog.json"
    load "$EOL" <<< "$NAMES" > "$WORK/eol.json"
    jq -n --argjson mirrored "$MIRRORED" --slurpfile catalogs "$WORK/catalog.json" --slurpfile eols "$WORK/eol.json" '
      $catalogs[0] as $catalog | $eols[0] as $eol |
      def stream: split("-")[0];
      def variant: split("-")[1:] | join("-");
      def shape: if test("^[0-9]+(\\.[0-9]+)*$") then (split(".") | length) else null end;
      def by_version: sort_by(.stream | split(".") | map(tonumber? // 0));
      def usable: . != null and (.digest // "" | test("^sha256:[a-f0-9]{64}$"))
        and (.deprecated != true) and (.superseded != true)
        and ((.architectures // []) | (index("amd64") != null and index("arm64") != null));

      [ $mirrored | group_by(.name)[] | . as $entries | $entries[0].name as $name
        | ($catalog[$name].tags) as $tags
        | if ($tags | type) != "array" then {error: $name} else
            ($tags | map({key: .name, value: .}) | from_entries) as $upstream
            | ([$eol[$name].result.releases[]? | select(.isEol == true) | {key: .name, value: (.eolFrom // "")}]
                | from_entries) as $ended
            | ($entries | map(.tag | stream) | unique) as $streams
            | ($entries | map(.tag | variant) | unique) as $variants
            | ($entries | map(.tag)) as $have
            | ($streams | map(shape) | map(select(. != null)) | unique) as $shapes
            | def ended($s): if $ended | has($s) then
                  "end of life" + (if $ended[$s] != "" then " since " + $ended[$s] else "" end) + " (endoflife.date)"
                else null end;
              {
                add: [ $tags[] | select(.variant == "default" and (.deprecated != true) and (.superseded != true))
                  | .name | select((shape as $s | $s != null and ($shapes | index($s) != null)))
                  | . as $s
                  | select(ended($s) == null)
                  | [ $variants[] | ($s + (if . == "" then "" else "-" + . end)) as $tag
                      | select($have | index($tag) | not)
                      | {tag: $tag, upstream: $upstream[$tag]} ] as $wanted
                  | {
                      name: $name,
                      stream: $s,
                      entries: [ $wanted[] | select(.upstream | usable)
                        | {name: $name, tag, source: "\($entries[0].repo):\(.tag)@\(.upstream.digest)"} ],
                      unavailable: [ $wanted[] | select(.upstream | usable | not) | .tag ]
                    }
                  | select(.entries | length > 0) ],
                skipped: [ $tags[] | select(.variant == "default" and (.deprecated != true) and (.superseded != true))
                  | .name | select((shape as $s | $s != null and ($shapes | index($s) != null)))
                  | select(. as $s | $streams | index($s) | not) | . as $s
                  | select(ended($s) != null) | {name: $name, stream: $s, reason: ended($s)} ],
                retire: [ $entries[] | . as $e | $upstream[$e.tag] as $u
                  | [ (if $u == null then "no longer in the upstream catalog" else empty end),
                      (if $u != null and $u.deprecated == true then "deprecated upstream" else empty end),
                      (if $u != null and $u.superseded == true then "superseded upstream" else empty end),
                      (ended($e.tag | stream) // empty) ] as $reasons
                  | select($reasons | length > 0)
                  | {name: $name, tag: $e.tag, stream: ($e.tag | stream), reason: ($reasons | join(", "))} ]
              }
          end ]
      | {
          add: (map(.add // []) | add // [] | by_version | sort_by(.name)),
          retire: (map(.retire // []) | add // [] | sort_by(.name)),
          skipped: (map(.skipped // []) | add // [] | by_version | sort_by(.name)),
          errors: map(.error // empty)
        }'
    ;;

  apply)
    [ -n "$ENTRIES" ] || usage
    if ! jq -e 'type == "array" and all(.[]; (.name | type) == "string" and (.tag | type) == "string"
        and (.source | type) == "string" and (.source | test("^[^[:space:]@]+:[^[:space:]@]+@sha256:[a-f0-9]{64}$")))' \
        <<< "$ENTRIES" > /dev/null 2>&1; then
      echo "--entries must be a JSON array of {name, tag, source}" >&2
      exit 2
    fi
    WORK="$(mktemp)"
    trap 'rm -f "$WORK" "$WORK.next"' EXIT
    cp "$IMAGES" "$WORK"
    while IFS=$'\t' read -r name source; do
      repo="${source%%@*}"
      awk -v name="$name" -v repo="$repo" -v prefix="${repo%:*}:" -v source="$source" '
        { line[NR] = $0 }
        # The entry itself, and the last entry of the same image
        index($0, "source: " repo "@") { same = NR }
        index($0, "source: " prefix) { last = NR }
        END {
          if (!same && !last) { print "No entry of " name " to add " repo " after" > "/dev/stderr"; exit 1 }
          for (i = 1; i <= NR; i++) {
            if (i == same) { sub(/source:.*/, "source: " source, line[i]) }
            print line[i]
            if (!same && i == last) {
              print "  - name: " name
              print "    source: " source
            }
          }
        }' "$WORK" > "$WORK.next" || exit 2
      mv "$WORK.next" "$WORK"
    done < <(jq -r '.[] | [.name, .source] | @tsv' <<< "$ENTRIES")
    cat "$WORK"
    ;;

  *) usage ;;
esac
