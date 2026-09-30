#!/usr/bin/env python3
"""
Longhorn Backup Sync to GitOps
Discovers the latest completed backup for all PVCs in the cluster and
generates/updates declarative Longhorn Volume and PersistentVolume manifests
in GitOps for automated disaster recovery bootstrap.
"""

import os
import sys
import json
import base64
import urllib.request
import urllib.error
import ssl
import re
import subprocess
from datetime import datetime, timezone

TARGET_FILE_PATH = "components/storage/longhorn/config/restore/volumes.yaml"
GITHUB_REPO = os.environ.get("GITHUB_REPO", "AntonBjornNilsson/cloud-gitops")
GITHUB_BRANCH = os.environ.get("GITHUB_BRANCH", "main")
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")

# In-cluster Kubernetes API detection
K8S_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
K8S_CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
K8S_API_URL = "https://kubernetes.default.svc"


def get_k8s_resources_in_cluster(endpoint):
    with open(K8S_TOKEN_PATH, "r") as f:
        token = f.read().strip()

    ctx = ssl.create_default_context(cafile=K8S_CA_PATH)
    req = urllib.request.Request(
        f"{K8S_API_URL}{endpoint}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json"
        }
    )
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))["items"]


def get_k8s_resources_kubectl(cmd_args):
    raw = subprocess.check_output(["kubectl"] + cmd_args + ["-o", "json"])
    return json.loads(raw)["items"]


def fetch_cluster_data():
    in_cluster = os.path.exists(K8S_TOKEN_PATH)
    if in_cluster:
        print("[*] Running inside Kubernetes cluster, querying API server directly...")
        pvcs = get_k8s_resources_in_cluster("/api/v1/persistentvolumeclaims")
        pvs = get_k8s_resources_in_cluster("/api/v1/persistentvolumes")
        backups = get_k8s_resources_in_cluster("/apis/longhorn.io/v1beta2/namespaces/longhorn-system/backups")
    else:
        print("[*] Running outside cluster, querying via kubectl...")
        pvcs = get_k8s_resources_kubectl(["get", "pvc", "-A"])
        pvs = get_k8s_resources_kubectl(["get", "pv"])
        backups = get_k8s_resources_kubectl(["get", "backup.longhorn.io", "-n", "longhorn-system"])

    return pvcs, pvs, backups


def generate_restore_yaml(pvcs, pvs, backups):
    pv_map = {pv["metadata"]["name"]: pv for pv in pvs}

    # Map volumeName -> latest completed backup
    vol_to_latest_backup = {}
    for bk in backups:
        st = bk.get("status", {})
        if st.get("state") != "Completed":
            continue
        vol_name = st.get("volumeName")
        created = st.get("backupCreatedAt", "")
        if not vol_name:
            continue
        if vol_name not in vol_to_latest_backup or created > vol_to_latest_backup[vol_name]["created"]:
            vol_to_latest_backup[vol_name] = {
                "name": bk["metadata"]["name"],
                "url": st.get("url"),
                "size": str(st.get("volumeSize") or st.get("size")),
                "created": created,
                "accessMode": st.get("labels", {}).get("longhorn.io/volume-access-mode", "rwo")
            }

    manifests = []
    summary_lines = []

    for pvc in sorted(pvcs, key=lambda x: (x["metadata"]["namespace"], x["metadata"]["name"])):
        ns = pvc["metadata"]["namespace"]
        name = pvc["metadata"]["name"]
        vol = pvc["spec"].get("volumeName")

        if not vol:
            continue

        if vol not in vol_to_latest_backup:
            print(f"[-] No completed backup found for PVC {ns}/{name} (Volume: {vol}) - skipping")
            continue

        backup = vol_to_latest_backup[vol]
        pv = pv_map.get(vol, {})

        storage = pvc["spec"].get("resources", {}).get("requests", {}).get("storage")
        if not storage and pv:
            storage = pv.get("spec", {}).get("capacity", {}).get("storage")
        if not storage:
            storage = "5Gi"

        access_modes = pvc["spec"].get("accessModes", ["ReadWriteOnce"])
        longhorn_access_mode = "rwx" if "ReadWriteMany" in access_modes else "rwo"

        # Substitute s3://<bucket-identifier>/ with ${s3_bucket_longhorn}
        backup_url = backup["url"]
        s3_url = re.sub(r"^s3://[^/]+/", "${s3_bucket_longhorn}", backup_url)

        summary_lines.append(f"  - {ns}/{name}: backup {backup['name']} ({backup['created']})")

        csi_attrs = pv.get("spec", {}).get("csi", {}).get("volumeAttributes") or {"numberOfReplicas": "3"}
        formatted_attrs = "\n".join(f"      {k}: \"{v}\"" for k, v in sorted(csi_attrs.items()))

        block = f"""# PVC: {ns}/{name}
# Volume: {vol}
# Backup: {backup["name"]} ({backup["created"]})
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: {vol}
  namespace: longhorn-system
  labels:
    longhornvolume: {vol}
    recurring-job-group.longhorn.io/default: enabled
spec:
  accessMode: {longhorn_access_mode}
  fromBackup: "{s3_url}"
  frontend: blockdev
  numberOfReplicas: 3
  size: "{backup["size"]}"
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: {vol}
  annotations:
    pv.kubernetes.io/bound-by-controller: "yes"
spec:
  capacity:
    storage: {storage}
  accessModes:
{chr(10).join(f"    - {mode}" for mode in access_modes)}
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  volumeMode: Filesystem
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: {vol}
    volumeAttributes:
{formatted_attrs}
  claimRef:
    apiVersion: v1
    kind: PersistentVolumeClaim
    namespace: {ns}
    name: {name}"""
        manifests.append(block)

    if not manifests:
        return "", summary_lines

    header = f"""# ==============================================================================
# AUTOMATICALLY GENERATED BY longhorn-backup-sync
# Generated At: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}
#
# These declarative Volume and PersistentVolume resources are pre-provisioned
# during cluster bootstrap or disaster recovery to restore Longhorn volumes
# from the latest S3 backups and bind them directly to the workload PVCs.
# ==============================================================================
"""
    return header + "---\n" + "\n---\n".join(manifests) + "\n", summary_lines


