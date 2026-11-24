# Cluster security strategy

> **Status: working document.** This starts as a deliberately over-ambitious catalogue of every control
> worth considering. Each control is decided one by one (priority or drop), and the document is then
> condensed into the final strategy: what we protect, against whom, which controls we run, and how we
> keep checking that they work.
>
> **No setup information goes in here** (node names, IPs, hostnames, account names, versions of specific
> hosts, concrete findings that point at a weakness). This file is generic and public. Concrete findings
> live in the private findings register (see G2).

## How to read this

Every control has:

- **What**: what it does, in one or two sentences.
- **Why**: the attack or failure it addresses.
- **Now**: what the cluster does today, as far as the repo shows. "Verify" means it has to be checked live.
- **Effort**: S = hours, M = days, L = weeks or a migration.
- **Decision**: the priority, set during review.

| Priority | Meaning |
|---|---|
| **Now** | Start in the coming weeks. Real gaps with a cheap or obvious fix. |
| **Next** | After the Now items, within a few months. |
| **Later** | Backlog / stretch goal. Worth doing, not urgent. |
| **Drop** | Out of scope, with the reason. |

## How we work: lectures

The work goes in small daily sessions, each one an hour-long **lecture**: learning first, implementing
second. Every lecture explains the concept and the attack it stops, looks at our own cluster, does the
smallest real step, and ends with a quiz and a preview. Big controls are split across several lectures.
Concrete findings go into the private findings register (G2), not into this file.

| # | Lecture | Controls | Status |
|---|---|---|---|
| | **Module 1: Baseline. Where are we?** | | |
| 1 | Know thyself: a census of the cluster | G2, G6 prep, I2/E8/A3 checks | Done 2026-11-23 |
| 2 | The rulebooks: CIS, NSA/CISA, MITRE, OWASP, plus a Kubescape scan | G3, C1 | Done 2026-11-24 |
| 3 | The floor under the pods: kube-bench, kubelet and API server | H1, H7/H8 (read) | Done 2026-11-24 |
| 4 | Think like an attacker: a red-team run from a pod | G6 | |
| 5 | What is worth stealing: data classification, threat model check | D8, G1 | |
| | **Module 2: Visibility before enforcement** | | |
| 6 | Who did what: Kubernetes audit logging | J1 | |
| 7 | One pane for security: dashboard, alert group, auth alerts | J3, J4 | |
| 8 | Reading the wire: Hubble flows and drop alerts | N10 | |
| | **Module 3: Blast radius** | | |
| 9 | Humans with short-lived keys: two-factor for admin first, then OIDC kubectl, cert to break-glass | I5 (part), I1 | |
| 10-11 | RBAC deep dive: who can do what, and why charts over-grant | I3, I10 | |
| 12 | Tokens nobody asked for: automount off | I4 | |
| 13 | Least privilege for the robot: scoping the agent | A1, A5, A3 | |
| 14 | The side door: Tailscale ACLs | I8 | |
| 15 | Fixing the floor: kube-bench findings | H7, H8 | |
| | **Module 4: Network** | | |
| 16 | Encrypt the wire: WireGuard | N5 | |
| 17-18 | Default deny: audit, then enforce; no pod reaches the LAN | N1, N7 | |
| 19-20 | Egress by name: FQDN allowlists | N2, A4 | |
| | **Module 5: Edge and admission** | | |
| 21 | The outer gate: Access policies and bypass paths | E2, E3, E8 | |
| 22 | Headers, TLS and the WAF | E4, E5 | |
| 23 | Admission beyond PSS: Kyverno best-practice policies | W7 | |
| 24 | Graduation: rerun the red team, compare with lecture 4 | G6 | |

The Next and Later items get lectures once Module 5 is done.

## Principles

1. **Assume breach.** Any one pod, credential or node can be compromised. Controls should limit how far
   it spreads (blast radius) and make sure we notice (detection), not only keep attackers out.
2. **Defence in depth.** No single layer (Cloudflare, Authelia, network policy, PSS) is trusted alone.
3. **GitOps is the security boundary.** Git is the source of truth: whoever can change what Flux applies
   owns the cluster. The repo, its automation and its signing keys are protected like cluster-admin.
4. **Measure, don't assume.** Every control has a check that proves it works (an admission denial, a
   dropped flow, a 403 from the outside, an alert that fires) and that check runs on a schedule.
5. **Secure by default, exceptions in writing.** Defaults deny; every exception has a comment, a reason
   and a review date.
6. **Security must not cost recoverability.** Every control is checked against "can I still recover the
   cluster after a full outage or a lost key?".

## Framework mapping

Four public rulebooks are used as checklists (G3). Each one asks a different question, so each finds
different gaps:

| Rulebook | Asks | Shape | Checked by |
|---|---|---|---|
| CIS Kubernetes Benchmark | "How should every setting be configured?" | ~130 numbered, testable checks in 5 sections | kube-bench (nodes, control plane), Kubescape `cis-v1.12.0` (API objects) |
| NSA/CISA Kubernetes Hardening Guide | "What are the main themes to get right?" | Narrative guide, 5 themes | Kubescape `nsa` |
| MITRE ATT&CK for Containers / Microsoft Threat Matrix for Kubernetes | "What would an attacker do, step by step?" | Tactics (goals) x techniques (methods) | Kubescape `mitre`, attack simulation (G6) |
| OWASP Kubernetes Top 10 | "What goes wrong most often in practice?" | 10 risk categories | By hand (table below) |

A compliance score belongs to the tool, not to the cluster: tools weigh checks differently, skip what
they can't see, and can't see each other's controls. Scores are only tracked over time with the same
tool, version and exceptions file.

### OWASP Kubernetes Top 10 (2022) -> controls

| OWASP | Risk | Controls in this strategy |
|---|---|---|
| K01 | Insecure workload configurations | W1-W9, I4 |
| K02 | Supply chain vulnerabilities | S1-S12, W6, J5 |
| K03 | Overly permissive RBAC | I3, I4, I10, A1 |
| K04 | Lack of centralized policy enforcement | W7, W1, C3, C4 |
| K05 | Inadequate logging and monitoring | J1-J9, N9, N10 |
| K06 | Broken authentication | I1, I5, I6, I7, I9, K6 |
| K07 | Missing network segmentation | N1-N8, I2, I8 |
| K08 | Secrets management failures | K1-K7, S10 |
| K09 | Misconfigured cluster components | H1, H7, H8, K3 |
| K10 | Outdated and vulnerable components | H2, H3, H4, S9 |

### NSA/CISA themes and CIS sections -> modules

