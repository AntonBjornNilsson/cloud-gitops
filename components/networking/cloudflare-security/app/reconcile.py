"""
Push policy.py to Cloudflare: one entrypoint ruleset per phase and a set of zone
settings, for every zone in ZONES (comma separated). Writes only what differs
from the live state; exits non-zero on any error (KubeJobFailed alerts).

DRY_RUN=1 prints the planned rulesets without touching Cloudflare (no token needed).
"""

import json
import os
import sys
import urllib.error
import urllib.request

import policy

API = "https://api.cloudflare.com/client/v4"
TOKEN = os.environ.get("CLOUDFLARE_API_TOKEN", "")
ZONES = [z.strip() for z in os.environ["ZONES"].split(",") if z.strip()]
DRY_RUN = os.environ.get("DRY_RUN") == "1"
RULE_KEYS = ("description", "expression", "action", "ratelimit", "enabled")


def call(method, path, body=None, base=API, auth=True):
    req = urllib.request.Request(base + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "homelab-cloudflare-security")
    if auth:
        req.add_header("Authorization", f"Bearer {TOKEN}")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            data = json.load(e)
        except ValueError:
            data = {"errors": [{"message": e.reason}]}
        if e.code == 404:
            return None
        raise SystemExit(f"{method} {path}: HTTP {e.code} {json.dumps(data.get('errors'))}")


def github_hooks():
    meta = call("GET", "/meta", base="https://api.github.com", auth=False)
    hooks = meta.get("hooks") or []
    if not hooks:
        raise SystemExit("GitHub /meta returned no hook ranges")
    return sorted(hooks)


def normalize(rules):
    out = []
    for r in rules:
        r = {k: r[k] for k in RULE_KEYS if k in r}
        r.setdefault("enabled", True)
        if "ratelimit" in r:
            r["ratelimit"] = {k: r["ratelimit"][k] for k in
                              ("characteristics", "period", "requests_per_period",
                               "mitigation_timeout") if k in r["ratelimit"]}
            r["ratelimit"]["characteristics"] = sorted(r["ratelimit"]["characteristics"])
        out.append(r)
    return out


def sync_phase(zone_id, zone, phase, rules):
    want = normalize(rules)
    live = call("GET", f"/zones/{zone_id}/rulesets/phases/{phase}/entrypoint")
    have = normalize(live["result"].get("rules", [])) if live else []
    if have == want:
        print(f"{zone} {phase}: up to date ({len(want)} rules)")
        return
    call("PUT", f"/zones/{zone_id}/rulesets/phases/{phase}/entrypoint",
         {"description": "Managed by cloud-gitops (cloudflare-security)", "rules": want})
    print(f"{zone} {phase}: updated ({len(have)} -> {len(want)} rules)")


def sync_settings(zone_id, zone):
    live = {s["id"]: s["value"] for s in call("GET", f"/zones/{zone_id}/settings")["result"]}
    changes = []
    for key, value in policy.SETTINGS.items():
        cur = live.get(key)
        if isinstance(value, dict) and isinstance(cur, dict):
            # Compare only the keys we set (Cloudflare adds others)
            same = all(cur.get(k) == v if not isinstance(v, dict)
                       else all((cur.get(k) or {}).get(kk) == vv for kk, vv in v.items())
                       for k, v in value.items())
        else:
            same = cur == value
        if not same:
            changes.append({"id": key, "value": value})
    if changes:
        call("PATCH", f"/zones/{zone_id}/settings", {"items": changes})
        print(f"{zone} settings: updated {', '.join(c['id'] for c in changes)}")
    else:
        print(f"{zone} settings: up to date")


def main():
    phases = {
        "http_request_firewall_custom": policy.custom_rules(github_hooks()),
        "http_ratelimit": policy.RATELIMIT_RULES,
    }
    if DRY_RUN:
        print(json.dumps({"zones": ZONES, "phases": phases, "settings": policy.SETTINGS}, indent=2))
        return
    if not TOKEN:
        raise SystemExit("CLOUDFLARE_API_TOKEN is empty")
    for zone in ZONES:
        found = call("GET", f"/zones?name={zone}")["result"]
        if not found:
            raise SystemExit(f"zone {zone} not visible to the token")
        zone_id = found[0]["id"]
        for phase, rules in phases.items():
            sync_phase(zone_id, zone, phase, rules)
        sync_settings(zone_id, zone)


if __name__ == "__main__":
    main()
    sys.stdout.flush()
