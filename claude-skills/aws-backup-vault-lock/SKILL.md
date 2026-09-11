---
name: aws-backup-vault-lock
description: Generic AWS Backup Vault Lock usage — compliance mode vs governance mode, the mandatory cooling-off period before compliance mode becomes truly immutable, minimum/maximum retention enforcement, changing a locked vault's policy, and how Vault Lock interacts with a Backup Plan's own lifecycle rules. Use whenever the user mentions AWS Backup Vault Lock, WORM (write-once-read-many) backups, immutable backups for ransomware/compliance requirements, a backup vault that won't let a retention rule be shortened, or SOC2/HIPAA/audit requirements around backup immutability — even if they just say "make our backups untouchable" or "compliance wants immutable backups." Not tied to any one company's account; for EIS/OneSuite's specific Backup Vault Lock rollout, prefer this repo's own eis-backup-vault-lock skill first.
---

# AWS Backup Vault Lock

Vault Lock applies a WORM (write-once-read-many) policy to an AWS Backup vault: once locked, recovery points inside cannot be deleted before their minimum retention expires, and the vault's own retention rules can't be loosened — not even by the account root user, once the lock is in **compliance mode** and past its cooling-off period.

## Two lock modes — the distinction that matters

| Mode | Who can still change/delete | Use case |
|---|---|---|
| **Governance mode** | Users with the `backup:BypassGovernanceRetention` IAM permission can still delete recovery points or modify the policy. | Internal safety guardrail against accidental deletion, not a compliance control. |
| **Compliance mode** | Nobody — including root — can delete a recovery point before retention expires, or loosen the policy, once the cooling-off period ends. | True regulatory immutability (SOC2, HIPAA, ransomware-resilience requirements). |

If the ask is "meet an audit/compliance requirement for immutable backups," it means compliance mode — governance mode does not satisfy that bar since a sufficiently-privileged user can still bypass it.

## The cooling-off period — the gotcha that catches people

Locking a vault in compliance mode does **not** make it immutable immediately. AWS enforces a minimum 3-day cooling-off period (configurable up to 36 months) during which the lock can still be *cancelled* entirely. Only after the cooling-off window elapses without cancellation does the vault become truly locked and irreversible. Anyone testing "can I still change this" during the cooling-off window will find they can — that's by design, not a bug, and it's the only chance to fix a misconfigured policy before it becomes permanent.

## Retention bounds

```bash
aws backup put-backup-vault-lock-configuration \
  --backup-vault-name my-vault \
  --min-retention-days 90 \
  --max-retention-days 2555 \
  --changeable-for-days 3
```

- `min-retention-days`: no recovery point in this vault can be deleted, nor can a Backup Plan's lifecycle rule expire it, before this many days — even if the plan itself says a shorter retention.
- `max-retention-days`: caps how long a recovery point can be *kept*, forcing eventual expiry (relevant for storage-cost or data-minimization requirements, not just "keep forever").
- A Backup Plan lifecycle rule that conflicts with the vault's locked bounds (e.g. plan says delete after 30 days, vault lock says min 90) is silently clamped to the vault's minimum — the plan's own setting doesn't win.

## Irreversibility — plan before you lock

Once compliance mode passes cooling-off:
- The vault cannot be deleted while it still contains any recovery point under retention.
- `min-retention-days` can only be *increased*, never decreased.
- `max-retention-days` can only be *decreased* (tightened), never increased.

This means testing a Vault Lock policy in a scratch/non-prod vault first, with values you're confident about, is the only real safety net — there is no "undo" path once the window passes.

## Interaction with existing vaults and cross-account/cross-region copies

Vault Lock is per-vault, not per-account — a Backup Plan copying recovery points into a second vault (cross-region or cross-account, common for the ransomware-resilience "3-2-1" pattern) needs its own independent lock configuration on that destination vault; locking the source vault does not propagate.