| NSA/CISA theme | CIS section | Where in this strategy |
|---|---|---|
| Pod security | 5.2 Pod security standards, 5.5 Admission control, 5.6 General policies | W (workloads), S3 |
| Network separation and hardening | 5.3 Network policies | N (network), E (edge) |
| Authentication and authorization | 3.1 Authentication, 5.1 RBAC and service accounts | I (identity), A (automation) |
| Audit logging and threat detection | 3.2 Logging | J (detection) |
| Upgrading and application security practices | (none) | H2-H4, S (supply chain) |
| (control plane hardening) | 1 Control plane, 2 etcd, 4 Worker nodes | H (hosts), K3 |
| (secrets) | 5.4 Secrets management | K (secrets) |

## Threat model

- **Purpose:** the cluster is in daily use, and it is also a practice ground for professional best
  practice. Controls that are more than a homelab strictly needs are welcome as learning, as long as
  they don't hurt recoverability.
- **Scope:** everything that can hand over the cluster: the cluster itself, both Git repos and GitHub
  (Actions, Renovate, the agent), Cloudflare, the nodes and NAS (OS, firmware, disks), the home network
  (router, VLANs, IoT, Wi-Fi, Tailscale) and the admin workstation.
- **Adversaries:** all of them:
  - opportunistic internet bots and scanners;
  - supply-chain compromise (a hijacked image, chart, action or release, applied by automation);
  - an exploited app or device inside the network moving laterally;
  - a targeted attacker (phishing, account takeover) and physical theft.
- **Assets, in order:** (1) credentials (password vault, secrets repo, API keys, the accounts above the
  cluster); (2) personal data (app databases, home automation history, personal files). Cluster
  integrity and availability matter, but they come after these two.
- **Risk appetite:** security first. Daily friction (hardware keys, signed commits, strict egress) is
  accepted where it buys real protection.
- **Entry points:** the Cloudflare tunnel (public hosts and machine bypass paths); the LAN and Tailscale;
  upstream code pulled in by Renovate and the agent; the accounts above the cluster (GitHub, Cloudflare,
  the IdP, the registrar); the admin workstation; physical access.

---

## G. Governance and process

### G1 Threat model
- **What:** A short written list of the assets, adversaries and entry points (the section above), revisited yearly.
- **Why:** Without it every control looks equally important; it is what lets us rank and drop things.
- **Now:** None written down.
- **Effort:** S
- **Decision (G1):** **Now.** Done in round 0 (see Threat model); refresh yearly.

### G2 Private findings register
- **What:** A list of concrete findings (what, where, severity, owner, status, date) in the private secrets
  repo, never in this public repo.
- **Why:** Scanners and reviews produce findings that are themselves sensitive (they point at weaknesses).
  A register keeps them tracked until closed instead of lost in chat logs.
- **Now:** None. Findings are scattered across TODO and memory.
- **Effort:** S
- **Decision (G2):** **Now.** Before the first scans. Opened in lecture 1.

### G3 Reference frameworks
- **What:** Use the CIS Kubernetes Benchmark, the NSA/CISA Kubernetes Hardening Guide, MITRE ATT&CK for
  Containers and the OWASP Kubernetes Top 10 as checklists to find blind spots.
- **Why:** They are the collected experience of real attacks; they catch things we would not think of.
- **Now:** PSS restricted covers part of CIS section 5. Nothing else is mapped.
- **Effort:** M
- **Decision (G3):** **Now.** The checklist for the baseline assessment. Done in lecture 2: the mapping is in
  "Framework mapping" below; Kubescape covers CIS, NSA/CISA and MITRE; OWASP is mapped by hand.

### G4 Review cadence
- **What:** Monthly automated posture report, quarterly manual review of findings and exceptions, yearly
  threat-model refresh.
- **Why:** Security decays: new apps, new exceptions, new CVEs. A rhythm keeps it from drifting.
- **Now:** Ad hoc.
- **Effort:** S
- **Decision (G4):** **Next.** Set up together with the runbooks (G5).

### G5 Incident response runbooks
- **What:** Step-by-step runbooks for the likely incidents: compromised pod, leaked secret, compromised
  node, compromised GitHub account or automation, compromised admin workstation, ransomware on the NAS.
- **Why:** During an incident you don't think clearly. A runbook says how to isolate, what to rotate, how
  to rebuild, and what evidence to keep.
- **Now:** None.
- **Effort:** M
- **Decision (G5):** **Next.** Written once the tools they rely on exist (audit log, quarantine, backups).

### G6 Attack simulation exercises
- **What:** Periodically play attacker: start from a pod (peirates, kube-hunter, Stratus Red Team for
  Kubernetes) or from a leaked credential, and see how far you get and whether alerts fire.
- **Why:** The only real proof that blast-radius limits and detection work.
- **Now:** Never done.
- **Effort:** M
- **Decision (G6):** **Now, then repeated.** A baseline attack run before hardening shows the real paths;
  rerun after each phase as proof.

## I. Identity and access

### I1 Human access to the Kubernetes API
- **What:** Daily admin access via OIDC (short-lived, 2FA-backed). The static admin client-certificate
  kubeconfig becomes break-glass only, stored offline.
- **Why:** A long-lived admin cert on a laptop is cluster-admin forever if the laptop is compromised; it
  can't be revoked without rotating the CA.
- **Now:** OIDC admin binding exists; a static admin context is used daily. Verify cert lifetimes.
- **Effort:** S
- **Decision (I1):** **Now.** This also covers Claude sessions at the desk, which use the static
  context today. They need an OIDC context with a token cache (kubelogin) instead.

### I2 Kubernetes API network exposure
- **What:** The API server only accepts connections from the admin network/Tailscale and the nodes, not
  from the whole LAN.
- **Why:** The API server is the most valuable target; anything on the LAN (IoT, guests) shouldn't even
  reach it.
- **Now:** Verify.
- **Effort:** S
- **Decision (I2):** **Now.** Check now what can reach it; enforce with N4/N8. Checked in lecture 3: the API
  server listens on all interfaces and answers the whole LAN, though only with 401 to anonymous callers.
  Restricting who can reach it is network work (N4, N8).

### I3 RBAC least-privilege audit
- **What:** Review every ClusterRole/Role binding for wildcards, `get secrets` cluster-wide,
  `escalate`/`bind`/`impersonate`, `nodes/proxy`, `pods/exec`, and remove what isn't needed.
- **Why:** These verbs are how one compromised pod becomes cluster-admin. Charts often grant far too much.
- **Now:** trivy-operator RbacAssessment reports exist; never reviewed systematically.
- **Effort:** M
- **Decision (I3):** **Now.**

### I4 ServiceAccount token automount off by default
- **What:** Kyverno mutates every pod to `automountServiceAccountToken: false` unless it opts in.
- **Why:** Most apps never talk to the API, yet each gets a token an attacker can use from inside the pod.
- **Now:** Default automount everywhere.
- **Effort:** S
- **Decision (I4):** **Now.** Audit mode first to find the pods that need a token.

