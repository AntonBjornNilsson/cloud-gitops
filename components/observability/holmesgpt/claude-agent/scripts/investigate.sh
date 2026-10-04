#!/bin/bash
# Init container: Claude investigates the cluster and edits a clone of the repo.
# Has the Claude subscription token and a read-only kubeconfig, but no GitHub credentials.
set -euo pipefail
source /etc/claude-agent/common.sh
trap 'notify_on_failure investigate' EXIT
mkdir -p "$HOME/.kube" "$OUT"

# kubeconfig with the same context name the repo skill uses
SA=/var/run/secrets/kubernetes.io/serviceaccount
cat > "$HOME/.kube/config" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: in-cluster
    cluster:
      server: https://kubernetes.default.svc
      certificate-authority: $SA/ca.crt
users:
  - name: claude-agent
    user:
      tokenFile: $SA/token
contexts:
  - name: oidc-user
    context:
      cluster: in-cluster
      user: claude-agent
current-context: oidc-user
EOF

# Public repo: clone and list PRs without credentials
git clone --quiet --depth 20 --branch "$GITHUB_BRANCH" "https://github.com/$GITHUB_REPO.git" "$WORK"
cd "$WORK"
OPEN_PRS=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/pulls?state=open&per_page=50" \
  | jq -r '[.[] | select(.head.ref | startswith("claude/")) | "- #\(.number) \(.title)"] | if length == 0 then "(none)" else join("\n") end')

PROMPT="$(cat /etc/claude-agent/prompt.md)

Open PRs from earlier runs:
$OPEN_PRS"

claude -p "$PROMPT" \
  --model "$CLAUDE_MODEL" \
  --max-turns "$CLAUDE_MAX_TURNS" \
  --add-dir "$OUT" \
  --allowedTools Read Grep Glob Edit Write \
    "Bash(kubectl get:*)" "Bash(kubectl describe:*)" "Bash(kubectl logs:*)" "Bash(kubectl top:*)" "Bash(kubectl events:*)" \
    "Bash(kubectl --context=oidc-user get:*)" "Bash(kubectl --context=oidc-user describe:*)" \
    "Bash(kubectl --context=oidc-user logs:*)" "Bash(kubectl --context=oidc-user top:*)" "Bash(kubectl --context=oidc-user events:*)" \
    "Bash(kubectl kustomize:*)" "Bash(flux get:*)" "Bash(flux --context=oidc-user get:*)" \
    "Bash(git status:*)" "Bash(git diff:*)" "Bash(git log:*)" "Bash(jq:*)" \
  --disallowedTools WebFetch WebSearch \
  | tee "$OUT/claude.log"

jq -e '.status and .title and .summary' "$REPORT" > /dev/null || { echo "missing or invalid $REPORT"; exit 1; }