def get_github_file(repo, branch, token, path):
    url = f"https://api.github.com/repos/{repo}/contents/{path}?ref={branch}"
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "Longhorn-Backup-Sync"
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            content = base64.b64decode(data.get("content", "")).decode("utf-8")
            return data.get("sha"), content
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None, None
        raise


def push_github_file(repo, branch, token, path, content, message, sha=None):
    url = f"https://api.github.com/repos/{repo}/contents/{path}"
    payload = {
        "message": message,
        "content": base64.b64encode(content.encode("utf-8")).decode("utf-8"),
        "branch": branch
    }
    if sha:
        payload["sha"] = sha

    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "Longhorn-Backup-Sync"
        },
        method="PUT"
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        return data.get("commit", {}).get("sha")


def strip_volatile_headers(yaml_str):
    """Strip timestamp comment line so we only compare actual resource content."""
    lines = [l for l in yaml_str.splitlines() if not l.startswith("# Generated At:")]
    return "\n".join(lines).strip()


def main():
    write_local = "--write-local" in sys.argv

    pvcs, pvs, backups = fetch_cluster_data()
    generated_content, summary = generate_restore_yaml(pvcs, pvs, backups)

    if not generated_content:
        print("[!] No volumes with completed backups found to sync.")
        return

    print(f"[+] Found {len(summary)} PVC(s) with completed backups:")
    for s in summary:
        print(s)

    if write_local:
        # Determine local repo root
        script_dir = os.path.dirname(os.path.abspath(__file__))
        repo_root = os.path.abspath(os.path.join(script_dir, ".."))
        local_target = os.path.join(repo_root, TARGET_FILE_PATH)
        os.makedirs(os.path.dirname(local_target), exist_ok=True)

        existing = ""
        if os.path.exists(local_target):
            with open(local_target, "r") as f:
                existing = f.read()

        if strip_volatile_headers(existing) == strip_volatile_headers(generated_content):
            print("[*] Local file is already up-to-date. No write needed.")
        else:
            with open(local_target, "w") as f:
                f.write(generated_content)
            print(f"[+] Successfully wrote {local_target}")
        return

    # GitOps sync mode (via GitHub API)
    if not GITHUB_TOKEN:
        print("[-] GITHUB_TOKEN is not set. Use --write-local for local updates or provide GITHUB_TOKEN.")
        sys.exit(1)

    print(f"[*] Checking existing GitOps manifest at {TARGET_FILE_PATH} in {GITHUB_REPO} ({GITHUB_BRANCH})...")
    sha, remote_content = get_github_file(GITHUB_REPO, GITHUB_BRANCH, GITHUB_TOKEN, TARGET_FILE_PATH)

    if remote_content and strip_volatile_headers(remote_content) == strip_volatile_headers(generated_content):
        print("[✓] GitOps backup manifests are already up to date. No commit needed.")
        return

    commit_msg = f"chore(longhorn): update latest PVC backup tags ({datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')} UTC) [skip ci]"
    print(f"[*] Pushing updated backup tags to {GITHUB_REPO}...")
    commit_sha = push_github_file(GITHUB_REPO, GITHUB_BRANCH, GITHUB_TOKEN, TARGET_FILE_PATH, generated_content, commit_msg, sha)
    print(f"[✓] Successfully committed to GitOps! Commit: {commit_sha}")


if __name__ == "__main__":
    main()
