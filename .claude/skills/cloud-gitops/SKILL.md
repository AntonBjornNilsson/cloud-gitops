---
name: cloud-gitops
description: Working guide for the cloud-gitops homelab repo (Flux v2 + Kustomize on k0s). Use for any task in this repo - adding/enabling/disabling a component or service, editing HelmReleases, ingress/auth, Cilium policies, Kyverno policies, Longhorn backups, Grafana dashboards, HolmesGPT/Ollama, or debugging the cluster. Covers layout, conventions, the mandatory read-only/GitOps workflow, and validation commands.
---

# cloud-gitops working guide

Flux v2 GitOps repo for a k0s homelab cluster.
Everything in the cluster is declared here; secrets live in a separate private secrets repo (see `cluster/flux-system/secrets-repo.yaml`).

For the long-form rationale (component vs. service tiers, config separation, dependency graph, PVC protection),
read `.agents/skills/cloud-gitops-architecture/SKILL.md`. This file is the quick, actionable version.

## Hard rules

0. **Never write setup-specific information into the repo** (node names, IPs, hostnames, account/repo names, paths, secret values). Anything environment-specific goes through `${var}` substitution from the secrets repo. This also applies to docs, comments, skills and commit messages.
1. **No imperative cluster mutations.** Never `kubectl apply/delete/edit/patch/scale/create`, never `helm install/upgrade`.
   Change manifests -> commit -> push -> let Flux reconcile.
2. **Always use `--context=oidc-user`** for kubectl/flux (it is read-only plus Flux reconcile rights).
   The default current context may be an admin one — do not rely on it.
   Allowed: `get`, `describe`, `logs`, `top`, `flux get ...`, `flux reconcile ...`.
3. **No plaintext secrets or private domains.** Use `${var}` placeholders; values come from the
   `flux-substitutions` Secret (in `cloud-gitops-secrets`) via `postBuild.substituteFrom`.
   Common vars: `${domain}`, `${auth_domain}`, `${admin_email}`, `${github_repo}`, `${oidc_issuer_host}`.
   New secrets must be added to `cloud-gitops-secrets` by the user — tell them which key to add.
   Never write hardcoded domain/credential fallbacks in scripts (`os.environ.get("X", "")`, not a real URL).
4. **Every Namespace** gets `annotations: kustomize.toolkit.fluxcd.io/prune: disabled` (Kyverno also enforces it).

## Layout

```
cluster/flux-system/        Flux bootstrap: gotk-*, secrets-repo.yaml, flux-components.yaml (./components), flux-services.yaml (./services)
cluster/cluster-oidc-admin.yaml  OIDC admin ClusterRoleBinding
components/kustomization.yaml    ON/OFF switch for infrastructure (list of system-*.yaml Flux Kustomizations)
components/<category>/<name>/    hardware | networking | observability | security | storage
services/kustomization.yaml      ON/OFF switch for user apps (list of directories)
services/<category>/<name>/      ai | demo | game-servers | home-automation | management | media/{getting,sorting,playing} | security
scripts/                         flux-all.sh (suspend|resume all), trigger.sh (HolmesGPT checks), sync-longhorn-backups.py
TODO                             user's backlog (">" = done)
```

Enable/disable = uncomment/comment the line in `components/kustomization.yaml` or `services/kustomization.yaml`.
Currently disabled examples: cloudflare, aws, trivy-operator, the *arr stack, homeassistant, vaultwarden, tailscale, github-runners, skyrim.
`components/networking/ingress-nginx` is legacy (Traefik replaced it) and is not referenced.

## Components (infrastructure)

Each component directory:
```
<name>.yaml                 Namespace + HelmRepository + HelmRelease (or raw manifests)
cilium-policy.yaml          CiliumNetworkPolicy
system-<name>.yaml          Flux Kustomization (path ./components/<cat>/<name>), listed in components/kustomization.yaml
kustomization.yaml          lists <name>.yaml, cilium-policy.yaml, [system-<name>-config.yaml]
config/ + system-<name>-config.yaml   (only if CRs/webhooks need the operator first; dependsOn: system-<name>)
```
The Flux Kustomization template: `apiVersion: kustomize.toolkit.fluxcd.io/v1`, namespace `flux-system`,
`sourceRef: GitRepository/flux-system`, `prune: true`, `dependsOn` on what it needs,
and `postBuild.substituteFrom: [{kind: Secret, name: flux-substitutions}]`. Copy an existing one, e.g.
`components/security/kyverno/system-kyverno.yaml`.

HelmRelease house style (see `components/observability/jaeger/jaeger.yaml`): `helm.toolkit.fluxcd.io/v2`,
HelmRepository in the same namespace, semver range `version: "3.x"`, `install/upgrade.strategy: RetryOnFailure`,
`remediation.retries: 3`, explicit `timeout`.

## Services (apps)

One directory with `kustomization.yaml` + `<name>.yaml` (Namespace, PVC, Deployment, Service, Ingress, CiliumNetworkPolicy),
added as a directory entry in `services/kustomization.yaml`. **No per-service Flux Kustomization** — all are reconciled by `flux-services`
(which depends on flux-components, system-traefik, system-cert-manager-config, system-longhorn). Template: `services/media/sorting/sonarr/sonarr.yaml`.

Conventions:
- Copy node placement (nodeSelector/tolerations), TZ, PUID/PGID and media hostPath from a sibling service; do not invent or document new values.
- Single-replica for RWO PVCs (multi-attach is impossible).

## Ingress, TLS and auth (mostly automatic via Kyverno)

