"""Strip the " Collection" suffix from Jellyfin collection names.

Jellyfin names automatic collections after the TMDB collection ("The Matrix Collection").
Each such collection is renamed and its Name field locked, so metadata refreshes keep
the new name. Collections whose name is already locked are left alone: that name was
set by hand.
"""
import json
import os
import urllib.parse
import urllib.request

JELLYFIN = "http://jellyfin.jellyfin.svc.cluster.local:8096"
SUFFIX = " Collection"
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"


def call(path, method="GET", body=None, **params):
    url = JELLYFIN + path + ("?" + urllib.parse.urlencode(params) if params else "")
    headers = {"Authorization": f'MediaBrowser Token="{os.environ["JELLYFIN_API_KEY"]}"'}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, method=method, headers=headers, data=data)
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else None


def main():
    admin = next(u for u in call("/Users") if u["Policy"]["IsAdministrator"])
    boxsets = call("/Items", IncludeItemTypes="BoxSet", Recursive="true")["Items"]
    for boxset in boxsets:
        name = boxset["Name"]
        if not name.endswith(SUFFIX) or name == SUFFIX.strip():
            continue
        # The update endpoint replaces the whole item, so send back the full item
        item = call(f"/Items/{boxset['Id']}", userId=admin["Id"])
        locked = item.get("LockedFields") or []
        if "Name" in locked:
            print(f"keep {name!r}: name is locked", flush=True)
            continue
        new_name = name[: -len(SUFFIX)]
        print(f"{'would rename' if DRY_RUN else 'renaming'} {name!r} -> {new_name!r}", flush=True)
        if DRY_RUN:
            continue
        item["Name"] = new_name
        item["LockedFields"] = locked + ["Name"]
        call(f"/Items/{boxset['Id']}", method="POST", body=item)


if __name__ == "__main__":
    main()
