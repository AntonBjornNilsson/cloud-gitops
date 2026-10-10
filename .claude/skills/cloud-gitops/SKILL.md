---
name: cloud-gitops
description: Working guide for the cloud-gitops homelab repo (Flux v2 + Kustomize on k0s). Use for any task in this repo - adding/enabling/disabling a component or service, editing HelmReleases, ingress/auth, Cilium policies, Kyverno policies, Longhorn backups, Grafana dashboards, HolmesGPT/Ollama, or debugging the cluster. Covers layout, conventions, the admin-context/GitOps-end-state workflow, and validation commands.
---

# cloud-gitops working guide

Flux v2 GitOps repo for a k0s homelab cluster.
Everything in the cluster is declared here; secrets live in a separate private secrets repo (see `cluster/flux-system/secrets-repo.yaml`).

For the long-form rationale (component vs. service tiers, config separation, dependency graph, PVC protection),
read `.agents/skills/cloud-gitops-architecture/SKILL.md`. This file is the quick, actionable version.

## Hard rules

0. **Never write setup-specific information into the repo** (node names, IPs, hostnames, account/repo names, paths, secret values). Anything environment-specific goes through `${var}` substitution from the secrets repo. This also applies to docs, comments, skills and commit messages.
1. **GitOps is the end state.** Git is the source of truth; every lasting change goes manifests -> commit -> push -> Flux reconcile.
   Imperative commands (`kubectl apply/delete/edit/patch/scale/create/rollout restart`, `flux suspend/resume`) are allowed only
   as temporary steps while debugging or unblocking (e.g. deleting a stuck pod/job, testing a patch, clearing a failed Helm release).
   Before you finish a task:
   - every fix you applied by hand is also committed and pushed, or reverted — the cluster must match the repo;
   - anything you suspended is resumed, and `flux get kustomizations -A` / `flux get helmreleases -A` show everything Ready;
   - tell the user which imperative commands you ran and where the matching commit is.
   Never `helm install/upgrade/uninstall` (HelmReleases are Flux-managed). Ask first before anything that loses data or is
   hard to undo: deleting PVCs/PVs, Namespaces, Longhorn volumes/backups, Secrets, CRDs, or Flux objects with `prune` on.
2. **Use the admin kube context** (cluster-admin; its name is in local memory, never in the repo) for kubectl/flux:
   pass it per command (`--context=<admin>`), never rely on the current context, never run `kubectl config use-context`.
   Admin rights do not relax rule 1.
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
Currently disabled examples: aws, the *arr stack, homeassistant, vaultwarden, github-runners, skyrim.

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

HelmRelease house style (see `components/security/cert-manager/cert-manager.yaml`): `helm.toolkit.fluxcd.io/v2`,
HelmRepository in the same namespace, semver range `version: "3.x"`, `install/upgrade.strategy: RetryOnFailure`,
`remediation.retries: 3`, explicit `timeout`.

## Services (apps)

One directory with `kustomization.yaml` + `<name>.yaml` (Namespace, PVC, Deployment, Service, Ingress, CiliumNetworkPolicy),
added as a directory entry in `services/kustomization.yaml`. **No per-service Flux Kustomization** — all are reconciled by `flux-services`
(which depends on flux-components, system-traefik, system-cert-manager-config, system-longhorn). Template: `services/media/sorting/sonarr/sonarr.yaml`.

Conventions:
- Copy node placement (nodeSelector/tolerations), TZ, PUID/PGID and media hostPath from a sibling service; do not invent or document new values.
- Pin to a node only via substitution (`kubernetes.io/hostname: ${media_node}`, `${gpu_node}`, `${longhorn_node_N}`), never a literal hostname.
- Single-replica for RWO PVCs (multi-attach is impossible).

## Ingress, TLS and auth (mostly automatic via Kyverno)

Write a minimal Ingress with `host: <app>.${domain}`. Kyverno then mutates it to add:
- `ingressClassName: traefik` (if unset),
- cert-manager `cloudflare-wildcard-issuer` annotation and `spec.tls` with secret `<ingress-name>-tls` (if unset),
- Authelia forward-auth middleware `authelia-authelia-forward-auth@kubernetescrd`.

Ingresses are LAN-only by default: Traefik's default entrypoint is `websecure` (the LoadBalancer IP; LAN DNS resolves
`*.${domain}` there). Nothing else is published; see "Exposing a service to the internet" below.
Opt out of Authelia with label `enable-oauth: "false"` (e.g. apps doing their own OIDC). Apps using Authelia OIDC
(grafana, headlamp, homepage, open-webui) need a client entry + hashed secret in authelia config and secrets repo.
Auth chain details: `components/networking/traefik/README.md`.

## Exposing a service to the internet

Internet traffic only enters via the Cloudflare tunnel, which cfgate (`components/networking/cfgate/`) manages from Git:
tunnel, cloudflared connectors, DNS records and Access applications. Public DNS has **no wildcard**: a hostname
resolves publicly only if cfgate published it. Path: Cloudflare edge -> Access -> tunnel -> cfgate cloudflared ->
Service `traefik/traefik-public` (Traefik entrypoint `public`, port 8444, reachable only from the cfgate cloudflared
pods) -> Ingress -> Authelia (unless opted out) -> app.

