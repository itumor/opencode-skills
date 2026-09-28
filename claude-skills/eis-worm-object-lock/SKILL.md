---
name: eis-worm-object-lock
description: Roll out WORM (S3 Object Lock COMPLIANCE + AWS Backup Vault Lock + a CloudTrail trail in the client's own account) for an EIS OneSuite client, including "BAM logs in WORM", "Object Lock on backup buckets / CloudTrail", and "provide configuration evidence" asks. Use when a ticket says WORM, Object Lock, immutable logs/backups, BAM retention, or asks to enable Object Lock on an existing bucket, or when a plan shows an S3 bucket "+/- create replacement" after object_lock_enabled flips. Reference run: COEXT-110091 (CAA upper, credit-agricole/terraform !166 + !179, eis-cloudtrail v1.0.0, template/client !48).
---

# EIS WORM rollout (Object Lock, Vault Lock, CloudTrail)

Every control here is COMPLIANCE mode. Once data lands, nobody (root and AWS Support included) can delete it before retention expires, and a bucket holding locked versions cannot be deleted. Put the retention values in front of the user **before** the apply, and never write test objects into a locked bucket.

## 1. Map the ask to real storage first
- **BAM** (Business Activity Monitoring) is rows in the app RDS (the "BAM Activity aggregate table"), not files. S3 Object Lock cannot attach to it. There are two honest layers:
  1. Tag the RDS `Backup = "<daily policy tag>"` so its snapshots land in the Vault-Locked vault. For a Multi-AZ **cluster** the tag reaches `aws_rds_cluster` through eis-rds `var.tags`; the vault's resources need `arn:aws:rds:*:*:cluster:*`.
  2. Create an Object Lock landing bucket (7 y). The export job into it is **app/data-eng scope**: say so, don't invent one.
- **CloudTrail:** the Control Tower org trail lives in the log-archive account, which the client repo can't change or template. Create a trail in the client's own account with **`eis-cloudtrail`** (`?ref=v1.0.0`+).
- **Retention:** read the client's requirements repo before picking numbers. CAA R-COMP-2 gives CloudTrail ≥ 1 y, audit ≥ 7 y, CloudWatch ≥ 90 d. A vault's `min_retention_days` is permanent after `LockDate`. Unknown requirement IDs (e.g. "ER10 vs ER30"): search Jira JQL `text ~`, Slack and the architecture repo. If there are 0 hits, reconcile the *numbers* across design vs live in an ADR and label it an interpretation.

## 2. Object Lock: new bucket vs existing bucket
- **New bucket:** eis-s3 ≥ v2.2.0, `object_lock_enabled = true`, `object_lock_configuration = { rule = { default_retention = { mode = "COMPLIANCE", days|years = N } } }`, versioning enabled.
- **Existing bucket:** do NOT flip the module flag. It is ForceNew on `aws_s3_bucket`. If the bucket's name feeds another module (e.g. eis-eks `s3_csi_driver_bucket_names`), Terraform plans `+/- create replacement and then destroy`. The same-name CreateBucket then fails `BucketAlreadyOwnedByYou` mid-apply, after the `-/+` versioning/PAB/SSE/lifecycle sub-resources may already have been removed. Two steps instead:
  1. A standalone `aws_s3_bucket_object_lock_configuration` (provider v6 enables Object Lock in place on a versioned bucket). The plan should show 1 add and no bucket change. Apply it.
  2. **In the SAME MR, before merging** (push a second commit after the step-1 apply, re-plan, apply): set the module flag + config (a no-op now that AWS reports `Enabled`) and add
     ```hcl
     moved {
       from = aws_s3_bucket_object_lock_configuration.<name>
       to   = module.s3["<key>"].module.s3_bucket.aws_s3_bucket_object_lock_configuration.this[0]
     }
     ```
     Expect 0/0/0 plus one "has moved to" (possibly `~ years 0 -> null` in place). Leave a tfvars comment that the flag must never go back to false.
  - **Never merge between step 1 and step 2.** CAA 2026-09-23: !166 merged right after the step-1 apply to free the locks, so `main` held `object_lock_enabled = false` against a live-locked bucket. The next unrelated stage MR (!177) planned `object_lock_enabled = true -> false # forces replacement` (`+/-` on the bucket, 7 add / 1 change / 6 destroy). The step-2 MR then got closed before it planned. If `main` is in that state, block every other plan in the dir until step 2 is applied.
- Check that the bucket is empty before any replace: `aws s3api list-object-versions` (versions **and** delete markers).

## 3. CloudTrail via eis-cloudtrail
- Pass `name = "${local.project_prefix}trail"` and `s3_bucket_name = module.s3["cloudtrail"].name`. The delivery bucket policy grants `cloudtrail.amazonaws.com` GetBucketAcl + PutObject on `AWSLogs/<acct>/*` with `bucket-owner-full-control`, scoped by `aws:SourceArn` to that trail name.
- The module already has the SNS-publish KMS grant and CloudWatch wiring. If you ever hand-roll a trail: an SNS topic encrypted with the trail CMK needs its own `cloudtrail.amazonaws.com` GenerateDataKey*/Decrypt grant, or notifications fail silently.

## 4. Template
Client template `upper/share/services` (template/client ≥ !48) already stamps the baseline: vault + Vault Lock, eis-s3 passthroughs, eis-cloudtrail, cloudtrail bucket 365 d, bamlogs bucket 7 y. For a new client, check the answers, then set the retention values before the first apply.

## 5. Plan reading and apply
- Read the change lines, not the counts. Any `aws_s3_bucket ... must be replaced` or `+/-` on a bucket means stop.
- `atlantis apply` is the user's comment. The harness R3 guard even blocks read-only commands whose text contains that phrase, so poll for the bot's `Ran Apply` note instead.
- Applying holds the project locks. Merge right after the LAST apply of the MR (never between the step-1 and step-2 applies of §2), and tell the owners of other MRs on the same dirs to rebase before re-planning (a stale base shows your new resources as destroys).

## 6. Evidence (paste into the ADR and Jira)
```bash
export AWS_PROFILE=<client>-ReadOnly AWS_REGION=<region>
for b in <buckets>; do aws s3api get-object-lock-configuration --bucket "$b"; aws s3api get-bucket-versioning --bucket "$b"; done
aws cloudtrail get-trail-status --name <prefix>trail   # IsLogging + Latest{Delivery,CloudWatchLogsDelivery,Notification}Time, all *Error null
aws s3api list-object-versions --bucket <prefix>cloudtrail --prefix AWSLogs/<acct>/CloudTrail/ --output json   # pick a *.json.gz, parse with python (zsh won't word-split)
aws s3api get-object-retention --bucket <prefix>cloudtrail --key <key> --version-id <vid>   # COMPLIANCE + RetainUntilDate
aws backup describe-backup-vault --backup-vault-name <vault>   # LockDate passed = compliance; NumberOfRecoveryPoints
aws resourcegroupstaggingapi get-resources --tag-filters Key=Backup,Values=<tag>
aws backup list-recovery-points-by-backup-vault --backup-vault-name <vault>   # after the next 03:00 UTC run
```
The first trail delivery takes about 2–5 min after `StartLogging`. A vault with 0 recovery points is not protecting anything yet, so say that plainly.

## Related
`eis-backup-vault-lock` (vault creation, retention floor, `LockDate` vs `Locked`) · `eis-module-fix-release-consume` · memories `eis_s3_object_lock_v220`, `eis_cloudtrail_module_v100`, `bam_business_activity_monitoring`, `aws_backup_selection_single_tag_tier`.
