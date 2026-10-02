#!/usr/bin/env bash
# =============================================================================
# trigger.sh — Manually trigger a HolmesGPT ScheduledHealthCheck on demand
#
# Usage:
#   ./trigger.sh                       # show available checks
#   ./trigger.sh list                  # list available checks
#   ./trigger.sh <check-name>          # run a single check
#   ./trigger.sh all                   # run every check sequentially
#
# Requirements: kubectl (with a valid kubeconfig), python3
# =============================================================================
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
NAMESPACE="${HOLMES_NAMESPACE:-holmesgpt}"
SERVICE="${HOLMES_SERVICE:-holmesgpt-holmes}"
SERVICE_PORT="${HOLMES_PORT:-80}"
WEBHOOK_URL="${HOLMES_WEBHOOK_URL:-http://holmes-remediation.holmesgpt.svc.cluster.local:8080/webhook}"
YAML_FILE="$(dirname "$0")/../components/observability/holmesgpt/config/scheduled-health-check.yaml"
POD_IMAGE="${HOLMES_CURL_IMAGE:-curlimages/curl:latest}"
# How long to wait for the trigger pod to complete (seconds)
POD_TIMEOUT="${HOLMES_POD_TIMEOUT:-30}"

# ─── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
BOLD='\033[1m'
RST='\033[0m'

log()  { echo -e "${BLU}[holmesgpt]${RST} $*"; }
ok()   { echo -e "${GRN}[✔]${RST} $*"; }
warn() { echo -e "${YLW}[!]${RST} $*"; }
err()  { echo -e "${RED}[✘]${RST} $*" >&2; }
die()  { err "$*"; exit 1; }

# ─── Helpers ─────────────────────────────────────────────────────────────────
require() {
  command -v "$1" &>/dev/null || die "'$1' is required but not found in PATH."
}

# Parse the YAML file and return a newline-separated list of check names
list_checks() {
  python3 - "$YAML_FILE" <<'EOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

docs = re.split(r'\n---', content)
names = []
for doc in docs:
    m = re.search(r'kind:\s*ScheduledHealthCheck', doc)
    if m:
        n = re.search(r'name:\s*(\S+)', doc)
        if n:
            names.append(n.group(1))

for name in names:
    print(name)
EOF
}

# Extract the query and timeout for a named check from the YAML file
get_check_payload() {
  local name="$1"
  python3 - "$YAML_FILE" "$name" <<'EOF'
import sys, re, json

path, target = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()

docs = re.split(r'\n---', content)
for doc in docs:
    if 'ScheduledHealthCheck' not in doc:
        continue
    name_m = re.search(r'name:\s*(\S+)', doc)
    if not name_m or name_m.group(1) != target:
        continue

    # Extract timeout
    timeout_m = re.search(r'timeout:\s*(\d+)', doc)
    timeout = int(timeout_m.group(1)) if timeout_m else 180

    # Extract query block (handles ">-" folded scalar)
    query_m = re.search(r'query:\s*>\-\n((?:[ \t]+.+\n?)+)', doc)
    if not query_m:
        print(json.dumps({"error": f"No query found for '{target}'"}))
        sys.exit(1)

    raw = query_m.group(1)
    # Determine indent level from first line
    indent = len(raw) - len(raw.lstrip())
    lines = [line[indent:].rstrip() for line in raw.splitlines()]
    # YAML folded block: blank line = paragraph break, otherwise join with space
    paragraphs = []
    current = []
    for line in lines:
        if line == '':
            if current:
                paragraphs.append(' '.join(current))
                current = []
        else:
            current.append(line)
    if current:
        paragraphs.append(' '.join(current))
    query = '\n'.join(paragraphs)

    print(json.dumps({"query": query, "timeout": timeout}))
    sys.exit(0)

print(json.dumps({"error": f"Check '{target}' not found"}))
sys.exit(1)
EOF
}