### I5 Authelia hardening
- **What:** WebAuthn/passkeys required for admin (no TOTP fallback), shorter sessions and inactivity
  timeouts, brute-force regulation checked, password policy, notifications on new devices.
- **Why:** Authelia guards almost every UI; its weakest allowed factor is the real strength of the cluster.
- **Now:** Deny-by-default rules, 2FA managed in Git (YubiKeys + TOTP). Verify session settings.
- **Effort:** S
- **Decision (I5):** **Next**, except one part pulled forward to **Now**: require two-factor for the
  admin group and for the Kubernetes OIDC client. The baseline showed the admin rules allow a password
  alone, so I1 (daily kubectl over OIDC) would weaken access until this is fixed. Done in lecture 9,
  before I1.

### I6 Break-glass procedure
- **What:** Documented, tested way back in when the normal path is broken: offline admin kubeconfig,
  Authelia recovery, recovery codes for GitHub/Cloudflare/IdP, the age/secret key, sealed in a known place.
- **Why:** Stronger security makes lock-out more likely. Break-glass is what makes strict controls safe.
- **Now:** Implicit, untested.
- **Effort:** S
- **Decision (I6):** **Next.** Dependency: the offline admin kubeconfig from I1 is its first piece, so it
  must be stored safely when I1 is done. The full procedure must be done before K1 (the age key) and I5.

### I7 External accounts hardening
- **What:** Hardware security keys and no SMS recovery on every account that can change the cluster:
  GitHub, Cloudflare, the IdP, the domain registrar, TrueNAS, the router, Tailscale.
- **Why:** These accounts sit above the cluster: a GitHub or Cloudflare takeover beats every in-cluster control.
- **Now:** Verify per account.
- **Effort:** S
- **Decision (I7):** **Next.**

### I8 Tailscale ACLs and tailnet lock
- **What:** Restrictive tailnet ACLs (which device may reach what), tailnet lock (new nodes must be signed
  by a trusted node), device approval and key expiry.
- **Why:** Tailscale is a second way into the network that bypasses Cloudflare and the router.
- **Now:** Verify.
- **Effort:** S
- **Decision (I8):** **Now.** ACLs managed as code if the API allows it.

### I9 Node SSH access
- **What:** Key-only (hardware-backed) SSH, no root login, no passwords, only from the admin network; or
  Tailscale SSH with ACLs; ultimately no SSH at all (see H4).
- **Why:** Root on a node is root on every pod on it, plus the kubelet's credentials.
- **Now:** Verify.
- **Effort:** S
- **Decision (I9):** **Next.**

### I10 In-cluster admin UIs
- **What:** Headlamp, Hubble UI, Grafana, Pyroscope, Coroot: each acts with the user's own identity (OIDC
  passthrough) or read-only, never with a cluster-admin ServiceAccount behind a login page.
- **Why:** A UI with its own admin token turns any Authelia bypass into cluster-admin.
- **Now:** Headlamp uses OIDC. Verify the others.
- **Effort:** S
- **Decision (I10):** **Now.** Done as part of the RBAC audit (I3).

## N. Network

### N1 Cluster-wide default deny
- **What:** Turn on default deny for ingress and egress in the cluster-wide baseline policy, so a pod with
  no policy gets no traffic instead of all traffic.
- **Why:** Per-app policies only protect apps that have one. A new or forgotten workload is wide open.
- **Now:** Every workload has a CiliumNetworkPolicy, but the baseline has default deny **off**.
- **Effort:** M
- **Decision (N1):** **Now.** Hubble/policy-audit mode first, then enforce.

### N2 Egress allowlists by FQDN
- **What:** Replace `toEntities: world` with `toFQDNs` rules naming the domains each app needs.
- **Why:** Unrestricted egress is how a compromised pod downloads tools and exfiltrates data.
- **Now:** `world` egress where needed; verify how many.
- **Effort:** M
- **Decision (N2):** **Now**, together with N1. Sensitive apps first (Vaultwarden, Authelia, the agent).
  VPN-tunnelled pods (torrent, indexers) can't be FQDN-limited; they stay limited to the VPN endpoint.

### N3 Layer-7 policies for sensitive APIs
- **What:** Cilium HTTP rules (methods, paths) on internal APIs, e.g. only `GET` on read-only paths.
- **Why:** Narrows what a compromised neighbour can do with an allowed connection.
- **Now:** None.
- **Effort:** M
- **Decision (N3):** **Later.** Start with a couple of showcase flows (e.g. dashboard -> media APIs).

### N4 Cilium host firewall
- **What:** Host policies on the nodes themselves: only the ports that must be open, from where they must
  be reachable.
- **Why:** Node services (kubelet, etcd, SSH, exporters) are reachable from the LAN today unless a host
  firewall says otherwise.
- **Now:** Verify.
- **Effort:** M
- **Decision (N4):** **Next.** After N1, and only once break-glass (I6) is in place: a wrong host rule can cut
  off the API.

### N5 Transparent encryption between nodes
- **What:** Cilium WireGuard encryption of all pod-to-pod traffic between nodes.
- **Why:** Anyone on the same LAN segment can otherwise sniff in-cluster traffic, most of which is plain HTTP.
- **Now:** Not configured.
- **Effort:** S
- **Decision (N5):** **Now.** Check MTU and throughput after enabling.

### N6 Workload identity / mutual authentication
- **What:** mTLS or Cilium mutual authentication between services, so a connection proves which workload
  it comes from, not just which IP.
- **Why:** Defends against spoofing and makes policy follow identity.
- **Now:** None.
- **Effort:** L
- **Decision (N6):** **Later.** N5 already gives most of the confidentiality gain.

### N7 Pods cannot reach the LAN
- **What:** Explicitly deny pod egress to home LAN ranges (router, NAS admin UI, IoT, clients) except
  named exceptions.
- **Why:** A compromised pod should not be a foothold into the rest of the home.
- **Now:** Partly covered by per-app policies; verify `world` vs LAN.
- **Effort:** S
- **Decision (N7):** **Now**, alongside N1.

### N8 VLAN segmentation
- **What:** Separate VLANs for cluster nodes, storage, management, clients and IoT, with inter-VLAN
  traffic denied by default at the router.
- **Why:** Limits what a compromised laptop, phone or IoT device can reach, and vice versa.
- **Now:** "Shut down inter-VLAN communication" is open in TODO.
- **Effort:** M
- **Decision (N8):** **Next.** Its own project: node IP changes break Cilium tunnels and DHCP pinning, so
  it needs a migration plan.

### N9 DNS visibility and control
- **What:** Log and alert on DNS from pods (Hubble DNS visibility), block DNS-over-HTTPS bypass, detect
  tunnelling patterns.