Write a minimal Ingress with `host: <app>.${domain}`. Kyverno then mutates it to add:
- `ingressClassName: traefik` (if unset),
- cert-manager `cloudflare-wildcard-issuer` annotation and `spec.tls` with secret `<ingress-name>-tls` (if unset),
- Authelia forward-auth middleware `authelia-authelia-forward-auth@kubernetescrd`.

Opt out of Authelia with label `enable-oauth: "false"` (e.g. apps doing their own OIDC). Apps using Authelia OIDC
(grafana, headlamp, homepage, open-webui) need a client entry + hashed secret in authelia config and secrets repo.
Auth chain details: `components/networking/traefik/README.md`.

## Network policy (Cilium)

Every workload has a CiliumNetworkPolicy. Pattern: ingress from `traefik` namespace on the app port,
`fromEntities: [host, remote-node, health]` for probes, `fromEndpoints: [{}]` intra-ns;
egress to kube-dns port 53, explicit peer namespaces, `toEntities: [world]` only if needed.
When two apps talk, update **both** sides' policies. Dropped traffic -> check Hubble.

## Storage & backups (Longhorn)

- PVCs are NOT backed up by default. Opt in with label or annotation `backup.longhorn.io/enabled: "true"`.
  Kyverno turns that into the Longhorn `backup` recurring-job group. Never schedule backups on the `default` group (Longhorn auto-adds every unlabeled volume to it).
- Daily backup 02:00 to S3; CronJob `longhorn-backup-sync` at 03:00 commits updates to
  `components/storage/longhorn/config/restore/volumes.yaml` ("chore(longhorn): update latest PVC backup tags ... [skip ci]").
  **That bot pushes to main daily — `git pull --rebase` before pushing.** Do not hand-edit `volumes.yaml` except to remove entries.
- DR restore flow: `components/storage/longhorn/config/restore/README.md`.

## Observability

- Everything lives in `components/observability/victoriametrics/`; Grafana (operator) is the single UI, home dashboard `homelab-overview`.
  - Metrics: VictoriaMetrics k8s-stack HelmRelease (`victoriametrics.yaml`). Logs: `logs.yaml` (VLSingle + VLAgent collecting all container logs).
    Traces: `traces.yaml` (VTSingle; Traefik sends OTLP/HTTP to `vtsingle-traces...:10428/insert/opentelemetry/v1/traces`).
  - Prefer standalone CRs over chart values: scrape targets in `scrapes/` (VMPodScrape), alert rules in `rules/` (VMRule, one file per domain),
    synthetic probes in `blackbox-exporter.yaml` (VMProbe; every Ingress is probed automatically), routing in `alertmanager-config.yaml`.
  - LogsQL alert rules: VMRule labelled `alerting.homelab/datasource: victorialogs` (`logs-alerting.yaml`); the main vmalert ignores them.
  - Alerts -> Alertmanager -> `alertmanager-ntfy` bridge (`/hook`) -> ntfy topic `homelab-alerts`. Severity sets priority
    (critical=urgent, warning=high, info=low). Every rule needs a `severity` label and `summary`/`description` annotations.
  - New app with metrics: add a VMPodScrape in `scrapes/` and allow ingress from the `victoriametrics` namespace on its metrics port.
- Dashboards: Jsonnet in `components/observability/dashboards/src/`, then run `components/observability/dashboards/generate.sh`
  (needs `jsonnet` + `jb install` for `vendor/`) and commit the regenerated `generated/*.yaml`. Never edit `generated/` by hand.
  Never use `${var}` in dashboards (Flux substitutes it); use `$var`. Community dashboards: `dashboards/upstream.yaml` (grafana.com id + revision).
- HolmesGPT uses in-cluster Ollama (`llama3.1:8b`, chosen for tool-calling support). Scheduled checks in
  `holmesgpt/config/scheduled-health-check.yaml`; trigger with `scripts/trigger.sh [list|all|<check>]`
  (note: this script creates a temporary Job, i.e. a cluster write — only run it when the user asks).
  Don't add `models.pull` to the Ollama HelmRelease values (makes Flux reconciliation slow).

## Workflow for any change

```bash
# 1. Diagnose (read-only)
flux --context=oidc-user get kustomizations -A
flux --context=oidc-user get helmreleases -A
kubectl --context=oidc-user -n <ns> get pods,events
kubectl --context=oidc-user -n <ns> logs deploy/<name>

# 2. Edit manifests, then validate locally (substitution vars stay literal - that's expected)
kubectl kustomize components > /dev/null && kubectl kustomize services > /dev/null
kubectl kustomize components/<cat>/<name>

# 3. Commit (conventional style: feat(scope): / fix(scope): / chore(scope):), pull --rebase, push

# 4. Reconcile and verify
flux --context=oidc-user reconcile source git flux-system
flux --context=oidc-user reconcile kustomization <system-name|flux-services> --with-source
flux --context=oidc-user reconcile helmrelease <name> -n <ns>
```

Commit and push without asking: pushing is how changes reach the cluster. `kustomize` is not installed standalone; use `kubectl kustomize`.

## Debugging cheatsheet

- Kustomization stuck "dependency not ready" -> walk the `dependsOn` chain; one failed HelmRelease blocks `flux-services`.
- HelmRelease failing upgrades -> check `flux get hr`, then `kubectl --context=oidc-user describe hr`; Jaeger uses `upgrade.remediation.strategy: uninstall` for stuck upgrades.
- `${var}` appearing literally in the cluster -> the Kustomization is missing `postBuild.substituteFrom` or the key is missing from the secrets repo.
- Pod can't reach something -> CiliumNetworkPolicy on either side; DNS egress rule missing is the usual culprit.
- PVC Pending/Multi-attach -> RWO volume with >1 replica or a rollout with surge; use `strategy: Recreate` or replicas 1.
