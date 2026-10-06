# Traefik Ingress & Authentication Flow

Traefik serves as the primary ingress controller with defense-in-depth authentication.

## 3-Tier Security Architecture

```
[External Request: https://<service>.$domain$]
                       │
                       ▼
┌────────────────────────────────────────────────────────┐
│ Tier 1: Cloudflare Access Edge (Outer Perimeter)       │
│ - *.$domain$ intercepts external traffic           │
│ - Enforces Google OAuth allowlist before cluster entry │
│ - Forwards verified requests over Cloudflare Tunnel    │
└──────────────────────┬─────────────────────────────────┘
                       │
                       ▼
┌────────────────────────────────────────────────────────┐
│ Tier 2: Traefik + Authelia ForwardAuth (Reverse Proxy) │
│ - Kyverno policy auto-injects middleware:              │
│   `authelia-authelia-forward-auth@kubernetescrd`       │
│ - Traefik queries Authelia via INTERNAL cluster RPC:   │
│   `http://authelia.authelia.svc.cluster.local/api/authz/forward-auth`
│ - Unauthenticated: 302 to https://auth.$domain$    │
│ - Authelia session cookie domain: `.$domain$`      │
│ - Authenticated: injects `Remote-User`, `Remote-Email` │
└──────────────────────┬─────────────────────────────────┘
                       │
                       ▼
┌────────────────────────────────────────────────────────┐
│ Tier 3: Application Layer                              │
│ - Case-by-case: Authelia OIDC SSO (Grafana, Headlamp)  │
│   or native app authentication (Vaultwarden, etc.)     │
└────────────────────────────────────────────────────────┘
```

## Key Invariants

1. **Unified Domain (`*.$domain$`)**:
   Both Cloudflare Access (`CF_Authorization`) and Authelia (`authelia_session`) share `.$domain$`. Cross-domain cookie splitting is strictly avoided to prevent browser redirect loops (RFC 6265).
2. **100% In-Cluster ForwardAuth RPC**:
   Traefik verifies sessions directly against `authelia.authelia.svc.cluster.local:80`. Subrequests never hairpin through WAN or Cloudflare Access.
3. **Bypass / Opt-Out**:
   To disable Authelia forward-auth on a specific ingress, set the label:
   ```yaml
   metadata:
     labels:
       enable-oauth: "false"
   ```
4. **LAN-only by default**:
   `websecure` (the LoadBalancer, reached from the LAN and over the Tailscale subnet router) is the default entrypoint, so every route is private unless it opts in.
   Internet traffic only arrives through the cloudflared tunnel, whose origin is the ClusterIP Service `traefik-public` (entrypoint `public`, reachable only from the `cloudflare` namespace).
   To make an ingress internet-facing, add:
   ```yaml
   metadata:
     annotations:
       traefik.ingress.kubernetes.io/router.entrypoints: websecure,public
   ```
