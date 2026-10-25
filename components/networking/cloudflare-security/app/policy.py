"""
Desired Cloudflare security state, applied to every zone in ZONES by reconcile.py.

Each phase below replaces the zone's whole entrypoint ruleset for that phase:
rules added in the dashboard are removed on the next run. Hosts that are not
in a zone simply never match, so one rule set serves both zones.

Free plan limits: 5 custom rules, 1 rate limiting rule (10 s period and
mitigation, counted per IP and data center). DDoS protection (L3/4 and HTTP)
is always on and left at Cloudflare's defaults.
"""

import os

DOMAIN = os.environ["DOMAIN"]
AUTH = f"auth.{DOMAIN}"
STREAM = f"stream.{DOMAIN}"
WEBHOOK = f"flux-webhook.{DOMAIN}"

# EU + EEA (ISO 3166-1 alpha-2)
ALLOWED_COUNTRIES = [
    "AT", "BE", "BG", "CY", "CZ", "DE", "DK", "EE", "ES", "FI", "FR", "GR", "HR",
    "HU", "IE", "IT", "LT", "LU", "LV", "MT", "NL", "PL", "PT", "RO", "SE", "SI",
    "SK", "IS", "LI", "NO",
]

# Authelia endpoints called by machines (Tailscale's control plane): stay
# reachable from anywhere; they authenticate with client credentials/tokens
OIDC_MACHINE = (
    f'(http.host eq "{AUTH}" and (starts_with(http.request.uri.path, "/.well-known/")'
    ' or http.request.uri.path in {"/jwks.json" "/api/oidc/token" "/api/oidc/userinfo"}))'
)


def q(values):
    return "{" + " ".join(f'"{v}"' for v in values) + "}"


def custom_rules(github_hooks):
    """http_request_firewall_custom; github_hooks: GitHub webhook CIDRs."""
    return [
        {
            "description": "flux-webhook: only GitHub POSTs to /hook",
            "expression": (
                f'http.host eq "{WEBHOOK}" and not (http.request.method eq "POST"'
                ' and http.request.uri.path eq "/hook"'
                f' and ip.src in {{{" ".join(github_hooks)}}})'
            ),
            "action": "block",
        },
        {
            "description": "Login hosts: EU/EEA only (machine OIDC endpoints exempt)",
            "expression": (
                f"http.host in {q([AUTH, STREAM])}"
                f" and not ip.src.country in {q(ALLOWED_COUNTRIES)}"
                f" and not {OIDC_MACHINE}"
            ),
            "action": "block",
        },
        {
            "description": "Scanner paths (nothing here serves PHP, dotfiles or WordPress)",
            "expression": (
                '(http.request.uri.path contains "/.env"'
                ' or http.request.uri.path contains "/.git"'
                ' or starts_with(http.request.uri.path, "/wp-")'
                ' or http.request.uri.path contains "phpmyadmin"'
                ' or ends_with(http.request.uri.path, ".php"))'
            ),
            "action": "block",
        },
        {
            "description": "Unused HTTP methods",
            "expression": 'http.request.method in {"TRACE" "TRACK" "CONNECT"}',
            "action": "block",
        },
    ]


RATELIMIT_RULES = [
    {
        # Authelia also bans an account after 3 failed logins; this stops floods
        "description": "Authelia login and token endpoints: 10 requests / 10 s per IP",
        "expression": (
            'http.request.uri.path in {"/api/firstfactor" "/api/secondfactor/totp"'
            ' "/api/oidc/token" "/api/reset-password/identity/start"}'
        ),
        "action": "block",
        "ratelimit": {
            "characteristics": ["cf.colo.id", "ip.src"],
            "period": 10,
            "requests_per_period": 10,
            "mitigation_timeout": 10,
        },
    },
]

# Zone settings (PATCH /zones/<id>/settings); anything not listed is left alone.
# SSL mode is not set: tunnel traffic does not use it, other origins might.
SETTINGS = {
    "always_use_https": "on",
    "automatic_https_rewrites": "on",
    "min_tls_version": "1.2",
    "tls_1_3": "on",
    "security_level": "medium",
    "browser_check": "on",
    "security_header": {
        "strict_transport_security": {
            "enabled": True,
            "max_age": 15552000,  # 180 days
            "include_subdomains": False,
            "preload": False,
            "nosniff": True,
        }
    },
}
