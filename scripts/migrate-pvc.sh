#!/usr/bin/env bash
# Copy a PVC's data into a new PVC (Longhorn -> NAS migration), with the app stopped.
#
#   scripts/migrate-pvc.sh --context=<admin> <namespace> <old-pvc> <new-pvc> [--root [--pod-prefix=<name>]]
#
# Procedure per app (the old PVC is never modified, it stays as the rollback):
#   1. git: add the new PVC (e.g. <old>-nas, storageClassName nas-iscsi) next to the old one, push,
#      and wait until it is Bound.
#   2. flux suspend kustomization <the app's Kustomization, e.g. flux-services>
#   3. this script: scales every Deployment/StatefulSet that mounts <old-pvc> to 0, copies the data
#      with a temporary pod (old PVC mounted read-only) and compares checksums.
#   4. git: point the app at the new PVC, push, flux resume, then scale the workloads back up with
#      the commands this script prints (Flux only restores replicas if the manifest sets them).
#
# The copy pod runs as the app's own uid/gid (pod securityContext runAsUser/runAsGroup, else fsGroup).
# For apps that run as root and have files owned by several users (bundled databases), pass --root:
# the pod then runs as root and keeps owners and modes. PSS restricted only lets root pods through
# under an existing Kyverno name-prefix exception, so the pod is named <pod-prefix>-pvc-copy;
# --pod-prefix defaults to the namespace (homeassistant*, unifi*), dispatcharr needs dispatcharr-web.
set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

ctx="" root=false prefix=""
args=()
for a in "$@"; do
  case "$a" in
    --context=*) ctx="${a#*=}" ;;
    --root) root=true ;;
    --pod-prefix=*) prefix="${a#*=}" ;;
    -h|--help) usage ;;
    *) args+=("$a") ;;
  esac
done
[[ -n "$ctx" && ${#args[@]} -eq 3 ]] || usage
ns="${args[0]}" old="${args[1]}" new="${args[2]}"
prefix="${prefix:-$ns}"
pod="${prefix}-pvc-copy"
k() { kubectl --context="$ctx" -n "$ns" "$@"; }

for pvc in "$old" "$new"; do
  phase=$(k get pvc "$pvc" -o jsonpath='{.status.phase}')
  [[ "$phase" == Bound ]] || { echo "PVC $pvc is '$phase', not Bound" >&2; exit 1; }
done

# Workloads that mount the old PVC, with the uid/gid their pods run as
mapfile -t workloads < <(k get deploy,sts -o json | python3 -I -c '
import json, sys
old = sys.argv[1]
for w in json.load(sys.stdin)["items"]:
    s = w["spec"]["template"]["spec"]
    if any(v.get("persistentVolumeClaim", {}).get("claimName") == old for v in s.get("volumes", [])):
        sc = s.get("securityContext", {})
        uid = sc.get("runAsUser", sc.get("fsGroup", ""))
        gid = sc.get("runAsGroup", sc.get("fsGroup", ""))
        print(w["kind"].lower() + "/" + w["metadata"]["name"], uid, gid)
' "$old")
[[ ${#workloads[@]} -gt 0 ]] || { echo "no Deployment/StatefulSet in $ns mounts $old" >&2; exit 1; }
read -r _ uid gid <<<"${workloads[0]}"
if ! $root && [[ -z "$uid" || -z "$gid" ]]; then
  echo "${workloads[0]%% *} sets no runAsUser/fsGroup (runs as root?): use --root" >&2; exit 1
fi

echo "stopping: ${workloads[*]%% *}"
restore=()
for w in "${workloads[@]}"; do
  restore+=("kubectl --context=$ctx -n $ns scale ${w%% *} --replicas=$(k get "${w%% *}" -o jsonpath='{.spec.replicas}')")
  k scale "${w%% *}" --replicas=0 >/dev/null
done
for w in "${workloads[@]}"; do
  sel=$(k get "${w%% *}" -o jsonpath='{.spec.selector.matchLabels}' | python3 -I -c 'import json,sys; print(",".join(f"{a}={b}" for a,b in json.load(sys.stdin).items()))')
  k wait --for=delete pod -l "$sel" --timeout=300s >/dev/null 2>&1 || true
done

if $root; then
  sec='securityContext: {seccompProfile: {type: RuntimeDefault}}'
  csec='securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"], add: ["CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID"]}}'
  untar='tar xpf - --numeric-owner -C /new'
  meta='%n %u %g %a'
else
  sec="securityContext: {runAsNonRoot: true, runAsUser: $uid, runAsGroup: $gid, fsGroup: $gid, fsGroupChangePolicy: OnRootMismatch, seccompProfile: {type: RuntimeDefault}}"
  csec='securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}'
  untar='tar xpf - -o -C /new'
  meta='%n %a'
fi

k delete pod "$pod" --ignore-not-found >/dev/null
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $pod, namespace: $ns}
spec:
  restartPolicy: Never
  $sec
  containers:
    - name: copy
      image: busybox:1.37
      command:
        - sh
        - -c
        - |
          set -e
          umask 0
          if [ -n "\$(ls -A /new | grep -vx lost+found)" ]; then echo "target is not empty" >&2; exit 1; fi
          cd /old && tar cf - --exclude=./lost+found . | $untar
          for d in old new; do
            cd /\$d
            find . -path ./lost+found -prune -o -type f -exec sha256sum {} + | sort -k2 > /tmp/\$d.sum
            find . -path ./lost+found -prune -o -exec stat -c '$meta' {} + | sort > /tmp/\$d.meta
          done
          diff /tmp/old.sum /tmp/new.sum
          diff /tmp/old.meta /tmp/new.meta || echo "(owner/mode differences above)"
          echo "files: \$(wc -l < /tmp/new.sum)  size: \$(du -sh /new | cut -f1)"
          echo COPY-OK
      $csec
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {cpu: "1", memory: 512Mi}
      volumeMounts:
        - {name: old, mountPath: /old, readOnly: true}
        - {name: new, mountPath: /new}
  volumes:
    - name: old
      persistentVolumeClaim: {claimName: $old, readOnly: true}
    - name: new
      persistentVolumeClaim: {claimName: $new}
EOF

k wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=3600s >/dev/null || true
k logs "$pod"
phase=$(k get pod "$pod" -o jsonpath='{.status.phase}')
if [[ "$phase" == Succeeded ]]; then
  k delete pod "$pod" --wait=false >/dev/null
  echo "done: $old -> $new. Workloads stay at 0: push the switch to $new, resume Flux, then run:"
  printf '  %s\n' "${restore[@]}"
else
  echo "copy pod is $phase; pod $pod kept for inspection. Workloads are at 0; to restart them on $old:" >&2
  printf '  %s\n' "${restore[@]}" >&2
  exit 1
fi
