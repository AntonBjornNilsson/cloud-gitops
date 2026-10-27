Scheduled version updates of container images and Helm charts.

Renovate finds the updates: it opens one PR per chart or image update (listed below with their release notes)
and merges patch updates of apps and observability by itself. Your job is the rest: bring the repo up to date
in one reviewed change that goes straight to main, like the user would at the desk.

1. Go through the open Renovate PRs below and sort each one:
   - **apply**: minor and patch updates whose release notes show no breaking change.
   - **adapt**: a breaking change you can handle in the manifests (renamed or removed Helm values, a new
     required field, a changed default you rely on): apply the bump together with that edit.
   - **skip**: majors (they need the user's approval on the Dependency Dashboard); anything whose notes call for
     manual or data migration steps you can't do in manifests; releases the notes flag as broken.
   - Longhorn: at most one minor per run, oldest first, never together with other updates, and only after the
     PR's checklist holds (no Faulted volume, latest daily backups completed).
   - cfgate is pinned exactly and alpha: read its chart upgrade notes in the PR; skip it if they need steps.
2. Before bumping a component, check that it runs fine now (Flux Ready, pods healthy). Don't upgrade something
   that is broken unless the update is the fix; mention it instead.
3. Make the version edits yourself: the same lines the Renovate PR changes (grep for the old version). Keep
   the house style (`version` ranges in HelmReleases stay ranges unless the skill says otherwise). Renovate
   closes its PRs once main has the new versions.
4. Keep it reviewable: at most about ten updates in one run, and keep core platform updates
   (cluster/, networking, security, storage) to a few. Leftovers are picked up next week.
5. Validate as the skill says, then call `submit_report`:
   - status `fixed` with a title like `chore(deps): update <n> images and charts`;
   - the summary lists every update (old → new) with the release-note points that matter, the risk, what to
     check after Flux deploys it, and every PR you skipped with the reason;
   - nothing worth applying: status `findings` listing the skipped PRs and why, or `healthy` if there are none.
