"""
Make Harbor match the desired state below through its API, so nothing is set up by
hand in the UI: proxy-cache registries and projects, the project for our own images,
its push robot account and the garbage collection schedule. Creates or updates only
what differs; never deletes. Exits non-zero on any error (KubeJobFailed alerts).

The proxy projects must match the node mirrors in registry-mirror.yaml.
"""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = os.environ.get("HARBOR_URL", "http://harbor-core.harbor.svc") + "/api/v2.0"
ADMIN_PASSWORD = os.environ["HARBOR_ADMIN_PASSWORD"]
DOCKERHUB_USER = os.environ.get("DOCKERHUB_USERNAME", "")
DOCKERHUB_TOKEN = os.environ.get("DOCKERHUB_TOKEN", "")
PUSH_ROBOT_SECRET = os.environ.get("PUSH_ROBOT_SECRET", "")

# Proxy cache: project name -> upstream registry endpoint (Harbor adapter type + URL)
PROXIES = {
    "dockerhub": {"type": "docker-hub", "url": "https://hub.docker.com"},
    "ghcr": {"type": "github-ghcr", "url": "https://ghcr.io"},
    "quay": {"type": "quay", "url": "https://quay.io"},
    "k8s": {"type": "docker-registry", "url": "https://registry.k8s.io"},
}

# Our own images: harbor.<domain>/homelab/<image>:<tag>. Public (LAN-only host) so
# the cluster pulls without imagePullSecrets; pushing needs the robot account.
OWN_PROJECT = "homelab"
PUSH_ROBOT = "push"

# Weekly GC frees the blobs of expired proxy-cache artifacts (Harbor drops cached
# artifacts not pulled for 7 days) and of deleted own images. Harbor cron has seconds.
GC_CRON = "0 0 4 * * 6"

AUTH = "Basic " + base64.b64encode(f"admin:{ADMIN_PASSWORD}".encode()).decode()


def call(method, path, body=None, ok_missing=False):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", AUTH)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        if ok_missing and e.code == 404:
            return None
        sys.exit(f"{method} {path}: HTTP {e.code}: {e.read().decode(errors='replace')}")


def wait_healthy():
    for _ in range(60):
        try:
            with urllib.request.urlopen(API + "/health", timeout=10) as resp:
                if json.loads(resp.read()).get("status") == "healthy":
                    return
        except (urllib.error.URLError, OSError, ValueError):
            pass
        time.sleep(10)
    sys.exit("Harbor did not become healthy")


def ensure_registry(name, spec):
    want = {"name": name, "type": spec["type"], "url": spec["url"], "insecure": False}
    if spec["type"] == "docker-hub" and DOCKERHUB_USER and DOCKERHUB_TOKEN:
        # Authenticated pulls get the higher Docker Hub limit
        want["credential"] = {"type": "basic", "access_key": DOCKERHUB_USER,
                              "access_secret": DOCKERHUB_TOKEN}
    existing = [r for r in call("GET", f"/registries?q=name%3D{name}") or [] if r["name"] == name]
    if not existing:
        call("POST", "/registries", want)
        print(f"registry {name}: created")
    elif "credential" in want or existing[0]["url"] != spec["url"]:
        # The secret is write-only, so the credential is re-sent every run
        call("PUT", f"/registries/{existing[0]['id']}",
             {"url": spec["url"], **({"credential_type": "basic",
                                      "access_key": DOCKERHUB_USER,
                                      "access_secret": DOCKERHUB_TOKEN} if "credential" in want else {})})
        print(f"registry {name}: updated")
    return [r for r in call("GET", f"/registries?q=name%3D{name}") if r["name"] == name][0]["id"]


def ensure_project(name, registry_id=None):
    project = call("GET", f"/projects/{name}", ok_missing=True)
    if project is None:
        body = {"project_name": name, "metadata": {"public": "true"}, "storage_limit": -1}
        if registry_id is not None:
            body["registry_id"] = registry_id
        call("POST", "/projects", body)
        print(f"project {name}: created")
    elif project.get("metadata", {}).get("public") != "true":
        call("PUT", f"/projects/{name}", {"metadata": {"public": "true"}})
        print(f"project {name}: made public")


def ensure_push_robot():
    if not PUSH_ROBOT_SECRET:
        print("robot: PUSH_ROBOT_SECRET not set, skipped")
        return
    full = f"robot${OWN_PROJECT}+{PUSH_ROBOT}"
    robots = [r for r in call("GET", "/robots?page_size=100") or [] if r["name"] == full]
    if robots:
        robot_id = robots[0]["id"]
    else:
        robot_id = call("POST", "/robots", {
            "name": PUSH_ROBOT, "level": "project", "duration": -1, "disable": False,
            "description": "Pushes own images (managed by harbor-config)",
            "permissions": [{"kind": "project", "namespace": OWN_PROJECT, "access": [
                {"resource": "repository", "action": "push"},
                {"resource": "repository", "action": "pull"},
                {"resource": "tag", "action": "create"},
            ]}],
        })["id"]
        print(f"robot {full}: created")
    # Pin the secret to the one in the secrets repo (idempotent)
    call("PATCH", f"/robots/{robot_id}", {"secret": PUSH_ROBOT_SECRET})


def ensure_gc_schedule():
    want = {"schedule": {"type": "Custom", "cron": GC_CRON},
            "parameters": {"delete_untagged": True, "workers": 1}}
    current = call("GET", "/system/gc/schedule", ok_missing=True)
    if not current or not current.get("schedule"):
        call("POST", "/system/gc/schedule", want)
        print("gc schedule: created")
    elif current["schedule"].get("cron") != GC_CRON:
        call("PUT", "/system/gc/schedule", want)
        print("gc schedule: updated")


def main():
    wait_healthy()
    call("PUT", "/configurations", {"self_registration": False})
    for name, spec in PROXIES.items():
        ensure_project(name, ensure_registry(name, spec))
    ensure_project(OWN_PROJECT)
    ensure_push_robot()
    ensure_gc_schedule()
    print("harbor-config: in sync")


if __name__ == "__main__":
    main()
