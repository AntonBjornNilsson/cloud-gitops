---
name: cloud-gitops
description: Working guide for the cloud-gitops homelab repo (Flux v2 + Kustomize on k0s). Use for any task in this repo - adding/enabling/disabling a component or service, editing HelmReleases, ingress/auth, Cilium policies, Kyverno policies, Longhorn backups, Grafana dashboards, the claude-agent service, Ollama, or debugging the cluster. Covers layout, conventions, the admin-context/GitOps-end-state workflow, and validation commands.
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
   `${cloudflare_*}` vars live in the separate `cloudflare-substitutions` Secret (`cloudflare/` in
   `cloud-gitops-secrets`) and `${authelia_*}` vars in `authelia-substitutions` (`authelia/`);
   Kustomizations that need them list those Secrets after `flux-substitutions` in `substituteFrom`.
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
scripts/                         flux-all.sh (suspend|resume all), sync-longhorn-backups.py
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
(grafana, headlamp, homepage, open-webui, jellyfin) need a client entry + hashed secret in authelia config and secrets repo.
Authelia is **deny by default**: a new forward-auth app also needs an `access_control.rules` entry in
`components/security/authelia/authelia.yaml` (`subject: "group:<app>"`; `group:admin` already covers every host),
and a new OIDC client an `authorization_policies` entry. Users and their groups are managed with
`manage_users.py` in the secrets repo, which reads the available groups from those rules (nothing to list by hand).
Second factors (YubiKeys, TOTP) are in Git too: `manage_2fa.py` in the secrets repo writes the `authelia-2fa` Secret
and the `second-factor-sync` sidecar makes Authelia's database match it, so devices added in the web UI are removed.
Only one user may be in `group:admin`; OIDC cluster-admin is bound by username (`cluster/cluster-oidc-admin.yaml`).
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

Edge security (WAF custom rules, rate limiting, zone settings) is `components/networking/cloudflare-security/`:
rules in `app/policy.py`, pushed by a CronJob every 30 min; dashboard edits are overwritten. A new public host for
people should be added to the EU/EEA geo rule there; a new machine path must be exempted from it.

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
  - Media exporters (exportarr, qbittorrent-exporter, jellyfin-exporter) run as `<app>-exporter` Deployments in the app's
    namespace with label `homelab/media-exporter: "true"` and a port named `metrics`; `scrapes/media-exporters.yaml` picks them up
    (adds `app=<namespace>`). Dashboards: `media_*.jsonnet` + `dispatcharr.jsonnet` (shared helpers in `media.libsonnet`), and
    `services_overview.jsonnet`, which reads the service list from `services/kustomization.yaml`: regenerate after enabling/disabling a service.
- Dashboards: Jsonnet in `components/observability/dashboards/src/`, then run `components/observability/dashboards/generate.sh`
  (needs `jsonnet` + `jb install` for `vendor/`) and commit the regenerated `generated/*.yaml`. Never edit `generated/` by hand.
  Generated dashboards carry `kustomize.toolkit.fluxcd.io/substitute: disabled`, so `${...}` (data links) is safe in Jsonnet;
  a `// grafana-folder: <name>` line in the source sets the folder. Community dashboards: `dashboards/upstream.yaml`
  (grafana.com id + revision; still Flux-substituted, so no `${...}` there).
  Trivy drilldowns (`trivy_*.jsonnet`, shared `trivy.libsonnet`) read trivy-operator's per-finding info metrics and use MetricsQL.
- Ollama (`services/ai/ollama/`): don't add `models.pull` to its HelmRelease values (makes Flux reconciliation slow).
- `components/observability/claude-agent/` (namespace `claude-agent`, Flux Kustomization `system-claude-agent`): always-on
  Agent SDK service (TypeScript and the web UI in `app/`, shipped as a ConfigMap and run by Node's type stripping; image
  in `image/` built by `.github/workflows/claude-agent-image.yaml`; `app/updater.ts` restarts the Deployment onto a new
  `:latest` digest once the service is idle).
  - Runs one session at a time: scheduled health reviews and weekly version updates (`SCHEDULES`, UTC cron; the
    updates run applies the open Renovate PRs it judges safe from their release notes, `app/updates.md`) and tasks started from the web UI
    at `claude-agent.${domain}` (Authelia): live transcript with reasoning, messages into a running session, continue a
    session, model/effort per run, token usage and claude.ai plan limits (`/usage`).
  - Claude Code auto-memory is pinned to one directory on the service's PVC (`MEMORY_DIR`, default `/data/memory`),
    shared by all runs; writes there need no approval. Memory guidance for the agent is in `app/rules.md`.
  - `app/policy.ts` decides which Bash commands run directly (read-only kubectl/flux/git/text tools); every other
    command, and the final "apply this diff", is a yes/no question on ntfy topic `claude-agent` (buttons POST to the
    Authelia-free `/answer/<token>/` path; no answer in 4h = no). Rules for Claude: `app/rules.md`, `app/health.md`.
  - On yes, the `publisher` sidecar (only container with the GitHub App key) commits the diff, rebases onto the latest
    `main`, re-runs `kubectl kustomize` and pushes straight to `main`: no PR, no waiting for CI, the same as a session at
    the desk. Runs end with an all-clear (listing anything that needs a human) when nothing changed.

## GitHub

- `main` is protected by `.github/rulesets/main.json` (PR + `validate` check). Admins and the agent's GitHub App bypass it.
  The App's bypass entry (`actor_type: Integration`) exists only on the live ruleset, since its id is setup info. After
  editing the JSON, re-apply it with `gh api` (PUT on the existing ruleset id) and carry that entry over:
  ```bash
  extra=$(gh api repos/{owner}/{repo}/rulesets/<id> --jq '[.bypass_actors[] | select(.actor_type == "Integration")]')
  jq --argjson extra "$extra" '.bypass_actors += $extra' .github/rulesets/main.json | gh api -X PUT repos/{owner}/{repo}/rulesets/<id> --input -
  ```
- Version updates come from Renovate (`.github/renovate.json5`, weekly batch, Dependency Dashboard issue); patches
  automerge, and the claude-agent's Saturday `updates` run applies the rest it judges safe straight to `main`.
  After a bump, trivy-operator rescans the new images: `kubectl --context=<admin> get vulnerabilityreports -n <ns> -o wide`.
  Longhorn: one minor at a time; don't roll Longhorn together with other upgrades (kubelet pulls images serially, others time out).

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
