# Longhorn Declarative Volume Restore (Disaster Recovery)

This directory contains declarative Kubernetes and Longhorn custom resources used for automated Disaster Recovery (DR) and cluster bootstrap.

## How It Works

1. **Daily Backup & Sync**:
   - Longhorn runs daily backups to S3 at `02:00` (`daily-backup` RecurringJob).
   - The `longhorn-backup-sync` CronJob runs at `03:00` daily, inspects all cluster PVCs, identifies the newest completed Longhorn backup for each volume, and updates `volumes.yaml` in GitOps.

2. **Cluster Bootstrap / Disaster Recovery**:
   - If the entire cluster is lost or wiped, rebuild nodes with `k0sctl apply` and bootstrap Flux (`flux bootstrap github ...`).
   - Flux reconciles `components/storage/longhorn` and applies `system-longhorn-config`.
   - Longhorn reads the declarative `Volume` CRs containing `fromBackup: "${s3_bucket_longhorn}?backup=...&volume=..."` and automatically restores each volume from S3.
   - Kubernetes creates the matching `PersistentVolume` (PV) resources pre-bound via `claimRef` to the target namespace and PVC name.
   - When Flux deploys `services/`, each application's `PersistentVolumeClaim` immediately binds to the pre-restored PV instead of provisioning an empty disk.
   - Workloads start with 100% of their backed-up state intact.

## Live-Cluster Safety

Every generated `Volume` and `PersistentVolume` carries two Flux annotations:

- `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` — Flux only *creates* them (bootstrap / DR) and never updates existing ones. Setting `fromBackup` on an existing, empty-provisioned volume makes Longhorn start a restore on it, which leaves the volume stuck "not ready for workloads".
- `kustomize.toolkit.fluxcd.io/prune: disabled` — dropping an entry from `volumes.yaml` never deletes the live volume or its data.

The nightly commits therefore only keep the DR snapshot in Git up to date; they do not change the running cluster.

## Manual Trigger

To trigger an immediate backup sync from your workstation without waiting for the nightly CronJob:
```bash
python3 scripts/sync-longhorn-backups.py --write-local
```
Or to run the in-cluster CronJob on-demand:
```bash
kubectl create job --from=cronjob/longhorn-backup-sync manual-backup-sync -n longhorn-system
```
