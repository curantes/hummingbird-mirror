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
# The catalog decides what a stream is: every upstream tag names the stream
# it belongs to. One stream holds every tag that moves with it, so the tags
# 1, 1.100, 1.100.0 and latest of rust are all in the stream "1", and the
# step from 1.99 to 1.100 is a refresh of the tag 1, not a new stream. A
# stream is not always named after a tag ("mainline", or "3.6" while it
# holds 3.7). The tag to mirror for a stream is its floating tag. For a
# stream named after a version that is the tag with that name (1.27). For
# any other stream it is the shortest version tag in it that is not a full
# version (coredns:1 in the stream "latest"), which keeps the version in
# the tag; the tag named like the stream, or latest, is accepted too. The
# part of a tag after the first "-" is the variant (builder in
# 1.27-builder).
#
#   add     a stream with current tags upstream (not deprecated, not
#           superseded) that is not past its end of life, and of which
#           nothing is mirrored: one entry per mirrored variant, on the
#           floating tag. Also the variants that a mirrored stream lacks
#           (upstream can publish a variant later).
#   retire  a mirrored tag that is gone, deprecated or superseded upstream,
#           or whose version is past its end of life. `follow` names the
#           tag its stream continues as, if it does: move the entry there.
#   narrow  a mirrored tag that is current but is not the floating tag of
#           its stream (1.15 in a stream that will move to 1.16), with the
#           tag to `follow`. It is superseded at the next upstream release.
#   skipped an unmirrored upstream stream that is past its end of life.
#   errors  images whose catalog data is missing or unreadable. They are
#           left out, so a failed download never reads as "gone upstream".
#
# Upstream data: <catalog>/<name>.json is the catalog API's tag list for an
# image (/v1/images/<name>/tags), where every tag has `stream`, `variant`
# and `canonical` (its full version). <eol>/<name>.json is the endoflife.date
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
      def prefix: split("-")[0];
      def suffix: split("-")[1:] | join("-");
      def with($v): . + (if $v == "" then "" else "-" + $v end);
      def numeric: test("^[0-9]+(\\.[0-9]+)*$");
      def by_version: sort_by(.stream | split(".") | map(tonumber? // 0));
      def live: . != null and (.deprecated != true) and (.superseded != true);
      def usable: live and (.digest // "" | test("^sha256:[a-f0-9]{64}$"))
        and ((.architectures // []) | (index("amd64") != null and index("arm64") != null));

      [ $mirrored | group_by(.name)[] | . as $entries | $entries[0].name as $name
        | ($catalog[$name].tags) as $tags
        | if ($tags | type) != "array" or (any($tags[]; (.stream | type) == "string") | not) then {error: $name} else
            ($tags | map({key: .name, value: .}) | from_entries) as $upstream
            | ([$eol[$name].result.releases[]? | select(.isEol == true) | {key: .name, value: (.eolFrom // "")}]
                | from_entries) as $ended
            | ($entries | map(. + {stream: $upstream[.tag].stream})) as $mine
            | ($entries | map(.tag | suffix) | unique) as $variants
            | ($entries | map(.tag)) as $have
            | ($tags | map(select(.variant == "default" and live and (.stream | type) == "string"))) as $current
            | def ended($s): if $ended | has($s) then
                  "end of life" + (if $ended[$s] != "" then " since " + $ended[$s] else "" end) + " (endoflife.date)"
                else null end;
              # The tags that float with a stream, without a variant, the
              # preferred one first. The shortest version tag of a stream
              # that is named after a version (1 in go 1.27) is left out:
              # it moves on to the next stream.
              def floats($s): ($current | map(select(.stream == $s))) as $in
                | any($in[]; .name == $s) as $named
                | if $named and ($s | numeric) then [$s] else
                    [ ([$in[] | select(.name != .canonical) | .name | select(numeric)]
                        | sort_by(split(".") | length) | first // empty),
                      (if $named then $s else $in[] | .name | select(. == "latest") end) ]
                  end;
              def floating($s): floats($s) | first;
              # The tag an entry should be on, if that is another one
              def follow: . as $e
                | (if $e.stream == null or (floats($e.stream) | index($e.tag | prefix) != null) then null
                   else floating($e.stream) end) as $f
                | if $f == null then null else ($f | with($e.tag | suffix)) end
                | if . != null and . != $e.tag and ($upstream[.] | usable) then . else null end;
              {
                add: [ $current | map(.stream) | unique[] | . as $s
                  | [$mine[] | select(.stream == $s)] as $in
                  | (if ($in | length) > 0 then $in | map(.tag | select(suffix == ""))
                     else [floating($s) // empty] end)[] as $base
                  | select(ended($base | prefix) == null)
                  | [ $variants[] as $v | ($base | with($v)) as $tag
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
                skipped: [ $current | map(.stream) | unique[] | . as $s
                  | select(any($mine[]; .stream == $s) | not)
                  | (floating($s) // empty) | ended(prefix) as $reason
                  | select($reason != null) | {name: $name, stream: $s, reason: $reason} ],
                retire: [ $mine[] | . as $e | $upstream[$e.tag] as $u
                  | (if $u != null and $u.superseded == true then $e | follow else null end) as $follow
                  | [ (if $u == null then "no longer in the upstream catalog" else empty end),
                      (if $u != null and $u.deprecated == true then "deprecated upstream" else empty end),
                      (if $u != null and $u.superseded == true then "superseded upstream" else empty end),
                      (if $follow != null then "its stream \($e.stream) continues as \($follow)" else empty end),
                      (ended($e.tag | prefix) // empty) ] as $reasons
                  | select($reasons | length > 0)
                  | {name: $name, tag: $e.tag, stream: ($e.stream // ($e.tag | prefix)),
                     reason: ($reasons | join(", ")), follow: $follow} ],
                narrow: [ $mine[] | . as $e | select($upstream[$e.tag] | live) | ($e | follow) as $follow
                  | select($follow != null)
                  | {name: $name, tag: $e.tag, stream: $e.stream, follow: $follow} ]
              }
          end ]
      | {
          add: (map(.add // []) | add // [] | by_version | sort_by(.name)),
          retire: (map(.retire // []) | add // [] | sort_by(.name)),
          narrow: (map(.narrow // []) | add // [] | sort_by(.name)),
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