- **Why:** DNS is the stealthiest exfiltration and command-and-control channel.
- **Now:** Hubble enabled; DNS visibility not used for alerting.
- **Effort:** M
- **Decision (N9):** **Next.** Visibility comes with N2's DNS proxy; alerts after.

### N10 Alerts on dropped flows
- **What:** Alert when policy drops traffic from unexpected sources (not routine noise).
- **Why:** Drops are often the first sign of lateral movement or scanning.
- **Now:** Hubble metrics exist; verify alerting.
- **Effort:** S
- **Decision (N10):** **Now.** Also used to tune N1.

## E. Edge and internet exposure

### E1 External attack-surface monitoring
- **What:** A scheduled scan from outside (e.g. GitHub Actions running nmap/nuclei against the published
  names and the WAN IP) that alerts on any new open port or hostname.
- **Why:** Proves that only intended things are exposed, and catches accidental exposure fast.
- **Now:** Manual.
- **Effort:** M
- **Decision (E1):** **Next.** Results must stay private: not in public Action logs.

### E2 Cloudflare Access policy review
- **What:** Review every Access application: identity requirements, session length, country, hardware
  key requirement, device posture.
- **Why:** Access is the outermost gate for people.
- **Now:** Allow-admin and bypass policies managed in Git.
- **Effort:** S
- **Decision (E2):** **Now.**

### E3 Machine bypass paths
- **What:** Every Access bypass path authenticates the request itself (HMAC/token), matches the narrowest
  path, and is rate-limited.
- **Why:** Bypass paths are deliberate holes in the outer gate.
- **Now:** Convention exists; verify each path.
- **Effort:** S
- **Decision (E3):** **Now.**

### E4 WAF and rate limiting
- **What:** Managed rulesets, bot protection, rate limits and geo rules at Cloudflare.
- **Why:** Stops commodity attacks before they reach the tunnel.
- **Now:** Custom rules + geo rule pushed from Git every 30 min.
- **Effort:** S
- **Decision (E4):** **Now.** Rate limits on login paths first.

### E5 Security headers and TLS policy
- **What:** HSTS (with preload), CSP where feasible, frame/content-type/referrer headers, TLS 1.2+ with
  modern ciphers as a Traefik default; checked with SSL Labs and Mozilla Observatory.
- **Why:** Cheap protection against downgrade, clickjacking and some XSS.
- **Now:** Verify.
- **Effort:** S
- **Decision (E5):** **Now.** Default Traefik middleware + TLSOption.

### E6 CrowdSec
- **What:** Behaviour-based blocking (log parsing + community blocklists) with bouncers in Traefik and/or
  Cloudflare.
- **Why:** Bans brute-forcing and scanning IPs automatically.
- **Now:** None.
- **Effort:** M
- **Decision (E6):** **Next.** Also covers LAN/Tailscale traffic, which Cloudflare never sees.

### E7 Certificate transparency monitoring
- **What:** Alert when a certificate is issued for one of our domains that we didn't request.
- **Why:** Early sign of domain/DNS compromise or a mis-issuance.
- **Now:** None.
- **Effort:** S
- **Decision (E7):** **Next.**

### E8 No direct origin exposure
- **What:** Prove there is no path to the cluster from the internet except the tunnel: no router port
  forwards, no UPnP, public entrypoint only reachable from the tunnel connectors.
- **Why:** One forgotten forward bypasses Cloudflare and Access entirely.
- **Now:** Public entrypoint limited to the connectors; verify router side.
- **Effort:** S
- **Decision (E8):** **Now.** A one-time check (forwards, UPnP, IPv6 inbound), later automated by E1.

### E9 Domain and email anti-spoofing
- **What:** SPF, DKIM, DMARC `p=reject` on every domain (also those that send no mail), DNSSEC, registrar lock.
- **Why:** Stops phishing as our domain and DNS hijacking.
- **Now:** Verify.
- **Effort:** S
- **Decision (E9):** **Next.**

## W. Workload hardening

### W1 Shrink the PSS exception list
- **What:** Re-justify every Kyverno `policyExclude` entry; remove or narrow each one; give each a review date.
- **Why:** Exceptions (privileged, root, hostPath, NET_ADMIN) are exactly what an attacker looks for.
- **Now:** Restricted profile enforced; around ten exception groups documented.
- **Effort:** M
- **Decision (W1):** **Next.**

### W2 Read-only root filesystem
- **What:** `readOnlyRootFilesystem: true` everywhere, with emptyDirs for paths that must be writable;
  Kyverno audit first, then enforce.
- **Why:** Stops an attacker from dropping binaries or altering the app in place.
- **Now:** Not required.
- **Effort:** M
- **Decision (W2):** **Next.** Same rollout as PSS restricted: audit, fix app by app, enforce.

### W3 User namespaces
- **What:** `hostUsers: false` so root in a container maps to an unprivileged user on the host.
- **Why:** Turns many container escapes into nothing; makes the remaining root exceptions much safer.
- **Now:** Not used. Needs kernel, runtime and Kubernetes support; verify.
- **Effort:** M
- **Decision (W3):** **Next.** Check support first, then pilot on the root-kept apps.

### W4 Custom seccomp and AppArmor profiles
- **What:** Per-app syscall profiles recorded with the Security Profiles Operator, replacing RuntimeDefault.
- **Why:** Shrinks the kernel attack surface to what each app actually uses.
- **Now:** RuntimeDefault everywhere (except documented exceptions).
- **Effort:** L
- **Decision (W4):** **Later.** Start with 2-3 internet-facing apps.

### W5 Sandboxed runtime for risky workloads
- **What:** gVisor or Kata via RuntimeClass for workloads that parse untrusted internet content
  (torrent client, indexers, media servers, IPTV, chat UIs).
- **Why:** A kernel exploit inside a sandbox doesn't reach the host kernel.
- **Now:** None.
- **Effort:** L
- **Decision (W5):** **Later.** Pilot on the torrent client/indexers; GPU workloads excluded.

### W6 Minimal images
- **What:** Prefer distroless/minimal/rootless upstream images over full-distro ones where an equivalent exists.
- **Why:** Fewer CVEs, no shell or package manager for an attacker.
- **Now:** Mixed.
- **Effort:** M
- **Decision (W6):** **Later.** Opportunistic, guided by which images trivy shows to be worst.

### W7 Kyverno best-practice policies beyond PSS
- **What:** Deny the `default` namespace, NodePort and unapproved LoadBalancer Services, `externalIPs`,
  ingress hosts outside our domains, `latest` tags, missing probes.
- **Why:** Each blocks a known misconfiguration or attack (e.g. traffic hijacking via externalIPs).
- **Now:** PSS + namespace/ingress mutations only.
- **Effort:** S
- **Decision (W7):** **Now.** Audit first, then enforce.