A service is public only if **all three** are in place:
1. **Ingress annotation** `traefik.ingress.kubernetes.io/router.entrypoints: websecure,public` (for a HelmRelease,
   via the chart's ingress annotations or a postRenderer). Without it the tunnel gets a 404 from Traefik.
2. **HTTPRoute** in `components/networking/cfgate/config/routes.yaml` (namespace `cfgate-system`; the Gateway only
   admits routes from there). Copy an existing one: backend `traefik-public` port 443 in `traefik` (the ReferenceGrant
   in `gateway.yaml` covers it), annotations `cfgate.io/origin-protocol: "https"`, `cfgate.io/origin-ssl-verify: "true"`
   and `cfgate.io/origin-server-name: "<host>"` (Traefik picks the wildcard cert by SNI). Limit paths with
   `matches` + a named rule if only part of the app is public. Annotation `homelab/dns-zone: "domain"` (or
   `"auth-domain"` for the email-domain zone) picks the `CloudflareDNS` resource in `dns.yaml` that creates the
   proxied CNAME; without it no DNS record is published.
3. **Access application** in `components/networking/cfgate/config/access.yaml` targeting the route, with a policy:
   - people: `allow-admin` (Google login, `allowedIdps: ["${cloudflare_google_idp_id}"]`, `autoRedirectToIdentity: true`),
     and add `cfgate.io/access-required: cfgate-system/<app>` to the route so it serves 503 instead of going
     unprotected if the app is not Ready. Not on a host that also has a path-scoped bypass app (e.g. auth +
     auth-oidc-machine): cfgate treats the overlap as a conflict and serves 503 for the whole host;
   - machines (webhooks): `bypass-everyone` on a path-limited rule (`targetRef.sectionName: <rule name>`); the app
     must authenticate the request itself (e.g. HMAC). `access-required` does not accept bypass policies.

Then commit, push and verify:
```bash
kubectl --context=<admin> -n cfgate-system get cloudflaretunnel,cloudflaredns,httproute,cloudflareaccessapplication
dig +short <host> @<zone nameserver>      # resolves publicly only once published
```
From outside (mobile data) the host should redirect to Cloudflare Access; Traefik access logs show
`"entryPointName":"public"` for tunnel traffic. Clients that cannot do a browser login (native/TV apps, APIs)
fail behind an allow policy: decide per app whether to use a service token (`non_identity` policy) or a bypass.

To unpublish: remove the HTTPRoute and its Access application (cfgate withdraws the DNS record) and drop `public`
from the Ingress annotation. Never re-add a `*.${domain}` record in Cloudflare: it makes every LAN-only name resolve
publicly again. cfgate is alpha and pinned exactly: read the chart upgrade notes before bumping it.

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
- `holmesgpt/claude-agent/`: daily CronJob running Claude Code (cluster-admin kubectl, context `in-cluster`; GitOps rules in its prompts) that opens `claude/*` PRs as a
  GitHub App; `holmes-remediation` sends the ntfy Merge/Reject buttons. Tooling image is built by
  `.github/workflows/claude-agent-image.yaml` (GHCR, `:latest`, pulled with `Always`); scripts live in `scripts/`.

## GitHub

- `main` is protected by `.github/rulesets/main.json` (PR + `validate` check). Admins bypass, the agent's GitHub App does not.
- Version updates come from the `claude-agent-updates` CronJob (daily): `scripts/check-updates.sh` lists newer chart/image
  versions, Claude picks one batch (Trivy CRITICAL fixes first, one core component per PR, no majors), `publish.sh` only
  accepts version-field diffs and opens a `claude/updates-*` PR; it reaches main only via the ntfy Merge button. One update
  PR at a time. Dependabot only covers `.github/` actions and the claude-agent image (paths the agent may not touch).
  After a bump, trivy-operator rescans the new images: `kubectl --context=<admin> get vulnerabilityreports -n <ns> -o wide`.
  Longhorn: one minor at a time; don't roll Longhorn together with other upgrades (kubelet pulls images serially, others time out).
  After editing the JSON, re-apply it with `gh api` (PUT on the existing ruleset id).

## Workflow for any change

```bash
# 1. Diagnose (read-only)
flux --context=<admin> get kustomizations -A
flux --context=<admin> get helmreleases -A
kubectl --context=<admin> -n <ns> get pods,events
kubectl --context=<admin> -n <ns> logs deploy/<name>

# 2. Edit manifests, then validate locally (substitution vars stay literal - that's expected)
kubectl kustomize components > /dev/null && kubectl kustomize services > /dev/null
kubectl kustomize components/<cat>/<name>

# 3. Commit (conventional style: feat(scope): / fix(scope): / chore(scope):), pull --rebase, push

# 4. Reconcile and verify
flux --context=<admin> reconcile source git flux-system
flux --context=<admin> reconcile kustomization <system-name|flux-services> --with-source
flux --context=<admin> reconcile helmrelease <name> -n <ns>
```

Commit and push without asking: pushing is how changes reach the cluster.
Only stage and push files you changed in this session (`git add <paths>`, never `git add -A`/`.`); other sessions may have uncommitted work in the tree — leave it alone (use `git pull --rebase --autostash` if it blocks the rebase). `kustomize` is not installed standalone; use `kubectl kustomize`.

## Debugging cheatsheet

- Kustomization stuck "dependency not ready" -> walk the `dependsOn` chain; one failed HelmRelease blocks `flux-services`.
- HelmRelease failing upgrades -> check `flux get hr`, then `kubectl --context=<admin> describe hr`; for stuck upgrades consider `upgrade.remediation.strategy: uninstall`.
- `${var}` appearing literally in the cluster -> the Kustomization is missing `postBuild.substituteFrom` or the key is missing from the secrets repo.
- Pod can't reach something -> CiliumNetworkPolicy on either side; DNS egress rule missing is the usual culprit.
- PVC Pending/Multi-attach -> RWO volume with >1 replica or a rollout with surge; use `strategy: Recreate` or replicas 1.
