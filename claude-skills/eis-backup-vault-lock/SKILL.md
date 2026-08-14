---
name: eis-backup-vault-lock
description: Deploy or review an AWS Backup vault with Vault Lock (WORM / compliance retention) in an EIS client environment via the eis-backup Terraform module. Use whenever a request mentions AWS Backup Vault Lock, WORM backups, immutable or undeletable backups, ransomware-proof backups, backup compliance mode, min_retention_days, changeable_for_days, a "locked vault", or an audit/HDS/SOC2 finding asking that backups cannot be deleted early. Also use when adding AWS Backup to any upper/prod EIS stage, when a backup policy's delete_after must be reconciled with a retention floor, or when someone asks whether a vault is "actually locked yet". Encodes the retention-floor math, the Locked-vs-LockDate trap, the one-shot KMS decision, and the eis-ec2 tagging cascade that silently destroys a live keypair.
---

# AWS Backup Vault Lock via eis-backup

Vault Lock makes recovery points **immutable**: once a vault reaches compliance mode, nobody — including the account root and AWS Support — can delete a recovery point or shorten its retention until it expires naturally. That power is the whole point, and also why this workflow is unusually unforgiving. Two decisions here can never be undone, so the sequencing below exists to put both of them in front of a human *before* apply, not after.

## The two irreversible decisions

Surface both explicitly to the user before applying. If you only flag one, flag the KMS key — it is the easier one to forget and the harder one to live with.

1. **Compliance-mode transition.** `changeable_for_days` is a grace window. While it runs the lock is *governance* mode and can still be deleted or loosened. When it lapses the vault becomes *compliance* mode, permanently, for the life of the vault.
2. **The encryption key.** A vault's `EncryptionKeyArn` is fixed at creation. `eis-backup` (through v1.1.0) has **no `kms_key_arn` input**, so vaults silently get the AWS-managed `alias/aws/backup` key. If a compliance vault needs a CMK, the module variable must be added *before* the first apply — afterwards it requires a brand-new vault. Consumer repos often suppress `CKV_AWS_166` in `ci/.checkov.yaml` for exactly this, so checkov passing is not evidence of a CMK.

## Retention floor: the constraint that reshapes the policy set

`min_retention_days` is a floor on **every** recovery point in the vault. Any backup rule whose `delete_after` is below it is invalid, because the rule promises a deletion the lock forbids.

`eis-backup`'s stock policies are `daily-7day` (7), `weekly-2week` (14), `monthly-1year` (365). With a 30-day floor the first two are unusable.

**The fix is to raise retention above the floor, not to delete the short policies.** Dropping to monthly-only is tempting and wrong twice over:

- Prod ends up with a coarser RPO than dev, which is backwards.
- A monthly cron fires on the 1st, so the vault can compliance-lock *weeks before it ever writes a recovery point* — and any "verify a real backup before the lock finalizes" plan becomes impossible.

Reach for the same daily/weekly/monthly cadence lower already runs, with retention lifted:

```hcl
backups = {
  default_backup_resources = [
    "arn:aws:ec2:*:*:instance/*",
    "arn:aws:ec2:*:*:volume/*",
    "arn:aws:s3:::*",           # add rds cluster/db ARNs where RDS exists
  ]

  default_backup_policies = {
    daily-35day   = { schedule = "cron(0 3 * * ? *)",   delete_after = 35,   tag = "Backup-Locked-Retention" }
    weekly-90day  = { schedule = "cron(0 1 ? * SUN *)", delete_after = 90,   tag = "Backup-Locked-Retention" }
    monthly-3year = { schedule = "cron(0 2 1 * ? *)",   delete_after = 1095, tag = "Backup-Locked-Retention" }
  }
}
```

The lock constrains retention, not the plan set — policies can still be added after locking, provided each respects the floor. So getting the *floor* right matters far more than getting the policy list complete on day one.

Cost consequence worth stating out loud: with a 30-day floor nothing expires early, so expect at least ~30 undeletable snapshots per selected resource. Incremental, but a real commitment that cannot be walked back post-lock.

## Module capability

`eis-backup` gained Vault Lock in **v1.1.0** (COEXT-108349). Earlier tags cannot express it at all.

```hcl
module "backup" {
  source = "git::https://sfo-devopsgit01.eqxdev.exigengroup.com/iac/terraform/modules/aws/eis-backup.git?ref=v1.1.0"

  project_prefix = local.project_prefix
  vault_name     = "aws11caasharevault"   # omit to get "${project_prefix}-vault"

  vault_lock = {
    changeable_for_days = 3
    min_retention_days  = 30
    # max_retention_days omitted = unlimited
  }

  config = var.backups
}
```

`vault_name` exists because the module otherwise hardcodes `"${project_prefix}-vault"` — a hyphenated name. When a ticket names an exact vault (`aws11caasharevault`), that hyphen makes the module's default the wrong string.

Both `vault_lock` and `vault_name` default to `null`, so bumping other consumers to v1.1.0 is a no-op. Verify a tag actually contains the feature before pinning to it:

```bash
glab api "projects/iac%2Fterraform%2Fmodules%2Faws%2Feis-backup/repository/files/main.tf/raw?ref=v1.1.0" | grep vault_lock_configuration
```

If the module needs changing, follow `eis-module-fix-release-consume`. Expect one specific blocker: several `eis-*` modules' CI lints every commit including GitLab's merge commit, which is not a Conventional Commit, so post-merge `main` goes red and the **manual `publish_release` job is skipped** — no tag, and the consumer's `?ref=` then fails with `invalid ref`. Fix is `git rev-list --no-merges` (already upstream in `terraform/template/module`, COEXT-105281).

## Placement

