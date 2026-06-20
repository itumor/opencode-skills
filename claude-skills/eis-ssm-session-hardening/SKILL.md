---
name: eis-ssm-session-hardening
description: >-
  Secure SSM Session Manager connections and enable session ("SSM Agent") logging on an EIS
  client/UAT environment via Terraform — private interface VPC endpoints (ssm/ssmmessages/ec2messages),
  a customer CMK for in-transit session encryption, a stage-scoped hardened Session document, and
  CloudWatch session logging with retention. Use when a ticket asks to "secure the SSM connections",
  "enable SSM Agent / Session Manager logs", "log SSM sessions", harden Session Manager, keep session
  logs N months, or check/enable CloudTrail + AWS Config + SSM logs for a client env (the CloudTrail/
  Config half is usually already covered by Control Tower — verify, don't rebuild). Encodes the two
  non-obvious blockers that make session logging silently fail. Reference: COEXT-105511 (CAA UAT,
  aws0caatestbld01, MRs !83/!86/!87), iac/projects/aws/credit-agricole/terraform.
---

# EIS SSM Session Manager hardening + session logging

Goal: SSM sessions to client hosts stay private (no public egress), are KMS-encrypted in transit,
and the full session transcript lands in CloudWatch with retention. Done via `_custom.tf` in the
per-client Terraform project, applied through Atlantis.

## CloudTrail / AWS Config first (usually CHECK-only)
These are commonly org-managed — verify before building anything (profile = the client SSO profile):
- `aws cloudtrail describe-trails` → expect a Control Tower org trail `aws-controltower-BaselineCloudTrail`
  (`IsOrganizationTrail=true`, multi-region, `IsLogging=true`, → a Log Archive account). That's the
  "compliance CloudTrail". No per-account trail needed if present.
- `aws configservice describe-configuration-recorder-status` → `recording:true` (EIS sets this per-account
  in `lower/infra/services/security_hub.tf`, delivering to the `audit` S3 bucket). Covers all stages.
- `aws ssm describe-instance-information` → target hosts `PingStatus Online`.

## The four Terraform pieces (UAT = `lower/test`; single account)
Apply order = Atlantis exec order (`parallel_apply:false` makes a single `atlantis apply` run them
ascending): **infra/services (13, CMK) → test/core (32, endpoints) → test/services (33, doc+log+IAM)**.
The CMK must exist before the doc/IAM reference it.

1. **`lower/test/core/vpc_endpoints.tf`** (append) — raw `aws_vpc_endpoint` Interface for
   `for_each = toset(["ssm","ssmmessages","ec2messages"])`, `private_dns_enabled=true`, one SG allowing
   443 from `concat([var.vpc["main"].cidr], var.vpc["main"].secondary_cidr_blocks)`, on the genuine
   private subnets `slice(module.vpc["main"].private_subnet_ids, 0, length(var.vpc["main"].subnets.private))`
   (interface endpoints allow only one subnet per AZ). Note: the `eis-vpc-endpoints` module is hardcoded
   to the EKS-capabilities service — NOT reusable here; use raw resources matching the S3-gateway style.

2. **`lower/infra/services/terraform_custom.auto.tfvars`** — add a CMK to the existing `kms` map
   (consumed by `kms_custom.tf`, module `terraform-aws-modules/kms/aws`):
   ```hcl
   "kms-ssm-session" = {
     description         = "CMK for SSM Session Manager in-transit session encryption - <TICKET>"
     enable_key_rotation = true
     default_policy      = true   # ROOT DELEGATION — see gotcha #2
   }
   ```

3. **`lower/test/services/ssm_session_custom.tf`** (new) — CloudWatch log group + a NAMED custom
   Session document (do NOT mutate the account-default `SSM-SessionManagerRunShell`; it's account-wide
   and would govern other stages). Key fields:
   ```hcl
   resource "aws_cloudwatch_log_group" "ssm_sessions" {
     name = "/aws/ssm/${local.project_prefix}sessions"
     retention_in_days = 365   # >= the ticket's floor
   }
   resource "aws_ssm_document" "session_manager" {
     name = "${local.project_prefix}SessionManagerRunShell"
     document_type = "Session"; document_format = "JSON"
     content = jsonencode({ schemaVersion="1.0", sessionType="Standard_Stream", inputs = {
       cloudWatchLogGroupName      = aws_cloudwatch_log_group.ssm_sessions.name
       cloudWatchEncryptionEnabled = false   # GOTCHA #1
       cloudWatchStreamingEnabled  = true
       kmsKeyId = "alias/${module.env_common_utility_infra.prefix_short}/kms-ssm-session"  # GOTCHA #3
       idleSessionTimeout = "20"; runAsEnabled = false
       shellProfile = { linux = "export PROMPT_COMMAND='history -a'; export HISTTIMEFORMAT='%F %T '" }
     }})
   }
   ```

4. **`lower/test/services/files/iam/ec2/<host>.json`** — add to the host's instance-role policy
   (eis-ec2 already attaches `AmazonSSMManagedInstanceCore`):
   - CW logs: `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams` on the
     `/aws/ssm/<prefix>sessions(:*)` ARNs.
   - **`logs:DescribeLogGroups` on `log-group:*`** — GOTCHA #4 (separate statement; list action).
   - KMS: `kms:GenerateDataKey`,`kms:Decrypt`,`kms:DescribeKey`, scoped via condition
     `ForAnyValue:StringLike { kms:ResourceAliases: "alias/*/kms-ssm-session" }`.

## GOTCHAS (each one silently breaks logging — found the hard way)

1. **`cloudWatchEncryptionEnabled=true` requires a customer CMK ON the log group.** With an AWS-owned-key
   log group, SSM REFUSES the session: client shows *"We couldn't start the session because encryption
   is not set up on the selected CloudWatch Logs log group"*; agent log: `Validation failed ... encryption
   is not set up`. → set it **false** (logs are still AWS-owned-key encrypted at rest; the in-transit
   channel stays CMK-encrypted via `kmsKeyId`). Only set `true` if you also `kms_key_id` the log group
   AND add a `logs.<region>.amazonaws.com` statement to the CMK key policy.

2. **CMK `default_policy=true`** (root delegation) so principals get key use via their IAM policies.
   Don't list the host role ARN in the key policy: the host role is created later in `test/services`
   while the CMK is created in `infra/services` — KMS validates principals and `PutKeyPolicy` fails if
   the role doesn't exist yet.

3. **Reference the CMK by alias LITERAL, not `data.aws_kms_alias`.** A data source fails at Atlantis
   plan time because the CMK is only *planned* (not applied) in another state:
   `Error: reading KMS Alias (alias/<prefix>/kms-ssm-session): empty result`. Use the string
   `"alias/${module.env_common_utility_infra.prefix_short}/kms-ssm-session"` (mirrors
   `lower/dev/services/eks_custom.tf` for kms-onesuite). Infra prefix resolves to e.g. `aws0caa`.

4. **The instance role needs `logs:DescribeLogGroups`** (not just `DescribeLogStreams`). The SSM agent
   calls DescribeLogGroups to validate the group before streaming; without it the session runs fine and
   is KMS-encrypted but **no logs are written** — agent log:
   `AccessDeniedException ... not authorized to perform: logs:DescribeLogGroups`.

## E2E verification (do this — don't trust "applied")
```bash
P="--profile <client> --region <region>"; H=<instance-id>; PFX=<prefix e.g. aws0caatest>
# 1. doc + endpoints + cmk + loggroup live
aws ssm describe-document $P --name ${PFX}SessionManagerRunShell --query 'Document.Status'
aws ec2 describe-vpc-endpoints $P --filters Name=tag:Issue,Values=<TICKET> --query 'VpcEndpoints[].State'
# 2. real session through the hardened doc (non-interactive; expect "encrypted using AWS KMS")
M="E2E-$(date +%s)"
{ sleep 4; printf 'echo %s\n' "$M"; printf 'whoami; hostname\n'; sleep 8; printf 'exit\n'; sleep 2; } \
  | aws ssm start-session $P --target $H --document-name ${PFX}SessionManagerRunShell
# 3. if no stream, diagnose via the agent log (Run Command), grep amazon-ssm-agent.log for cloudwatch/denied
aws ssm send-command $P --instance-ids $H --document-name AWS-RunShellScript \
  --parameters 'commands=["grep -iE \"cloudwatch|DescribeLogGroups|denied|Validation failed\" /var/log/amazon/ssm/amazon-ssm-agent.log | tail -20"]'
# 4. confirm transcript landed (stream name = sessionId; events have sessionData[])
aws logs describe-log-streams $P --log-group-name /aws/ssm/${PFX}sessions --order-by LastEventTime --descending --limit 3
aws logs get-log-events $P --log-group-name /aws/ssm/${PFX}sessions --log-stream-name <sid> --query 'events[].message'
```

## Bypass caveat (note on the ticket)
A NAMED custom doc only logs when operators pass `--document-name <prefix>SessionManagerRunShell`; a
plain `aws ssm start-session` uses the unhardened account-default doc (unlogged/unencrypted). This repo
can't prevent that — the StartSession principals are IdC permission sets. To enforce, add a condition
pinning `ssm:StartSession` to the custom document in the UAT IdC permission set (identity account; see
eis-idc-scoped-ssm-access). Raise with the IdC owner.

## MR lifecycle
Per-MR via Atlantis: branch `<TICKET>_<slug>` off fresh `main` → push → `glab mr create --assignee/--reviewer
mzivarts` → he approves → `glab mr note create <id> -m "atlantis apply"` (sequential exec order) → on
"Apply complete" `glab mr merge <id> --yes --remove-source-branch`. If a project is "currently locked by
an unapplied plan from pull !N", `atlantis unlock` that MR (re-plan it later). mzivarts is the terraform
approver. Then re-run E2E and Resolve the Jira ticket (REST v2 + JIRA_TOKEN from ~/.zshrc).
