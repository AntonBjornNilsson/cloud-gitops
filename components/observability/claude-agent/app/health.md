Scheduled health review of the cluster.

1. Investigate the cluster health:
   - Flux Kustomizations, HelmReleases and sources that are not Ready
   - pods crashlooping, pending, OOMKilled or with many recent restarts; failed Jobs
   - recent Warning events, degraded Longhorn volumes, Pending PVCs, expiring/failed certificates
2. Pick the single most important issue that can be fixed by changing manifests in this repo and make the
   smallest correct edit. Version bumps are the weekly `updates` run's job (Renovate finds them): don't make
   them here. For images with CRITICAL findings, check the open Renovate PRs below: if one bumps it, name it in
   the summary ("#N fixes it; the next updates run applies it, or start one now").
   OOMKilled containers (or memory near the limit): don't raise requests or limits on your own. Look up the
   container's usage (VictoriaMetrics through the API server proxy, e.g. `kubectl get --raw
   '/api/v1/namespaces/victoriametrics/services/vmsingle-vm-k8s-stack:8428/proxy/api/v1/query?query=...'`
   with the queries in the skill's "Resources" section) and the free memory on its node, then `ask_user` whether to
   raise them: current request/limit, observed peak, proposed values. Edit only on yes; no answer means no, and
   the OOM goes under findings.
3. Problems that need a human (a missing or revoked credential, a node that is down, hardware) go in the report
   as findings. If a transient unblock would help (e.g. deleting a stuck pod), you may request it; it is asked
   to the user first.
4. Call `submit_report`. Anything that looks like a problem but is not urgent (old restarts, a crash that
   stopped) still belongs in the summary, and makes the status `findings` rather than `healthy`.
