# cloudflare-security

Cloudflare's edge security for both zones, from Git. cfgate (`../cfgate`) manages tunnel, DNS and
Access; this component manages what sits in front of them.

A CronJob (every 30 min) runs `app/reconcile.py`, which pushes `app/policy.py`:

| Phase / setting | What |
|---|---|
| Custom rules (`http_request_firewall_custom`) | flux-webhook only accepts GitHub POSTs to `/hook` (ranges from GitHub's `/meta`, refreshed every run); login hosts (auth, stream) EU/EEA only, Authelia's machine OIDC endpoints exempt; scanner paths; TRACE/TRACK/CONNECT |
| Rate limiting (`http_ratelimit`) | Authelia login, TOTP, token and password-reset endpoints: 10 requests / 10 s per IP |
| Zone settings | Always HTTPS, HTTPS rewrites, TLS >= 1.2, TLS 1.3, security level medium, browser integrity check, HSTS (180 days, no subdomains, no preload) |

Each phase's ruleset is replaced as a whole, so rules added in the dashboard disappear on the next
run. Only differences are written; a failed run fails the Job (`KubeJobFailed` alert).

Left alone on purpose:
- **DDoS protection** (L3/4 and HTTP) is always on, on every plan, at Cloudflare's defaults.
- **Bot Fight Mode**: on the Free plan it cannot be skipped per path, so it would challenge GitHub
  webhooks, Tailscale's OIDC calls and the Jellyfin apps.
- **SSL mode**: tunnel traffic does not use it, other origins in the zones might.
- **Free managed ruleset**: Cloudflare deploys and updates it automatically.

Free plan limits: 5 custom rules (4 used), 1 rate limiting rule (period and mitigation fixed at 10 s).

## Changing rules

Edit `app/policy.py`, then check the result locally (no token needed):

```sh
cd app && DRY_RUN=1 DOMAIN=example.com ZONES=example.com python3 reconcile.py
```

Commit and push, then run it now instead of waiting for the schedule:

```sh
kubectl --context=<admin> -n cloudflare-security create job --from=cronjob/cloudflare-security manual-$(date +%s)
kubectl --context=<admin> -n cloudflare-security logs -f job/<name>
```

The API token (`cloudflare_security_api_token`, in `cloudflare-substitutions` in the secrets repo)
needs Zone > Zone WAF: Edit and Zone > Zone Settings: Edit on both zones.
