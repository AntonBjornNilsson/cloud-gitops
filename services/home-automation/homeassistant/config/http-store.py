"""Write the reverse-proxy settings into Home Assistant's stored HTTP config.

Since 2026.10 Home Assistant imports `http:` from YAML only once, as a "pending"
config that must be confirmed in the UI within 5 minutes or it is reverted (and
the YAML ignored from then on). Run before every start so Git stays the source
of truth: trust X-Forwarded-For from TRUSTED_PROXIES (Traefik's pod IP changes),
keep any other HTTP settings made in the UI.
"""

import json
import os
import sys
from datetime import datetime, timezone

from homeassistant.components.http.config import HTTP_STORAGE_SCHEMA

PATH = "/config/.storage/http"

proxies = [p for p in os.environ.get("TRUSTED_PROXIES", "").split(",") if p]
if not proxies:
    print("TRUSTED_PROXIES not set, skipping")
    sys.exit(0)

if os.path.exists(PATH):
    with open(PATH) as f:
        store = json.load(f)
else:
    store = {
        "version": 2,
        "minor_version": 2,
        "key": "http",
        "data": {
            "stable": dict(HTTP_STORAGE_SCHEMA({})),
            "pending": None,
        },
    }

data = store["data"]
stable = data["stable"]
stable["use_x_forwarded_for"] = True
stable["trusted_proxies"] = proxies
stable.setdefault("created_at", datetime.now(timezone.utc).isoformat())
stable["error"] = None
stable["error_message"] = None
data["pending"] = None
data["yaml_migration_done"] = True

os.makedirs(os.path.dirname(PATH), exist_ok=True)
with open(PATH + ".tmp", "w") as f:
    json.dump(store, f, indent=2)
os.chmod(PATH + ".tmp", 0o600)
os.replace(PATH + ".tmp", PATH)
print(f"trusted_proxies: {proxies}")
