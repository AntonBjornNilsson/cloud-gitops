Scheduled health review of the cluster.

1. Investigate the cluster health:
   - Flux Kustomizations, HelmReleases and sources that are not Ready
   - pods crashlooping, pending, OOMKilled or with many recent restarts; failed Jobs
   - recent Warning events, degraded Longhorn volumes, Pending PVCs, expiring/failed certificates
2. Pick the single most important issue that can be fixed by changing manifests in this repo and make the
   smallest correct edit. Renovate updates chart and image versions (including CVE fixes): don't make version
   bumps. For images with CRITICAL findings, check the open Renovate PRs below: if one bumps it, name it in the
   summary ("merging #N should fix...").
3. Problems that need a human (a missing or revoked credential, a node that is down, hardware) go in the report
   as findings. If a transient unblock would help (e.g. deleting a stuck pod), you may request it; it is asked
   to the user first.
4. Call `submit_report`. Anything that looks like a problem but is not urgent (old restarts, a crash that
   stopped) still belongs in the summary, and makes the status `findings` rather than `healthy`.
