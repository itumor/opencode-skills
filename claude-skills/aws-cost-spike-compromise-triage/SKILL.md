---
name: aws-cost-spike-compromise-triage
description: Use when an AWS account's bill or Cost Explorer widget jumps (e.g. "+2,122%", "cost analysis for this account", "why is this account $47k", "who is using Bedrock here", "account got hacked", sudden GPU EC2 / Bedrock Claude spend). Read-only procedure that separates a normal cost rise from a credential compromise (cryptomining / LLMjacking), finds the principal + timeline in CloudTrail, lists what is still billing, and writes a shareable report. Reference case GenAI dev 615299750085, 2026-10-14.
---

# AWS cost spike / compromise triage (read-only)

Everything here is a read. Terminating instances, deleting users or keys, and detaching policies are irreversible: list them as open items and let the user decide. Never `aws sso login` before probing (see step 0).

## 0. Identify the account + auth
- The screenshot rarely names the account. Match its "Current month" figure exactly: `aws ce get-cost-and-usage --region us-east-1 --time-period Start=<YYYY-MM-01>,End=<tomorrow> --granularity MONTHLY --metrics UnblendedCost`, run against each candidate profile (`aws_profiles` memory).
- Legacy profile expired? If `[sso-session eis-idc]` is live (probe `--profile PTO-Reference`), write a scratch config with `sso_session = eis-idc` plus the account id and role, then export `AWS_CONFIG_FILE=<scratch>`. No login needed.

## 1. Cost shape (Cost Explorer, always `--region us-east-1`)
Dump these to scratch JSON, then summarise with a `python3 -I file.py` script written via the Write tool (Bash heredocs trip guard R15):
- MONTHLY by `SERVICE`, last 6 months, for the baseline.
- DAILY by `SERVICE`, last ~35 days. A compromise shows as 1–3 days of large spend, then a drop at containment.
- Current month by `REGION` and by `USAGE_TYPE`. Sign of compromise: `*-BoxUsage:p4d/p5/g6e/g7*.48xlarge` in regions the team never uses, and Bedrock `*-MP:*tokens*` spread over 10+ regions.
- EC2 Compute filtered, grouped by `INSTANCE_TYPE` and `REGION`.
- `get-cost-forecast`. **It extrapolates the spike**; report the real estimate instead: MTD + remaining days × post-containment daily rate.
- CE lags ~24 h, so today shows $0.

## 2. What is still running or billing
- Every region: `describe-instances` (id, type, state, LaunchTime, KeyName, profile, public IP, Name tag). Attacker fingerprints: generic key pairs (`prod-N`), fake `prod`/`prd` tags, no instance profile, all launched within hours of each other.
- Stopped is not safe. A stopped instance can be restarted, and its EBS still bills: `describe-volumes --query "Volumes[?CreateTime>='<date>']"`.

## 3. Who did it (CloudTrail `lookup-events`, 90 days, per region)
- In each affected region: `RunInstances`, `StopInstances`, `CreateKeyPair`/`ImportKeyPair`. Group by `userIdentity.arn`, source IP, user agent and `errorCode`. Many `InsufficientInstanceCapacity`/`VcpuLimitExceeded` errors mean a scripted GPU grab.
- IAM writes: `EventSource=iam.amazonaws.com` in us-east-1, skipping `readOnly`. Look for `CreateLoginProfile`/`UpdateLoginProfile`/`CreateAccessKey` on other users (persistence), and the responder's `AttachUserPolicy AWSDenyAll`/`UpdateAccessKey Inactive`.
- `federated-user/<x>` = a `GetFederationToken` session minted from some IAM user's long-term key.
- Keys: `list-access-keys` + `get-access-key-last-used` for every user. Print only the last 4 characters of a key id, never full ids.

## 4. Attribute the money
- Incident cost = spike days − (normal daily × days). Split it into EC2 and Bedrock. For Bedrock, compare the per-region split during the spike with the baseline.

## 5. Report + handoff
Write `~/gitwork/iac/docs/<account>-cost-incident-<YYYY-MM>.md` with these sections: bottom line, monthly trend, service table, region/instance table, UTC timeline (who/IP/what), entry point (verified vs likely), open items. Usual open items:
1. Terminate the stopped attacker instances and delete their key pairs (snapshot first if forensics are needed).
2. Delete the compromised IAM users/keys.
3. Add AWS Budgets + Cost Anomaly Detection.
4. Restrict regions (SCP, or a deny policy if the account is outside the Org).
5. Open an AWS Support case for a fraud billing credit.

Give a caveman-style Slack paste. Save a project memory with the facts and the open items.
