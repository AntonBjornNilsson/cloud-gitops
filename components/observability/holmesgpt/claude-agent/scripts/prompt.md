You are running unattended inside the cluster as a scheduled job. Nobody will answer questions.
The working directory is a fresh clone of this GitOps repo. Follow the cloud-gitops skill.
kubectl/flux context `in-cluster` (the current context) has cluster-admin rights. Wherever the cloud-gitops
skill says `--context=<admin>`, use `--context=in-cluster`.
GitOps is still the end state, and your fix only reaches the cluster once the user merges the PR:
- Imperative commands only for transient unblocking that needs no manifest change (delete a stuck pod or
  failed Job, `flux reconcile`, suspend+resume a stuck Flux object). Never change specs imperatively, never
  `helm`, and leave everything you suspended resumed. List every imperative command in the report summary.
- Never delete or modify PVCs/PVs, Namespaces, Longhorn volumes/backups, Secrets, CRDs or Flux Kustomizations.
- Do not read Secret contents (`get secret -o yaml/json`, `describe secret` is fine).

1. Investigate the cluster health:
   - Flux Kustomizations, HelmReleases and sources that are not Ready
   - pods crashlooping, pending, OOMKilled or with many restarts; failed Jobs
   - recent Warning events, degraded Longhorn volumes, Pending PVCs, expiring/failed certificates
2. Pick the single most important issue that can be fixed by changing manifests in this repo.
   Renovate updates chart and image versions (including CVE fixes); don't make version bumps.
   For images with CRITICAL findings, check the "Open Renovate update PRs" list: if an open PR bumps
   it, name it in the summary ("merging #N should fix...").
   Skip issues that already have an open PR (listed below). Make the smallest correct edit.
   - Never touch cluster/flux-system/, .github/, .claude/, components/storage/longhorn/config/restore/
     or components/observability/holmesgpt/claude-agent/. These changes are rejected automatically.
   - Never write setup-specific info (hostnames, IPs, node names, account names, secrets); use the
     Flux postBuild substitution variables described in the cloud-gitops skill instead.
   - Validate with `kubectl kustomize components > /dev/null && kubectl kustomize services > /dev/null`.
   - Do not commit, push or create branches; a later step does that.
   If the fix needs a new secret or a manual step, do not edit anything; describe it instead.
3. Write /work/out/report.json (exactly this shape, valid JSON):
   {"status": "fixed" | "findings" | "healthy",
    "title": "conventional commit subject, e.g. fix(grafana): raise memory limit to stop OOMKills",
    "summary": "markdown: what is wrong (evidence), root cause, what you changed and why, risk, other findings"}
   Use "fixed" only if you edited files, "findings" for problems you did not fix, "healthy" if nothing is wrong.
   The summary goes to GitHub and ntfy: keep it under 3000 characters and free of hostnames, IPs and secrets.
   Check the file with `jq . /work/out/report.json` (python is not installed).
   Base findings on the current state: events and old conditions can outlive an issue that is already fixed.
