#!/bin/bash
# Exchanges the GitHub App private key for an installation token (valid 1h) and stores it in
# the github-app-token Secret, used by claude-agent and holmes-remediation.
# Flux postBuild substitution rewrites dollar-brace variables: only use $var and $(...) here.
set -euo pipefail

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

NOW=$(date +%s)
HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((NOW - 60)) $((NOW + 540)) "$(cat /etc/github-app/app-id)" | b64url)
SIGNATURE=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | openssl dgst -sha256 -sign /etc/github-app/private-key | b64url)

# Scope the token to this repo with only the permissions the agent needs
jq -n --arg repo "$(basename "$GITHUB_REPO")" \
  '{repositories: [$repo], permissions: {contents: "write", pull_requests: "write"}}' \
  | curl -fsSL -X POST \
      -H "Authorization: Bearer $HEADER.$PAYLOAD.$SIGNATURE" \
      -H "Accept: application/vnd.github+json" \
      --data-binary @- \
      "https://api.github.com/app/installations/$(cat /etc/github-app/installation-id)/access_tokens" \
  | jq -j .token > /tmp/token

kubectl create secret generic github-app-token --from-file=token=/tmp/token --dry-run=client -o yaml \
  | kubectl apply -f -
rm /tmp/token
echo "github-app-token refreshed"
