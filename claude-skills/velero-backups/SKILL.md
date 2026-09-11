---
name: velero-backups
description: Generic Kubernetes backup/restore with Velero — BackupStorageLocation and VolumeSnapshotLocation setup, scheduled Backups, restic/kopia file-system backup for CSI or non-CSI volumes, restore including namespace remapping, hooks (pre/post backup exec), and IRSA/workload-identity wiring on EKS/AKS/GKE. Use whenever the user mentions Velero, "backup this cluster/namespace", disaster recovery for Kubernetes, restoring a namespace, a Velero backup stuck in PartiallyFailed, or velero CLI commands — even if they only say "cluster backup" or "restore this cluster from last night." Not tied to any one company's backup topology; for EIS/OneSuite's Velero parity and Backup Vault Lock wiring, prefer this repo's own eis-velero-backups / eis-backup-vault-lock skills first.
---

# Velero

Velero backs up Kubernetes API objects and (optionally) their persistent volume data, storing both in object storage (S3, GCS, Azure Blob) so a cluster — or a namespace — can be restored elsewhere.

## Core objects

| CRD | Purpose |
|---|---|
| `BackupStorageLocation` (BSL) | Where backup tarballs/manifests land — an S3 bucket + prefix + credentials. |
| `VolumeSnapshotLocation` (VSL) | Where cloud-native volume snapshots go (EBS snapshots on AWS, etc.) — only relevant if using the cloud snapshot path, not restic/kopia. |
| `Backup` | One backup run — filtered by namespace/label/resource selectors, `ttl`, `includedNamespaces`, `snapshotVolumes`. |
| `Schedule` | A cron-like wrapper that creates `Backup` objects on a recurring cadence. |
| `Restore` | Replays a `Backup` back into the cluster, with optional namespace remapping and resource filters. |
| `PodVolumeBackup` / `PodVolumeRestore` | Per-pod-volume backup/restore records when using restic/kopia (file-level) instead of cloud volume snapshots. |

## Two ways Velero backs up volume data

1. **Cloud-native snapshots** (via `VolumeSnapshotLocation` + a snapshot plugin, or native CSI snapshotting): fast, consistent, but tied to that cloud's snapshot API and often can't cross regions/accounts on restore without extra copy steps.
2. **File-system backup** (restic, or kopia as of newer Velero): works for any volume type including hostPath and non-CSI, backs up file contents directly into the BSL bucket. Requires the `backup.velero.io/backup-volumes` annotation on the pod (or opt-out annotation with default-backup-all configured) naming which volumes to include — a volume Velero silently skips is almost always a missing/misspelled annotation, not a bug.

Don't assume snapshotVolumes=true alone backs up data — check which path (cloud snapshot vs restic/kopia) the BSL/VSL config actually wires up, since the two need different plugins and different daemonset (node-agent) deployment.

## Identity / credentials on managed Kubernetes

On EKS, Velero's pod needs write access to the S3 bucket (and EBS snapshot permissions if using cloud snapshots) via IRSA (IAM Roles for Service Accounts) — annotate the Velero service account with the role ARN, don't hand it static AWS keys. Equivalent pattern on AKS (workload identity/pod identity) and GKE (Workload Identity). A backup that fails with an S3 403 almost always traces to the IRSA trust policy or the service account annotation, not Velero config itself.

## Hooks

```yaml
metadata:
  annotations:
    pre.hook.backup.velero.io/command: '["/bin/sh", "-c", "pg_dump ... > /backup/dump.sql"]'
    pre.hook.backup.velero.io/container: db
    post.hook.restore.velero.io/command: '["/bin/sh", "-c", "psql < /backup/dump.sql"]'
```

Pre-backup hooks run inside a pod's container before the volume backup starts (e.g. flush a database to disk); post-restore hooks run after resources are created. Hooks that fail don't automatically fail the whole backup unless `onError: Fail` is set — a "successful" backup can still mean the hook silently errored, so check the backup's hook status, not just its phase.

## Restore with namespace remapping

```bash
velero restore create --from-backup nightly-20260601 \
  --namespace-mappings old-ns:new-ns \
  --include-resources deployments,services,configmaps
```

Useful for restoring into a scratch namespace to inspect before overwriting the live one. Note: Velero restore does not delete/replace existing resources by default — restoring into a namespace that still has the old objects results in "already exists" skips unless `--existing-resource-policy update` is set.

## Debugging a stuck or PartiallyFailed backup

```bash
velero backup describe <name> --details
velero backup logs <name>
```

Common causes: BSL unreachable (network policy, wrong bucket region), a `PodVolumeBackup` timing out on a large volume (check `--fs-backup-timeout`), or a hook exceeding its default timeout. `velero backup describe --details` prints per-resource and per-hook status — read past the top-level phase before concluding it's a config bug versus one resource genuinely failing.

## Retention

`Backup.spec.ttl` (default 30 days) controls when Velero's own garbage collector deletes the backup and its data from the BSL. This is independent from any bucket-level lifecycle policy or object lock the storage backend enforces — a backup can disappear from `velero backup get` due to TTL expiry while the underlying S3 objects are still retained (or vice versa, if a bucket policy blocks Velero's delete, e.g. Object Lock/WORM) — check both layers when a backup "should still exist" but doesn't, or won't delete.
