#!/usr/bin/env python3
"""
Check that every ${var} a Flux Kustomization renders is provided by one of the
Secrets in its postBuild.substituteFrom. Flux turns an unresolved variable into
an empty string without an error, so a missing Secret there breaks things quietly.

Key names (never values) are read from the cluster with `kubectl describe secret`,
or with --secrets-dir from the Secret manifests in a checkout of the secrets repo
(to check a change there before it is pushed).

  scripts/check-substitutions.py [--context <kube-context>] [--secrets-dir <path>]
"""
import os
import re
import subprocess
import sys

import yaml

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.realpath(__file__)), ".."))
VAR = re.compile(r"(?<!\$)\$\{([a-zA-Z_][a-zA-Z0-9_]*)")


def kubectl(args, context):
    cmd = ["kubectl"] + (["--context", context] if context else []) + args
    return subprocess.run(cmd, capture_output=True, text=True)


def local_secrets(root):
    found = {}
    for dirpath, _, files in os.walk(root):
        if "/." in dirpath:
            continue
        for f in files:
            if f.endswith((".yaml", ".yml")):
                for d in yaml.safe_load_all(open(os.path.join(dirpath, f))):
                    if isinstance(d, dict) and d.get("kind") == "Secret":
                        keys = set(d.get("stringData") or {}) | set(d.get("data") or {})
                        found.setdefault(d["metadata"]["name"], set()).update(keys)
    return found


def secret_keys(name, context, cache={}):
    if name not in cache:
        out = kubectl(["-n", "flux-system", "describe", "secret", name], context)
        keys = set()
        if out.returncode == 0:
            data = out.stdout.split("\nData\n", 1)[-1]
            keys = {m.group(1) for m in re.finditer(r"^([A-Za-z0-9_.-]+):\s+\d+ bytes", data, re.M)}
        cache[name] = keys if out.returncode == 0 else None
    return cache[name]


def build(path):
    out = subprocess.run(["kubectl", "kustomize", os.path.join(REPO, path)], capture_output=True, text=True)
    return out.returncode, out.stdout, out.stderr.strip()


def is_flux_kustomization(d):
    return (isinstance(d, dict) and d.get("kind") == "Kustomization"
            and d.get("apiVersion", "").startswith("kustomize.toolkit.fluxcd.io")
            and d["spec"].get("sourceRef", {}).get("name") == "flux-system")


def flux_kustomizations():
    """Every Flux Kustomization that exists: cluster/flux-system and, recursively, what each one renders."""
    queue, seen = ["cluster/flux-system"], set()
    while queue:
        path = queue.pop(0)
        rc, out, _ = build(path)
        if rc != 0:
            continue
        for d in yaml.safe_load_all(out):
            if is_flux_kustomization(d) and d["metadata"]["name"] not in seen:
                seen.add(d["metadata"]["name"])
                queue.append(d["spec"]["path"])
                yield d


def main():
    context = sys.argv[sys.argv.index("--context") + 1] if "--context" in sys.argv else None
    local = local_secrets(sys.argv[sys.argv.index("--secrets-dir") + 1]) if "--secrets-dir" in sys.argv else None
    failed = False
    checked = 0
    for ks in flux_kustomizations():
        name = ks["metadata"]["name"]
        if "postBuild" not in ks["spec"]:
            continue  # no substitution at all
        sources = [s["name"] for s in ks["spec"].get("postBuild", {}).get("substituteFrom", []) if s.get("kind") == "Secret"]
        rc, out, err = build(ks["spec"]["path"])
        if rc != 0:
            print(f"{name}: kustomize build failed: {err}")
            failed = True
            continue
        used = set()
        for doc in yaml.safe_load_all(out):
            if not doc:
                continue
            ann = (doc.get("metadata") or {}).get("annotations") or {}
            if ann.get("kustomize.toolkit.fluxcd.io/substitute") == "disabled":
                continue
            used |= set(VAR.findall(yaml.dump(doc)))
        checked += 1
        provided = set()
        for s in sources:
            keys = local.get(s) if local is not None else secret_keys(s, context)
            if keys is None:
                print(f"{name}: Secret {s} not found")
                failed = True
            else:
                provided |= keys
        missing = sorted(used - provided)
        if missing:
            print(f"{name}: not in {', '.join(sources) or 'any Secret'}: {' '.join(missing)}")
            failed = True
    if failed:
        sys.exit(1)
    print(f"All substitution variables resolve ({checked} Kustomizations checked).")


if __name__ == "__main__":
    main()
