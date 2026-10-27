Scheduled version updates of container images and Helm charts.

Renovate finds the updates: it opens one PR per chart or image update (listed below with their release notes)
and merges patch updates of apps and observability by itself. Your job is the rest: bring the repo up to date
in one reviewed apply that lands straight on main, like the user would at the desk.

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
3. Land them through Renovate's PRs:
   - **apply**: don't edit anything; list the PR number in `merge`. The service squash-merges it as it is.
   - **adapt**: make the bump and the edits it needs yourself in the clone (the same lines the PR changes; grep
     for the old version) and list the PR in `supersedes`. Your change is pushed after the merges, and the PR
     is closed with a link to it. Never list a PR in both.
   - Two `merge` PRs that change the same lines conflict: merge one and leave the other for next week (Renovate
     rebases it).
4. Keep it reviewable: at most about ten updates in one run, and keep core platform updates
   (cluster/, networking, security, storage) to a few. Leftovers are picked up next week.
5. Validate as the skill says, then call `submit_report`:
   - status `fixed` with a title like `chore(deps): update <n> images and charts` (the commit subject of your
     own change, if there is one), and the `merge`/`supersedes` lists;
   - the summary lists every update (old → new) with the release-note points that matter, the risk, what to
     check after Flux deploys it, and every PR you skipped with the reason;
   - nothing worth applying: status `findings` listing the skipped PRs and why, or `healthy` if there are none.