### W8 Isolate sensitive workloads
- **What:** Run identity and secret workloads (Authelia, Vaultwarden, Flux) on nodes that don't also run
  internet-facing media/download workloads.
- **Why:** A container escape on a node exposes everything scheduled there.
- **Now:** Placement is by hardware/capacity, not sensitivity.
- **Effort:** M
- **Decision (W8):** **Later.** Depends on node capacity; pair with H9.

### W9 Namespace quotas
- **What:** ResourceQuota/LimitRange per namespace.
- **Why:** Contains resource-exhaustion (crypto-mining, fork bombs) to one namespace.
- **Now:** Per-container limits enforced by convention; no quotas.
- **Effort:** S
- **Decision (W9):** **Later.**

## S. Supply chain

### S1 Pin every image by digest
- **What:** `image: name:tag@sha256:...` everywhere (Renovate keeps them current); Kyverno requires it.
- **Why:** A tag can be repointed by whoever controls the registry; a digest can't.
- **Now:** Some images pinned, many tag-only, our own agent image uses `:latest`.
- **Effort:** M
- **Decision (S1):** **Later.** Partly covered earlier by S3: Kyverno `verifyImages` with `mutateDigest`
  pins signed images to their digest at admission.

### S2 Allowed registries
- **What:** Kyverno only admits images from a list of registries (or only via our pull-through cache).
- **Why:** Blocks typosquats and images from unknown sources.
- **Now:** Any registry.
- **Effort:** S
- **Decision (S2):** **Next.** Audit mode lists today's registries, then enforce.

### S3 Image signature verification
- **What:** Kyverno `verifyImages` checks cosign signatures for images whose publishers sign them
  (Flux, Cilium, Kyverno, our own images, ...).
- **Why:** Proves the image was built by its publisher's pipeline, not pushed by someone who stole a token.
- **Now:** None.
- **Effort:** M
- **Decision (S3):** **Next.** Start with our own image (S5) and the platform components.

### S4 Pull-through cache with gating
- **What:** Harbor (or Zot) as the only registry nodes pull from, with vulnerability scanning and the
  option to block critical CVEs.
- **Why:** One choke point for what enters the cluster; also helps resilience and image-pull speed.
- **Now:** Harbor component exists, disabled.
- **Effort:** M
- **Decision (S4):** **Later.** Memory cost; S2 + S3 give most of the value first.

### S5 Own image builds with provenance
- **What:** Our images get SLSA build provenance (GitHub attestations), cosign signatures, an SBOM and a
  CVE scan in CI, with pinned base images.
- **Why:** Lets the cluster verify our own images are what our CI built.
- **Now:** Built by GitHub Actions, not signed.
- **Effort:** S
- **Decision (S5):** **Next.** Prerequisite for S3 on our own images.

### S6 GitHub Actions hardening
- **What:** Pin actions by SHA, least-privilege `permissions:`, no `pull_request_target` on untrusted
  input, harden-runner egress control, OpenSSF Scorecard.
- **Why:** CI has write access to the repo and registry; compromised actions are a common attack.
- **Now:** Verify.
- **Effort:** S
- **Decision (S6):** **Next.**

### S7 Signed commits verified by Flux
- **What:** Every commit on `main` is signed (people and automation) and Flux's GitRepository `verify`
  refuses unsigned or unknown-key commits.
- **Why:** Someone who gets push access (stolen token, compromised automation) still can't make Flux apply changes.
- **Now:** Not used.
- **Effort:** M
- **Decision (S7):** **Next.** Only after break-glass (I6). A signing mistake stalls all reconciliation.

### S8 Branch protection without automation bypass
- **What:** Even automation goes through a PR and the `validate` check; nothing pushes straight to `main`.
- **Why:** Bypasses are the path of least resistance for an attacker who compromises the automation.
- **Now:** Admins and the agent's GitHub App bypass the ruleset.
- **Effort:** S
- **Decision (S8):** **Next.** The publisher moves to PR + auto-merge on green; admin bypass only as break-glass.

### S9 Update automation guardrails
- **What:** Limit what unattended updates may do: release-age minimum, no zero-touch majors, rendered
  manifest diff checked against policy (no new RBAC, privileges, hostPath, egress) before auto-merge.
- **Why:** A malicious upstream release is applied automatically today if it looks fine in release notes.
- **Now:** Release age 3/7 days; patches automerge; the agent merges majors zero-touch.
- **Effort:** M
- **Decision (S9):** **Next.** Extend the agent's chart pre-render check with a policy check of the diff.

### S10 Secret scanning
- **What:** gitleaks in pre-commit and CI on both repos, plus GitHub push protection.
- **Why:** Catches a secret before it lands in a public repo.
- **Now:** Verify.
- **Effort:** S
- **Decision (S10):** **Next.**

### S11 Signed Helm charts
- **What:** Prefer OCI charts and verify their cosign signatures in Flux where publishers sign them.
- **Why:** Same as S3, for the manifests themselves.
- **Now:** HelmRepositories, no verification.
- **Effort:** M
- **Decision (S11):** **Next.** Together with S3.

### S12 SBOM inventory
- **What:** Keep SBOMs of all running images in a tool like Dependency-Track to answer "are we affected by X?".
- **Why:** Speeds up response to the next big library CVE.
- **Now:** trivy SBOMs disabled (CR size).
- **Effort:** M
- **Decision (S12):** **Later** (no preference given; defaulted).

## K. Secrets and keys

### K1 Encrypt the secrets repo (SOPS + age)
- **What:** Secrets in Git encrypted with age; Flux decrypts in-cluster with a key that lives only in the
  cluster and offline backup.
- **Why:** Today a leak of the private repo (GitHub breach, token, laptop) exposes every credential.
- **Now:** Private repo, plaintext.
- **Effort:** M
- **Decision (K1):** **Next.** After I6, so the age key goes into break-glass storage on day one.

### K2 External secret store
- **What:** OpenBao on a node outside the cluster + External Secrets Operator; enables dynamic,
  short-lived credentials.
- **Why:** Central rotation, audit of every secret read, short lifetimes.
- **Now:** None.
- **Effort:** L
- **Decision (K2):** **Later.** The step after K1.

### K3 Encryption of Secrets at rest in etcd
- **What:** API server encryption provider for Secrets (ideally a KMS plugin).
- **Why:** An etcd backup or disk image otherwise contains every Secret in plaintext.
- **Now:** Verify the k0s configuration.
- **Effort:** S
- **Decision (K3):** **Next.** Must be done before etcd backups (D3) leave the node.

### K4 Credential inventory and rotation
- **What:** List every credential (owner, scope, where used, last rotated) with a rotation interval and
  scripted rotation where possible.
- **Why:** You can't rotate what you don't know about; after an incident you must rotate everything fast.
- **Now:** Implicit in the secrets repo layout.
- **Effort:** M
- **Decision (K4):** **Next.** The inventory goes in the findings register; scripted rotation comes after.

