Scheduled version updates of container images and Helm charts.

Renovate finds the updates: it opens one PR per chart or image update (listed below with their release notes)
and merges patch updates of apps and observability by itself. Your job is the rest: bring the repo up to date
straight on main, like the user would at the desk.

This run is unattended: nobody approves it. Your report is applied exactly as you submit it, the user gets a
notification afterwards, and a health review checks the cluster 30 minutes later. So be conservative: when in
doubt, skip and say why. Use read-only commands only: nobody answers questions in this run, so any command
that needs approval just waits for hours and is then refused.

1. Go through the open Renovate PRs below and sort each one:
   - **apply**: minor and patch updates whose release notes show no breaking change.
   - **adapt**: a breaking change you can handle in the manifests (renamed or removed Helm values, a new
     required field, a changed default you rely on): apply the bump together with that edit.
   - **majors**: apply or adapt only if the release notes list every breaking change and none of them needs
     more than a manifest edit you can make with confidence. Never take a major of a database or other stateful
     store (postgres, mongo, redis, ...): its data format needs a migration. Skipped majors stay open as PRs for
     the user; when you skip one, say that its clients must match too (an app's own `pg_dump` for its backups,
     for example), which you can't check from here.
   - **skip**: anything whose notes call for manual or data migration steps you can't do in manifests;
     releases the notes flag as broken; notes that are missing or too thin to judge a non-patch update.
   - **Chart analysis** (below the PR list) renders each chart PR at its old and new version with the repo's
     values, and adds upstream upgrade notes for core charts. Read it for every chart PR. It counts as release
     notes, so "the notes are thin" doesn't apply when the analysis shows what changes:
     - A **BLOCKER** is never an apply, and that PR stays out of `merge`. Denied by the restricted profile: adapt
       only by adding the missing securityContext and limits through chart values (Helm hook Jobs too: a denied
       hook fails the upgrade and blocks every Kustomization behind it), otherwise skip. Kind change: skip unless a
       chart value keeps the old kind and the notes confirm it. Doesn't render with the repo's values: adapt if the
       fix to the value is clear, otherwise skip. CRD stored version missing: skip.
     - Check the rendered changes and changed defaults against what the repo relies on: a mount going read-only,
       a Service port renamed, a scrape removed, a value the chart no longer has. Adapt or skip those.
     - A non-patch chart PR that says unavailable, not analysed or could not analyse: skip it and say why.
     - The analysis can't see pods an operator creates, and it can't re-render your adapted version: say so in
       the report when you adapt a chart.
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
