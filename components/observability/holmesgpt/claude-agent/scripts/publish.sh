#!/bin/bash
# Main container: guards the change Claude made, then pushes a branch and opens the PR.
# Holds the GitHub App token, never runs Claude.
set -euo pipefail
source /etc/claude-agent/common.sh
trap 'notify_on_failure publish' EXIT
cd "$WORK"

STATUS=$(jq -r .status "$REPORT"); TITLE=$(jq -r .title "$REPORT"); SUMMARY=$(jq -r .summary "$REPORT")
echo "status=$STATUS title=$TITLE"

git config --global --add safe.directory "$WORK"
git add -A
if git diff --cached --quiet; then
  [ "$STATUS" = "healthy" ] || register "$TITLE" "$SUMMARY"
  trap - EXIT; exit 0
fi

# ── guards ──────────────────────────────────────────────────────────────────
reject() {
  register "$TITLE" "$SUMMARY

⚠️ No PR opened: $1"
  trap - EXIT; exit 0
}
FORBIDDEN=$(git diff --cached --name-only \
  | grep -E '^(cluster/flux-system/|\.github/|\.claude/|components/storage/longhorn/config/restore/|components/observability/holmesgpt/claude-agent/)' || true)
[ -z "$FORBIDDEN" ] || reject "change touches protected paths: $FORBIDDEN"
TOKEN=$(cat "$GITHUB_TOKEN_FILE")
if git diff --cached | grep -F "$TOKEN" > /dev/null; then reject "diff contains a credential"; fi
kubectl kustomize components > /dev/null && kubectl kustomize services > /dev/null || reject "kustomize validation failed"
AGENT_TASK=$(printenv AGENT_TASK || echo health)

# ── branch, push, PR ────────────────────────────────────────────────────────
# Token is read from the file on every use, so a refresh mid-run is picked up
git config --global credential.helper '!f() { echo username=x-access-token; echo "password=$(cat "$GITHUB_TOKEN_FILE")"; }; f'
git config --global user.name "claude-agent"
git config --global user.email "claude-agent@users.noreply.github.com"

BRANCH="claude/$AGENT_TASK-$(date -u +%Y%m%d-%H%M)"
git switch --quiet -c "$BRANCH"
git commit --quiet -F - <<EOF
$TITLE

Opened by the claude-agent CronJob ($AGENT_TASK run).

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
git push --quiet origin "$BRANCH"

PR=$(jq -n --arg t "$TITLE" --arg s "$SUMMARY" --arg h "$BRANCH" --arg b "$GITHUB_BRANCH" \
  '{title: $t, head: $h, base: $b,
    body: ($s + "\n\n---\n_Opened by the claude-agent CronJob. Merge or reject from ntfy._\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)")}' \
  | curl -fsSL -X POST -H "Authorization: Bearer $(cat "$GITHUB_TOKEN_FILE")" -H "Accept: application/vnd.github+json" \
      --data-binary @- "https://api.github.com/repos/$GITHUB_REPO/pulls")
register "$TITLE" "$SUMMARY" "$(echo "$PR" | jq -r .number)" "$(echo "$PR" | jq -r .html_url)"
trap - EXIT