### K5 Least-scope credentials
- **What:** Every API token scoped to the minimum: per-zone Cloudflare tokens, role-limited NAS API key,
  single-repo GitHub App with minimal permissions.
- **Why:** Limits what a leaked token can do.
- **Now:** Verify per token.
- **Effort:** S
- **Decision (K5):** **Next.** With K4.

### K6 Hardware-backed key material
- **What:** The age key, SSH keys and admin credentials on YubiKeys (age-plugin-yubikey, FIDO2 SSH).
- **Why:** Keys can't be copied off a compromised workstation.
- **Now:** YubiKeys used for Authelia.
- **Effort:** M
- **Decision (K6):** **Next.** Together with K1/S7/I9, so each new key is hardware-backed from the start.
  Two keys (primary + backup).

### K7 Vaultwarden hardening
- **What:** Admin page off (or argon2 token, admin-only), signups off, 2FA enforced, encrypted offsite backups.
- **Why:** It holds the keys to everything else.
- **Now:** Verify.
- **Effort:** S
- **Decision (K7):** **Next.**

## H. Hosts, OS and control plane

### H1 CIS benchmark of nodes and control plane
- **What:** kube-bench (one-off, then scheduled) against nodes and the k0s control plane.
- **Why:** Finds kubelet/API server/etcd misconfigurations.
- **Now:** Never run.
- **Effort:** S
- **Decision (H1):** **Now.** Part of the baseline. kube-bench needs host access, so it runs as a short-lived
  Job in a namespace with a temporary, documented PSS exception.
  Done in lecture 3: one script (kept with the findings register) runs the node audit and kube-bench on
  every node, collects the results and cleans up, in under a minute. Two host-only checks (Secure Boot,
  which process owns each port) run over SSH, with the user's OK each time. kube-bench on k0s needs
  triage: about half its control-plane failures are kubeadm file paths that don't exist on k0s, and it
  reads the kubelet's config file rather than the effective config.

### H2 Automated OS patching
- **What:** unattended-upgrades for security updates + kured to drain and reboot one node at a time.
- **Why:** Kernel and OpenSSL CVEs on the nodes are the floor under every container control.
- **Now:** Manual.
- **Effort:** S
- **Decision (H2):** **Next.**

### H3 Kubernetes version currency
- **What:** Policy: at most one minor version behind upstream, patches within a few weeks, checked by an alert.
- **Why:** Kubernetes and runtime CVEs are fixed only in supported versions.
- **Now:** Manual.
- **Effort:** S
- **Decision (H3):** **Next.** Version alert first; upgrades via k0s autopilot or the Talos move.

### H4 Immutable OS
- **What:** Move nodes to Talos Linux: no SSH, no package manager, API-driven upgrades.
- **Why:** Removes whole classes of host attack and drift.
- **Now:** In TODO (k0s migration).
- **Effort:** L
- **Decision (H4):** **Later.** The biggest single hardening step; it solves I9, H2 and H7 by design. Plan
  it after the Next items.

### H5 Full-disk encryption
- **What:** LUKS on every node and the NAS, unlocked by TPM2 or network-bound (Clevis/Tang).
- **Why:** A stolen or discarded disk leaks nothing.
- **Now:** Verify.
- **Effort:** M
- **Decision (H5):** **Later.** Combine with the Talos move (nodes) and the NAS redundancy rebuild (D5).

### H6 Secure Boot and firmware
- **What:** Secure Boot on, BIOS password, firmware updates tracked.
- **Why:** Prevents boot-level persistence.
- **Now:** Verify.
- **Effort:** S
- **Decision (H6):** **Later.** With H4/H5 (Secure Boot + TPM together).

### H7 Kubelet hardening
- **What:** Anonymous auth off, webhook authorization, read-only port off, `seccompDefault: true`,
  `protectKernelDefaults`, certificate rotation.
- **Why:** The kubelet API on each node can run commands in every pod on it.
- **Now:** k0s defaults; verify.
- **Effort:** S
- **Decision (H7):** **Now.** Fix what H1 finds.

### H8 API server hardening
- **What:** Anonymous auth limited, profiling off, NodeRestriction admission, strong TLS settings.
- **Why:** The API server is cluster-admin's front door.
- **Now:** k0s defaults; verify.
- **Effort:** S
- **Decision (H8):** **Now.** Fix what H1 finds.

### H9 Control-plane high availability
- **What:** Three controllers / etcd members.
- **Why:** Mostly availability, but also lets a compromised or failed controller be rebuilt without downtime.
- **Now:** One controller (in TODO).
- **Effort:** L
- **Decision (H9):** **Later.** Plan together with the Talos migration.

### H10 Host intrusion detection
- **What:** auditd rules and file-integrity monitoring on nodes, alerts on logins and changes.
- **Why:** Detects someone on a node outside Kubernetes' view.
- **Now:** None.
- **Effort:** M
- **Decision (H10):** **Later.** Runtime detection (J2) covers much of it from inside.

### H11 Physical security
- **What:** Who can touch the hardware; console, USB, BIOS access.
- **Why:** Physical access beats most controls.
- **Now:** Home environment.
- **Effort:** S
- **Decision (H11):** **Later.**

## D. Data protection and recovery

### D1 Offsite encrypted backups (3-2-1)
- **What:** Client-side encrypted backups (restic/Kopia/Velero) of all app volumes to object storage
  outside the home.
- **Why:** Ransomware, fire, theft or a NAS compromise is unrecoverable today.
- **Now:** Snapshots on the same NAS only; no offsite copy.
- **Effort:** M
- **Decision (D1):** **Later.** Accepted risk until then: losing the NAS (ransomware, theft, disk
  failure) loses all app data, credentials and personal data included.

### D2 Immutable backups
- **What:** Object lock / append-only backup credentials, so nothing in the cluster can delete or alter backups.
- **Why:** Ransomware deletes backups first.
- **Now:** None.
- **Effort:** S
- **Decision (D2):** **Later.** With D1: pick a provider that supports object lock from day one.

### D3 etcd / k0s backups
- **What:** Scheduled k0s backup offsite + restore runbook.
- **Why:** Lets the control plane be rebuilt after loss or compromise.
- **Now:** In TODO.
- **Effort:** S
- **Decision (D3):** **Later.**

### D4 Restore drills
- **What:** Quarterly restore of one app, yearly full rebuild from Git + backups, with time measured.
- **Why:** Untested backups are hopes.
- **Now:** None.
- **Effort:** M
- **Decision (D4):** **Later.** First drill right after the first offsite backup lands.

### D5 NAS redundancy
- **What:** Mirror instead of stripe.
- **Why:** One disk failure currently loses all data. Integrity/availability, not confidentiality.
- **Now:** Stripe, no redundancy.
- **Effort:** M
- **Decision (D5):** **Later.** With D1 and NAS encryption (H5).

