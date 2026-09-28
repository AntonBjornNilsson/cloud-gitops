---
name: cloud-gitops-architecture
description: Architecture, organization, and dependency guidelines for components and services in the cloud-gitops repository. Explains the distinction between cluster components (infrastructure/foundational) and services (user-facing applications), how Flux Kustomizations are structured, config separation, and dependsOn dependency management.
---

# Cloud-GitOps Architecture Guide

This guide describes the architectural layout, component vs. service distinction, Flux Kustomization hierarchy, and dependency resolution rules for the `cloud-gitops` repository. Any LLM or developer working with this repository must adhere to these patterns.

---

## 1. Architectural Distinction: Components vs. Services

Everything deployed into the cluster falls strictly into one of two tiers:

| Tier | Purpose | Characteristics | Examples |
|---|---|---|---|
| **Components** | **Foundational Infrastructure** | Parts the cluster cannot function without, or should not function without. Enables base networking, storage, security, policy, and monitoring. | Cilium, MetalLB, Traefik, Cert-Manager, Longhorn, VictoriaMetrics, Grafana, Kyverno, Authentik |
| **Services** | **End-User Value** | Applications and workloads that deliver value to the end user. They rely on the foundational infrastructure provided by components. | Jellyfin, Dispatcharr, Radarr, Sonarr, Skyrim Server, Home Assistant, Ollama, Open-WebUI, Vaultwarden |

---

## 2. Repository Layout & Control Points

```
cloud-gitops/
├── cluster/
│   └── flux-system/
│       ├── gotk-components.yaml      # Flux controller deployments & CRDs
│       ├── gotk-sync.yaml            # Flux GitRepository & root Kustomization
│       ├── secrets-repo.yaml         # Secrets repository source & kustomization
│       ├── flux-components.yaml      # Flux Kustomization CR pointing to ./components
│       ├── flux-services.yaml        # Flux Kustomization CR pointing to ./services
│       └── kustomization.yaml        # Root kustomize: ONLY includes gotk, secrets, flux-components, flux-services
├── components/
│   ├── kustomization.yaml            # SINGLE SOURCE OF TRUTH for what components are enabled
│   ├── hardware/
│   ├── networking/
│   ├── observability/
│   ├── security/
│   └── storage/
└── services/
    ├── kustomization.yaml            # SINGLE SOURCE OF TRUTH for what services are enabled
    ├── ai/
    ├── demo/
    ├── game-servers/
    ├── home-automation/
    ├── management/
    ├── media/
    └── security/
```

### Key Principles:
1. `cluster/flux-system/kustomization.yaml` is clean and high-level. It NEVER contains individual component or service definitions.
2. `components/kustomization.yaml` is solely in charge of which components are enabled.
3. `services/kustomization.yaml` is solely in charge of which services are enabled.

---

## 3. Component Architecture & Config Separation

### Why Config is Separated (`config/` subfolder)
When an operator or HelmRelease is deployed (e.g. MetalLB, Cert-Manager, Kyverno, Longhorn), it introduces Custom Resource Definitions (CRDs) and validating/mutating webhooks.
Applying Custom Resources (e.g. `IPAddressPool`, `ClusterIssuer`, `ClusterPolicy`, `RecurringJob`) in the same manifest batch will fail because:
1. The CRDs are not yet registered with the Kubernetes API server.
2. The admission webhook pods are not yet running and ready to validate the CRs.

### The Self-Contained Component Pattern
Each component that requires post-installation configuration **is in charge of its own config kustomization**:

```
components/<category>/<component>/
├── <component>.yaml                 # HelmRelease, Namespace, etc.
├── cilium-policy.yaml               # Component network policy
├── system-<component>.yaml          # Flux Kustomization CR for the component itself
├── system-<component>-config.yaml   # Flux Kustomization CR for the component config
├── kustomization.yaml               # Includes <component>.yaml, cilium-policy.yaml, and system-<component>-config.yaml
└── config/                          # Subdirectory containing post-install Custom Resources
    ├── kustomization.yaml           # Standard kustomize file listing CR manifests
    └── <custom-resources>.yaml      # IP pools, ClusterIssuers, Policies, Jobs, etc.
```

### How the Config Flow Works:
1. `components/kustomization.yaml` deploys `<category>/<component>/system-<component>.yaml`.
2. Flux reconciles `system-<component>` at `path: ./components/<category>/<component>`.
3. The component's `kustomization.yaml` deploys the component manifests AND the `system-<component>-config` Flux Kustomization CR.
4. `system-<component>-config` specifies:
   - `path: ./components/<category>/<component>/config`
   - `dependsOn: - name: system-<component>`
5. Flux waits until `system-<component>` is healthy and ready, then applies the `config/` resources.

> [!WARNING]
> **Circular Deadlock Prevention (`wait: false` on Parents)**:
> If `system-<component>.yaml` deploys `system-<component>-config.yaml`, the parent `system-<component>.yaml` **MUST set `wait: false`** (or omit `wait: true`).
> If `wait: true` is set on the parent, Flux waits for all applied resources—including `system-<component>-config`—to be Ready before marking the parent Ready. Because the child has `dependsOn: system-<component>`, neither can ever become ready.
> Always configure both Kustomizations with `timeout: 5m0s` and `retryInterval: 1m0s` to prevent transient timeouts during container image pulls and initial webhook setups.