Put the vault in the **shared-services** state of the level (`upper/share/services`, mirroring `lower/infra/services`), not the workload state. AWS Backup only requires the vault and its resources to share an **account and region** — not a Terraform state — so a shared-zone vault protecting workloads in a sibling state is correct, not a compromise.

Per-customer projects use the `_custom.tf` / `variables_custom.tf` / `_custom.auto.tfvars` convention plus an ADR — see the `customize-terraform` skill in the client repo.

## The tagging trap: one tag can destroy a live keypair

Selection is tag-based (`aws:ResourceTag/Backup`), so **the vault protects nothing until resources are tagged.** The obvious next step — tag an EC2 host — has a non-obvious cost.

`eis-ec2` exposes a single `tags` variable and fans it out to all seven of its resources, including `aws_secretsmanager_secret.ssh`. Adding one tag therefore:

1. marks that secret as changed →
2. defers `data.aws_secretsmanager_secret_version.ssh` to apply time →
3. makes `aws_key_pair.public_key` unknown at plan time →
4. Terraform resolves unknown-on-a-ForceNew attribute as **`must be replaced`**

The key *material* usually does not change (check that the `aws_secretsmanager_secret_version` **resource** — not the data source — is absent from the plan; if so `secret_string_wo_version` is unchanged), and the module never reconciles a running host's `authorized_keys`, so SSH survives. But it is still an avoidable destroy of a prod keypair with a new `key_pair_id`.

Options, in order of preference: add an instance-only tag input to `eis-ec2`; tag resources not managed by `eis-ec2` (S3, EBS); or ship the vault empty and tag in a follow-up. Shipping empty is legitimate — locking an empty vault commits no data — but say so plainly rather than implying coverage exists.

## Verify: read `LockDate`, not `Locked`

**`Locked: true` appears the instant a lock configuration is attached**, while the vault is still in governance mode and fully reversible. A verification step that waits for `Locked=false` during the grace window will never succeed. The field that marks the point of no return is `LockDate`, and it equals `CreationDate + changeable_for_days` to the second.

```bash
aws backup describe-backup-vault --backup-vault-name <vault> --region <region>
```

| Field | Read it as |
|---|---|
| `Locked: true` | a lock config exists — says nothing about immutability |
| `LockDate` in the future | governance mode; still removable/loosenable |
| `LockDate` passed | **compliance mode**; retention can only ever increase |
| `MaxRetentionDays` absent | unlimited, as intended when the input is omitted |
| `EncryptionKeyArn` | resolve it — `kms describe-key` `KeyManager=AWS` + `alias/aws/backup` means no CMK |

Then confirm the plans and that coverage is real rather than nominal:

```bash
aws backup list-backup-plans --query 'BackupPlansList[].BackupPlanId' --output text
aws backup get-backup-plan --backup-plan-id <id> \
  --query 'BackupPlan.[BackupPlanName,Rules[].[RuleName,ScheduleExpression,Lifecycle.DeleteAfterDays,TargetBackupVaultName]]'
aws backup list-backup-selections --backup-plan-id <id>

# Coverage truth-check — a vault+plans+selections all existing proves nothing
aws resourcegroupstaggingapi get-resources --tag-filters Key=Backup,Values=<tag-value> \
  --query 'length(ResourceTagMappingList)'
aws backup list-recovery-points-by-backup-vault --backup-vault-name <vault> \
  --query 'length(RecoveryPoints)'
```

Zero tagged resources and zero recovery points is the honest signal that nothing is protected yet.

### Do not mistake an expired session for missing access

Before reporting "I can't verify, no access to that account": the AWS SSO token is scoped to the **start-URL**, not to profiles, so a missing `~/.aws/config` profile is not evidence of anything. Enumerate what the token actually reaches, and get credentials without a profile:

```bash
TOK=$(python3 -c "
import json,glob,os,datetime
now=datetime.datetime.now(datetime.timezone.utc)
for f in glob.glob(os.path.expanduser('~/.aws/sso/cache/*.json')):
    d=json.load(open(f))
    if 'accessToken' not in d: continue
    if datetime.datetime.fromisoformat(d['expiresAt'].replace('Z','+00:00'))>now:
        print(d['accessToken']); break")
aws sso list-accounts --access-token "$TOK" --region us-east-1
aws sso get-role-credentials --access-token "$TOK" --account-id <acct> --role-name ReadOnlyAccess --region us-east-1
```

If every cached token is expired the accurate statement is "the SSO session is expired, approve a login" — a three-minute fix — not "I lack permission", which sends the user chasing an admin grant they don't need. `aws sso login --profile <any-with-same-start-url> --no-browser` prints a device code; run it backgrounded and poll the cache. Prefer `ReadOnlyAccess` for verification.

## Order of work

1. Confirm the retention floor with whoever owns the requirement, then build a policy set where every `delete_after` clears it.
2. Release the module first if `vault_lock` support or a CMK input is missing; the consumer's `?ref=` cannot resolve until the tag exists.
3. Open the consumer MR. **Read the plan's change lines, not the summary counts** — this work should be purely additive, so any `to destroy` or `must be replaced` is a signal (see the keypair cascade above), not noise.
4. Surface both irreversible decisions, then apply.
5. Verify with the commands above, including the coverage truth-check.
6. If a real recovery point is wanted as proof *before* compliance mode, the tagging change has to land inside the `changeable_for_days` window — with a daily policy the first point appears the next morning. Otherwise state plainly that the vault will lock empty.

## Related

- `eis-module-fix-release-consume` — module MR → manual release → consumer bump
- `customize-terraform` (client repo) — `_custom.tf` + ADR conventions
- `atlantis-debug` — when the plan/apply itself misbehaves
- Reference run: COEXT-108349, `aws11caasharevault`, CAA prod `144905517910` / `eu-west-3`
