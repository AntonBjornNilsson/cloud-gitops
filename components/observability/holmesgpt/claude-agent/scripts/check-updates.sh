#!/bin/bash
# Lists newer chart and image versions for everything Flux deploys from this repo.
# Run from the repo root; prints a JSON array. Deterministic (no LLM): the updates
# agent picks from this list instead of looking versions up itself.
# Flux postBuild substitution rewrites dollar-brace variables: only use $var and $(...) here.
set -uo pipefail
MAX=8
TMP=$(mktemp -d)

# Flux Kustomizations reconciled from this repo (recursively, config ones included)
flux_paths() {
  yq -N 'select(.apiVersion == "kustomize.toolkit.fluxcd.io/v1" and .kind == "Kustomization"
               and .spec.sourceRef.name == "flux-system") | .spec.path'
}

# Render only what is enabled: services + every component path Flux applies
render() {
  local queue seen="" p out
  kubectl kustomize services
  queue=$(kubectl kustomize components | flux_paths)
  while [ -n "$queue" ]; do
    p=$(printf '%s\n' "$queue" | head -1); queue=$(printf '%s\n' "$queue" | tail -n +2)
    case " $seen " in *" $p "*) continue ;; esac
    seen="$seen $p"
    out=$(kubectl kustomize "$p") || { echo "render failed: $p" >&2; continue; }
    printf -- '---\n%s\n' "$out"
    queue=$(printf '%s\n%s\n' "$queue" "$(printf '%s\n' "$out" | flux_paths)" | sed '/^$/d')
  done
}

# Loops below read their list from fd 3: helm/crane would otherwise consume stdin.

# stdin: candidate tags; prints up to MAX tags newer than $1 with the same shape, newest first
# (a leading "v" is ignored when comparing and kept in the output as in $1)
newer() {
  local cur v="" shape
  cur=$(sed 's/^v//' <<<"$1"); [ "$cur" = "$1" ] || v=v
  shape=$(printf '%s' "$cur" | sed -E 's/[].^$*+?()|{}\\[]/\\&/g; s/[0-9]+/[0-9]+/g')
  { sed 's/^v//' | grep -E "^$shape\$"; echo "$cur"; } | sort -uV | awk -v c="$cur" 'f { print } $0 == c { f = 1 }' \
    | tail -n "$MAX" | tac | sed "s/^/$v/" | jq -R . | jq -sc .
}

render > "$TMP/rendered.yaml" 2> "$TMP/render.err"
yq -o=json -I=0 '.' "$TMP/rendered.yaml" | jq -sc '[.[] | select(. != null)]' > "$TMP/docs.json"

# ── charts ─────────────────────────────────────────────────────────────────
jq -c '
  (map(select(.kind == "HelmRepository") | {key: "\(.metadata.namespace)/\(.metadata.name)", value: {url: .spec.url, oci: (.spec.type == "oci")}}) | from_entries) as $repos
  | (map(select(.kind == "OCIRepository") | {key: "\(.metadata.namespace)/\(.metadata.name)", value: {url: .spec.url, tag: .spec.ref.tag}}) | from_entries) as $ocis
  | .[] | select(.kind == "HelmRelease") | .metadata.namespace as $ns
  | if .spec.chartRef then
      $ocis["\(.spec.chartRef.namespace // $ns)/\(.spec.chartRef.name)"] as $o
      | {release: "\($ns)/\(.metadata.name)", chart: ($o.url | sub("^oci://"; "")), current: ($o.tag // ""), type: "oci"}
    else
      .spec.chart.spec as $c | $repos["\($c.sourceRef.namespace // $ns)/\($c.sourceRef.name)"] as $r
      | {release: "\($ns)/\(.metadata.name)", chart: $c.chart, current: ($c.version // ""),
         repo: $r.url, type: (if $r.oci then "oci" else "http" end)}
    end' "$TMP/docs.json" > "$TMP/charts.jsonl"

while read -r c <&3; do
  rel=$(jq -r .release <<<"$c"); chart=$(jq -r .chart <<<"$c"); cur=$(jq -r .current <<<"$c")
  type=$(jq -r .type <<<"$c"); repo=$(jq -r '.repo // ""' <<<"$c")
  if [ -z "$cur" ] || ! grep -qE '^v?[0-9]+\.[0-9]+' <<<"$cur"; then
    jq -c '. + {note: "not pinned to a version"}' <<<"$c"; continue
  fi
  if [ "$type" = "oci" ]; then
    ref=$chart; [ -n "$repo" ] && ref="$(sed 's|^oci://||' <<<"$repo")/$chart"
    tags=$(crane ls "$ref" 2>> "$TMP/lookup.err")
  else
    name=$(md5sum <<<"$repo" | cut -c1-12)
    helm repo add --force-update "$name" "$repo" > /dev/null 2>> "$TMP/lookup.err"
    tags=$(helm search repo "$name/$chart" --versions -o json 2>> "$TMP/lookup.err" | jq -r '.[].version')
  fi
  [ -n "$tags" ] || { jq -c '. + {note: "version lookup failed"}' <<<"$c"; continue; }
  n=$(newer "$cur" <<<"$tags")
  [ "$n" = "[]" ] || jq -c --argjson n "$n" '. + {kind: "chart", newer: $n}' <<<"$c"
done 3< "$TMP/charts.jsonl" > "$TMP/out.jsonl"

# ── images in raw manifests (chart-managed images move with the chart) ──────
jq -c '
  [ .[] | select(.kind | IN("Deployment", "StatefulSet", "DaemonSet", "CronJob", "Job", "Pod"))
    | "\(.metadata.namespace // "")/\(.kind)/\(.metadata.name)" as $w
    | (.. | objects | select(has("image") and (.image | type) == "string") | .image) as $img
    | {img: $img, w: $w} ]
  | group_by(.img)[] | {image: .[0].img, used_by: (map(.w) | unique)}' "$TMP/docs.json" > "$TMP/images.jsonl"

while read -r i <&3; do
  ref=$(jq -r '.image | split("@")[0]' <<<"$i")
  case "$ref" in *'$'*) continue ;; esac
  last=$(basename "$ref")
  if [[ "$last" == *:* ]]; then repo=$(sed -E 's/:[^:/]+$//' <<<"$ref"); tag=$(sed -E 's/.*://' <<<"$last")
  else repo=$ref; tag=latest; fi
  if ! grep -qE '[0-9]' <<<"$tag"; then
    jq -c --arg r "$repo" --arg t "$tag" '{kind: "image", image: $r, current: $t, used_by, note: "unversioned tag, cannot be bumped"}' <<<"$i"
    continue
  fi
  tags=$(crane ls "$repo" 2>> "$TMP/lookup.err") || { jq -c --arg r "$repo" --arg t "$tag" '{kind: "image", image: $r, current: $t, used_by, note: "tag lookup failed"}' <<<"$i"; continue; }
  n=$(newer "$tag" <<<"$tags")
  [ "$n" = "[]" ] || jq -c --arg r "$repo" --arg t "$tag" --argjson n "$n" '{kind: "image", image: $r, current: $t, used_by, newer: $n}' <<<"$i"
done 3< "$TMP/images.jsonl" >> "$TMP/out.jsonl"

jq -s . "$TMP/out.jsonl"
if [ -s "$TMP/render.err" ] || [ -s "$TMP/lookup.err" ]; then
  echo "check-updates warnings:" >&2; sort -u "$TMP/render.err" "$TMP/lookup.err" | head -20 >&2
fi
rm -rf "$TMP"