---

## 4. Thorough Dependency Management (`dependsOn`)

Flux Kustomizations (`kustomize.toolkit.fluxcd.io/v1`) must declare explicit dependencies using `spec.dependsOn` to prevent race conditions during cluster bootstrap.

### Standard Dependency Graph:

```mermaid
graph TD
    secrets[secrets-kustomization] --> cert_cfg[system-cert-manager-config]
    secrets --> auth[system-authentik]
    secrets --> oauth[system-oauth2-proxy]

    cilium[system-cilium]
    
    metallb[system-metallb] --> metallb_cfg[system-metallb-config]
    cert[system-cert-manager] --> cert_cfg
    
    metallb_cfg --> traefik[system-traefik]
    cert_cfg --> traefik
    
    longhorn[system-longhorn] --> longhorn_cfg[system-longhorn-config]
    traefik --> longhorn_cfg
    
    traefik --> vm[system-victoriametrics]
    traefik --> grafana[system-grafana]
    vm --> grafana
    
    traefik --> auth
    longhorn_cfg --> auth
    
    traefik --> oauth
    
    kyverno[system-kyverno] --> kyverno_cfg[system-kyverno-config]
    
    traefik --> services[flux-services]
    cert_cfg --> services
    longhorn --> services
```

### Exact Component Dependencies:

1. **`system-metallb-config`**:
   - `dependsOn: [system-metallb]`
2. **`system-cert-manager-config`**:
   - `dependsOn: [system-cert-manager, secrets-kustomization]`
3. **`system-traefik`**:
   - `dependsOn: [system-metallb-config, system-cert-manager-config, system-victoriametrics]`
4. **`system-longhorn-config`**:
   - `dependsOn: [system-longhorn, system-traefik]`
5. **`system-kyverno`**:
   - `dependsOn: [system-victoriametrics]`
6. **`system-kyverno-config`**:
   - `dependsOn: [system-kyverno]`
7. **`system-victoriametrics`**:
   - Reconciles independently (provides foundational Prometheus CRDs required by other components).
8. **`system-grafana`**:
   - `dependsOn: [system-victoriametrics, system-traefik]`
9. **`system-authentik`**:
   - `dependsOn: [system-traefik, system-longhorn-config, secrets-kustomization]`
10. **`system-oauth2-proxy`**:
   - `dependsOn: [system-traefik, secrets-kustomization]`
11. **`flux-services`**:
    - `dependsOn: [flux-components, system-traefik, system-cert-manager-config, system-longhorn]`

---

## 5. Adding a New Component: Step-by-Step

When adding a new component (e.g. `monitoring-agent` in `observability`):

1. **Create Component Directory**:
   `components/observability/monitoring-agent/`
2. **Add Manifests**:
   - `monitoring-agent.yaml` (HelmRelease or Deployment, Namespace)
   - `cilium-policy.yaml` (CiliumNetworkPolicy)
3. **Add Component Flux Kustomization**:
   Create `components/observability/monitoring-agent/system-monitoring-agent.yaml`:
   ```yaml
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: system-monitoring-agent
     namespace: flux-system
   spec:
     interval: 2m0s
     path: ./components/observability/monitoring-agent
     prune: true
     sourceRef:
       kind: GitRepository
       name: flux-system
     dependsOn:
       - name: system-traefik # add whatever infrastructure it requires
     wait: true
     postBuild:
       substituteFrom:
         - kind: Secret
           name: flux-substitutions
   ```
4. **If Post-Install Config is Needed (CRDs/Webhooks)**:
   - Create `components/observability/monitoring-agent/config/`
   - Add CR manifests and `config/kustomization.yaml`
   - Create `system-monitoring-agent-config.yaml` with `dependsOn: [system-monitoring-agent]`
   - Include `system-monitoring-agent-config.yaml` in `components/observability/monitoring-agent/kustomization.yaml`
5. **Register Component in `components/kustomization.yaml`**:
   ```yaml
   resources:
     # ...
     - observability/monitoring-agent/system-monitoring-agent.yaml
   ```

---

## 6. Adding a New Service: Step-by-Step

When adding an end-user service (e.g. `valheim-server` under `game-servers`):

1. **Create Service Directory**:
   `services/game-servers/valheim-server/`
2. **Add Manifests & Kustomization**:
   - `valheim-server.yaml` (Namespace, Deployment/StatefulSet, Service, PVC, etc.)
   - `cilium-policy.yaml` (Strict egress/ingress network policy)
   - `kustomization.yaml` listing the manifests
3. **Register Service in `services/kustomization.yaml`**:
   ```yaml
   resources:
     # ...
     - game-servers/valheim-server
   ```
4. **Do NOT create a separate Flux Kustomization**:
   Services are aggregated and reconciled as a unit under `flux-services`. Only use separate Flux Kustomizations for infrastructure components that other resources depend on.