# Fire a single check via a temporary Kubernetes Job (works non-interactively)
fire_check() {
  local name="$1"
  local query="$2"
  local timeout="$3"
  # Job names must be <=63 chars, lowercase alphanumeric + hyphens
  local job_name
  job_name="holmes-trig-$(echo "$name" | tr '_' '-' | cut -c1-30)-$$"
  job_name="${job_name:0:63}"

  local payload
  payload=$(python3 -c "
import json, sys
payload = {
    'name': sys.argv[1],
    'query': sys.argv[2],
    'mode': 'alert',
    'timeout': int(sys.argv[3]),
    'destinations': [{
        'type': 'slack',
        'config': {
            'webhook_url': sys.argv[4]
        }
    }]
}
print(json.dumps(payload))
" "$name" "$query" "$timeout" "$WEBHOOK_URL")

  # Escape single quotes in payload for embedding in shell string
  local escaped_payload
  escaped_payload=$(printf '%s' "$payload" | sed "s/'/'\'''/g")

  log "Firing check ${BOLD}${name}${RST} (timeout: ${timeout}s)..."

  # Create a one-shot Job — avoids the --rm/attach limitation of kubectl run
  kubectl create job "$job_name" \
    --namespace="$NAMESPACE" \
    --image="$POD_IMAGE" \
    -- /bin/sh -c "
      curl -sf -X POST 'http://${SERVICE}:${SERVICE_PORT}/api/checks/execute' \
        -H 'Content-Type: application/json' \
        -d '${escaped_payload}' \
      && echo 'Holmes API call succeeded.' \
      || { echo 'Holmes API call failed'; exit 1; }
    " 1>/dev/null

  # Wait for the Job to complete or fail
  if kubectl wait job/"$job_name" \
       --namespace="$NAMESPACE" \
       --for=condition=complete \
       --timeout="${POD_TIMEOUT}s" 1>/dev/null 2>&1; then
    ok "Check '${name}' dispatched successfully."
  else
    warn "Check '${name}' did not complete within ${POD_TIMEOUT}s (the check may still be running in Holmes)."
    kubectl logs "job/${job_name}" --namespace="$NAMESPACE" 2>/dev/null | sed 's/^/    /' || true
  fi

  # Always clean up the Job
  kubectl delete job "$job_name" --namespace="$NAMESPACE" --ignore-not-found=true 1>/dev/null 2>&1 || true
}

# ─── Main ────────────────────────────────────────────────────────────────────
require kubectl
require python3

[[ -f "$YAML_FILE" ]] || die "Cannot find YAML file at: $YAML_FILE"

# Resolve argument
CMD="${1:-list}"

if [[ "$CMD" == "list" || -z "${1:-}" ]]; then
  echo ""
  echo -e "${BOLD}${CYN}Available HolmesGPT ScheduledHealthChecks${RST}"
  echo -e "${CYN}$(printf '─%.0s' {1..50})${RST}"
  mapfile -t checks < <(list_checks)
  for c in "${checks[@]}"; do
    echo -e "  ${GRN}•${RST} $c"
  done
  echo ""
  echo -e "Run: ${BOLD}./trigger.sh <check-name>${RST}  or  ${BOLD}./trigger.sh all${RST}"
  echo ""
  exit 0
fi

if [[ "$CMD" == "all" ]]; then
  mapfile -t checks < <(list_checks)
  total="${#checks[@]}"
  echo ""
  echo -e "${BOLD}${CYN}Triggering all ${total} checks sequentially...${RST}"
  echo ""
  failed=0
  for i in "${!checks[@]}"; do
    name="${checks[$i]}"
    num=$((i + 1))
    echo -e "${YLW}[${num}/${total}]${RST} ${name}"

    payload_json=$(get_check_payload "$name")
    if echo "$payload_json" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'error' not in d else 1)" 2>/dev/null; then
      query=$(echo "$payload_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['query'])")
      timeout=$(echo "$payload_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['timeout'])")
      fire_check "$name" "$query" "$timeout" || ((failed++)) || true
    else
      warn "Skipping '$name': $(echo "$payload_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown'))")"
      ((failed++)) || true
    fi
    echo ""
  done

  echo -e "${BOLD}Done.${RST} ${GRN}$((total - failed))/${total} checks dispatched successfully.${RST}"
  [[ "$failed" -eq 0 ]] || exit 1
  exit 0
fi

# Single named check
name="$CMD"
payload_json=$(get_check_payload "$name") || die "Check '$name' not found. Run './trigger.sh list' to see available checks."

if ! echo "$payload_json" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'error' not in d else 1)" 2>/dev/null; then
  die "$(echo "$payload_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown error'))")"
fi

query=$(echo "$payload_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['query'])")
timeout=$(echo "$payload_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['timeout'])")

echo ""
fire_check "$name" "$query" "$timeout"
echo ""
