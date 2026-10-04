# Sourced by investigate.sh and publish.sh.
# Flux postBuild substitution rewrites dollar-brace variables: only use $var and $(...) here.

REMEDIATION=http://holmes-remediation.holmesgpt.svc.cluster.local:8080
WORK=/work/repo
OUT=/work/out
REPORT=$OUT/report.json

# Hand the result to holmes-remediation; without a PR number it sends a plain ntfy alert
register() { # title summary [pr_number pr_url]
  local n="" u=""
  if [ $# -ge 4 ]; then n=$3; u=$4; fi
  jq -n --arg t "$1" --arg s "$2" --arg n "$n" --arg u "$u" \
    '{title: $t, summary: $s, pr_number: ($n | tonumber? // null), pr_url: (if $u == "" then null else $u end)}' \
    | curl -fsS -X POST -H 'Content-Type: application/json' --data-binary @- "$REMEDIATION/register"
  echo
}

notify_on_failure() {
  local rc=$?
  [ $rc -eq 0 ] || register "claude-agent $1 failed" "Exit code $rc, see: kubectl -n holmesgpt logs job/<name> -c $1"
}