### D6 NAS hardening
- **What:** Admin UI only from the management network, 2FA, role-limited API key, NFS exports limited to
  node IPs with root squash, iSCSI CHAP, unused services off, alerts.
- **Why:** The NAS holds every byte of data; it is the ransomware target.
- **Now:** Configured as code; verify these points.
- **Effort:** S
- **Decision (D6):** **Next.** Via the NAS config-as-code.

### D7 Application-consistent database dumps
- **What:** Scheduled dumps (pg_dump etc.) next to crash-consistent snapshots.
- **Why:** A snapshot of a running database may not restore cleanly.
- **Now:** Snapshots only (some apps have their own backups).
- **Effort:** M
- **Decision (D7):** **Later.** With D1.

### D8 Data classification
- **What:** Classify data (secrets, personal, re-creatable) to decide encryption, backup and access tiers.
- **Why:** Not everything deserves the same protection or backup cost.
- **Now:** Informal (TODO lists re-creatable data).
- **Effort:** S
- **Decision (D8):** **Now.** A table in the findings register; it guides D1 and H5 later.

## J. Detection and response

### J1 Kubernetes API audit logging
- **What:** API server audit policy, logs shipped to VictoriaLogs, alerts on exec, Secret reads by
  humans, RBAC changes, new bindings, anonymous requests.
- **Why:** The single most valuable security log in a cluster; today there is no record of who did what.
- **Now:** Verify (none found in the repo).
- **Effort:** M
- **Decision (J1):** **Now.** The foundation for detection, runbooks (G5) and the red-team runs (G6).

### J2 Runtime threat detection
- **What:** eBPF runtime detection (Tetragon or Falco): shells in containers, unexpected binaries,
  sensitive file reads, privilege changes, new outbound destinations; optionally enforcement.
- **Why:** Sees the attack while it happens, inside allowed traffic and allowed pods.
- **Now:** None (in TODO).
- **Effort:** M
- **Decision (J2):** **Next, with Tetragon.** Fits the Cilium stack and can enforce; we write the policies
  ourselves. Needs J1/J3's alert plumbing first.

### J3 Security alerting and dashboard
- **What:** A "Security" Grafana dashboard and alert group: posture, findings, denials, auth events,
  runtime events, routed at high priority.
- **Why:** Security signals must not drown among operational alerts.
- **Now:** Kyverno denial alert, trivy dashboards.
- **Effort:** S
- **Decision (J3):** **Now.** Grows as J1/J2/J4 add sources.

### J4 Authentication event alerting
- **What:** Alerts on failed-login bursts, bans, new 2FA devices, Access denials, SSH logins.
- **Why:** Credential attacks are the most common real-world attack.
- **Now:** Verify.
- **Effort:** S
- **Decision (J4):** **Now.** LogsQL rules on logs that are already collected.

### J5 Exploitability-aware CVE alerting
- **What:** Alert on CVEs that are in CISA KEV or have high EPSS in internet-facing images, instead of raw counts.
- **Why:** Hundreds of CVEs are noise; a few are being exploited now.
- **Now:** trivy counts and dashboards.
- **Effort:** M
- **Decision (J5):** **Next.**

### J6 Honeytokens and canaries
- **What:** Fake credentials (cloud keys, a kubeconfig, a DB URL) planted in the secrets repo, pods and
  the workstation; any use alerts immediately.
- **Why:** Near-zero false positives; catches a breach that slipped past everything else.
- **Now:** None.
- **Effort:** S
- **Decision (J6):** **Next.**

### J7 External dead-man's switch
- **What:** The Watchdog alert goes to an external heartbeat service that alerts when it stops.
- **Why:** An attacker (or an outage) that silences monitoring is otherwise invisible.
- **Now:** In TODO.
- **Effort:** S
- **Decision (J7):** **Next.**

### J8 Off-cluster log retention
- **What:** Security-relevant logs (audit, auth, runtime) copied off the cluster, append-only, kept long enough.
- **Why:** Attackers delete logs; in-cluster logs die with the cluster.
- **Now:** In-cluster only.
- **Effort:** M
- **Decision (J8):** **Later.** Same offsite storage as D1.

### J9 Forensics readiness and containment
- **What:** A quarantine label that isolates a pod (Cilium deny-all) while keeping it running; a runbook
  to capture its filesystem, logs and process list before rebuilding.
- **Why:** Contain first, understand second, rebuild last.
- **Now:** None.
- **Effort:** S
- **Decision (J9):** **Next.** Pairs with the runbooks (G5).

## C. Continuous assurance

### C1 Posture scanning (Kubescape)
- **What:** Kubescape operator: continuous NSA/MITRE/CIS posture, attack-path view, Headlamp plugin.
- **Why:** A running score that shows drift and what to fix next.
- **Now:** None (in TODO).
- **Effort:** S
- **Decision (C1):** **CLI scan Now** (baseline). **Operator Next**, decided after comparing it with trivy (C2).
  Lecture 2: scores are only comparable over time with an exceptions file that sets aside verified
  false failures (`ignore`) and marks accepted risks (`alertOnly`); the file lives with the findings
  register until the operator makes it a cluster resource.

### C2 trivy-operator scope
- **What:** Decide what trivy keeps (image CVEs, exposed secrets) and what moves to Kubescape (config, RBAC, compliance).
- **Why:** Two scanners with overlapping reports means double noise and memory.
- **Now:** trivy runs vuln, config-audit, RBAC, exposed-secret scans.
- **Effort:** S
- **Decision (C2):** **Next.** Based on the baseline results of both.

### C3 Security checks in CI
- **What:** On every PR: render with kustomize, run Kyverno CLI against the rendered manifests (catch
  denials before merge), kube-linter/Polaris, trivy config, gitleaks.
- **Why:** Shift left: insecure changes fail before they reach the cluster.
- **Now:** `validate` renders and checks; verify what exactly.
- **Effort:** M
- **Decision (C3):** **Next.** Fits with S8 and S10.

### C4 Policy tests
- **What:** Kyverno CLI test suites with good and bad example resources for every policy.
- **Why:** A chart upgrade or edit can silently weaken a policy (it has happened).
- **Now:** None.
- **Effort:** S
- **Decision (C4):** **Next.**

### C5 Posture trend dashboard
- **What:** Score and open findings over time in Grafana.
- **Why:** Shows whether things get better or worse.
- **Now:** None.
- **Effort:** S
- **Decision (C5):** **Next.**

### C6 Scheduled automated security review
- **What:** The claude-agent runs a weekly security review: reads reports, updates the findings register,
  proposes fixes.
- **Why:** Keeps the review cadence (G4) without relying on memory.
- **Now:** Health reviews exist, not security-focused.
- **Effort:** S
- **Decision (C6):** **Next.** After G2 and C1, and after A1: an agent that reviews security should not
  itself hold cluster-admin.

## A. Automation and AI agent security

### A1 Agent blast radius
- **What:** Replace the agent's cluster-admin binding with a read-only role plus narrowly scoped write
  verbs; separate identities for review and for acting.
- **Why:** The agent processes untrusted text; whatever it can do, a successful prompt injection can do.
- **Now:** cluster-admin.
- **Effort:** M
- **Decision (A1):** **Now.** The audit log (J1) shows which verbs it actually uses.

### A2 Prompt-injection guardrails
- **What:** Treat release notes, logs, PR bodies and web pages as hostile input; zero-touch only for
  change types that a deterministic check approves (policy-checked diff, see S9); everything else asks.
- **Why:** An upstream release note can contain instructions aimed at the agent.
- **Now:** `policy.ts` gates commands; updates are zero-touch.
- **Effort:** M
- **Decision (A2):** **Next.** Built together with S9 (same mechanism).

### A3 Approval channel integrity
- **What:** Approval topic requires auth to read and publish, tokens unguessable, single-use and expiring.
- **Why:** If someone can read or answer the approval channel, they can approve the agent's actions.
- **Now:** Tokenised answer URLs, 4h expiry; verify topic access control.
- **Effort:** S
- **Decision (A3):** **Now.**

### A4 Agent egress allowlist
- **What:** The agent pod may only reach the API endpoints it needs (model API, GitHub, registries, the cluster).
- **Why:** Limits exfiltration if the agent is subverted.
- **Now:** Verify.
- **Effort:** S
- **Decision (A4):** **Now.** Part of N2.

### A5 Agent audit trail
- **What:** Every agent action is logged and attributable (run id in commit trailers, transcript kept).
- **Why:** After an incident you must know what the agent did and why.
- **Now:** Transcripts in the UI; verify retention.
- **Effort:** S
- **Decision (A5):** **Now.**

## P. Home network perimeter and workstation

### P1 Router hardening
- **What:** Router admin only from the management network, 2FA, updates, config backup as code.
- **Why:** The router decides what reaches what.
- **Now:** Verify.
- **Effort:** S
- **Decision (P1):** **Next.** With N8; both touch the router.

### P2 Network IDS/IPS
- **What:** Suricata/Zenarmor/CrowdSec on the router.
- **Why:** Sees threats on the wire, including from non-cluster devices.
- **Now:** Verify.
- **Effort:** M
- **Decision (P2):** **Later.** Detection mode first, after the VLANs exist.

### P3 IoT isolation
- **What:** IoT devices in their own VLAN; only Home Assistant may reach them.
- **Why:** IoT firmware is the weakest code in the house.
- **Now:** Verify.
- **Effort:** M
- **Decision (P3):** **Next.** Part of the VLAN project (N8).

### P4 Admin workstation hardening
- **What:** The machine holding the admin kubeconfig and secrets repo: disk encryption, updates, separate
  user/profile for admin work, hardware keys.
- **Why:** It is effectively cluster-admin; compromising it beats every in-cluster control.
- **Now:** Verify.
- **Effort:** S
- **Decision (P4):** **Next.** With I1/K6.

---

## Decision log

| Date | Decision |
|---|---|
| 2026-11-23 | First review: threat model set; all 106 controls prioritised (33 Now, 48 Next, 25 Later, 0 dropped). |

## Roadmap

The Now items are ordered so that each phase builds on the last: measure first, then add visibility,
and only then enforce, so every enforcement step can be watched and tuned.

### Now

1. **Baseline (read-only).** G2 findings register, G3 framework checklists, D8 data classification,
   H1 kube-bench, C1 Kubescape CLI scan, G6 first attack-simulation run. One-off checks: I2 API
   exposure, E8 origin exposure, A3 approval channel.
2. **Visibility before enforcement.** J1 API audit log, J3 security dashboard and alert group, J4 auth
   alerts, N10 dropped-flow alerts.
3. **Blast radius.** I1 OIDC for daily access (the static cert goes offline), I3 RBAC audit with I10
   admin UIs, I4 token automount off, A1 scoped agent RBAC, A5 agent audit trail, I8 Tailscale ACLs,
   H7/H8 fixes from kube-bench.
4. **Network.** N5 WireGuard, N1 cluster-wide default deny with N7 no-LAN egress, N2 FQDN egress
   (A4 agent first).
5. **Edge and admission.** E2/E3 Access and bypass review, E4/E5 WAF, headers and TLS policy, W7 Kyverno
   best-practice policies.
6. **Prove it.** Rerun G6 and compare with the first run.

### Next

- **Keys and recovery:** I6 break-glass (first) -> K1 SOPS, K3 etcd encryption, K4/K5 credential
  inventory and scopes, K6 hardware keys, K7 Vaultwarden, I7 external accounts, I5 Authelia, D6 NAS.
- **Supply chain:** S2 allowed registries, S5 -> S3/S11 signatures, S6 Actions, S7 signed commits,
  S8 no bypass, S9 + A2 update guardrails, S10 secret scanning, C3/C4 CI and policy tests.
- **Hosts:** H2 patching, H3 version currency, I9 SSH, N4 host firewall.
- **Network and home:** N8 VLANs with P1 router and P3 IoT, N9 DNS, E1 attack-surface monitoring,
  E6 CrowdSec, E7 CT monitoring, E9 domain anti-spoofing, P4 workstation.
- **Workloads:** W1 PSS exceptions, W2 read-only rootfs, W3 user namespaces.
- **Detection and process:** J2 Tetragon, J5 KEV/EPSS, J6 canaries, J7 dead-man's switch, J9 quarantine,
  G4/G5 cadence and runbooks, C1 Kubescape operator, C2 trivy scope, C5 trend, C6 weekly agent review.

### Later

- **Platform rebuild (one project):** H4 Talos, H5 disk encryption, H6 Secure Boot, H9 control-plane HA,
  W8 sensitive-workload isolation.
- **Backups (one project):** D1 offsite, D2 immutable, D3 etcd, D4 drills, D5 NAS mirror, D7 DB dumps,
  J8 off-cluster logs.
- **Deeper hardening:** N3 L7 policies, N6 mutual auth, W4 seccomp profiles, W5 sandboxed runtime,
  W6 minimal images, W9 quotas, S1 digest pinning, S4 registry cache, S12 SBOM inventory,
  K2 OpenBao, H10 host IDS, H11 physical, P2 network IDS.

### Accepted risks (until the Later items land)

- **No offsite backup** (D1-D4): ransomware, theft or loss of the NAS loses all app data, credentials
  and personal data included.
- **Tag-based images** (S1): a repointed tag is pulled unverified, except for images covered by S3.
