---
name: eis-idc-scoped-ssm-access
description: Use when granting AWS access to support/external engineers in an EIS account via IAM Identity Center — "user gets AccessDeniedException on ssm:StartSession", "give the CyberArk/vendor team access to these VMs", scoped SSM Session Manager / RDP-over-SSM / secret-read access to tagged instances, creating a custom permission set + AD group, or verifying an IdC group assignment. Covers the EISHELP→OPS→IdC-admin split, a tag-scoped SSM policy, headless SSO device login, and what you can/can't self-verify.
---

# EIS IdC scoped SSM access grant

## Overview
External/support engineers need to reach specific EC2s but only have `ReadOnlyAccess` (no `ssm:StartSession`, no `secretsmanager:GetSecretValue`). Grant the minimum via a **custom Identity Center permission set + AD group**, scoped by instance **tag** (not instance id — ids churn on rebuild). Reference impl: CyberArk CAA, `CyberArkOperator` / `cyberark_caa_ops`, account 691064586749 (COEXT-105541, live 2026-06-15).

## Who does what (you cannot do it all)
| Step | Owner | Why |
|---|---|---|
| AD group create + membership | OPS, via **EISHELP Access Request** (issuetype 21400) | cloud team doesn't manage AD ([[eishelp-ad-group-requests]]) |
| AD→IdC sync | automatic (`CreatedBy: Identity_Sync`) | synced group shows as `name@exigengroup.com` |
| Permission set + account assignment | someone with **IdC admin** (e.g. Markuss) | EIS-IaC AdministratorAccess **CANNOT** — `sso:ListPermissionSets` / `sso:ListAccountAssignmentsForPrincipal` denied |
| Verify / test | you (account-side reads) + an engineer login | see Verification |

File the EISHELP request with both the AD group spec AND the full permission-set policy JSON inline so the IdC admin can copy-paste. EISHELP may route it back into the cloud project as an Action Item — that's fine.

## The tag-scoped policy (proven)
`ssm:StartSession` needs BOTH the instance resource (tag-conditioned) AND the session **documents** in Resource — the original AccessDenied named the `SSM-SessionManagerRunShell` document. AWS-managed docs use the account-less ARN form (`arn:aws:ssm:REGION::document/AWS-*`).

```json
{ "Version": "2012-10-17", "Statement": [
  {"Sid":"SessionToVMs","Effect":"Allow","Action":"ssm:StartSession",
   "Resource":"arn:aws:ec2:*:*:instance/*",
   "Condition":{"StringLike":{"ssm:resourceTag/Role":["CyberArkSIA","CyberArkPSM"]}}},
  {"Sid":"SessionDocuments","Effect":"Allow","Action":"ssm:StartSession","Resource":[
    "arn:aws:ssm:*:*:document/SSM-SessionManagerRunShell",
    "arn:aws:ssm:*::document/AWS-StartPortForwardingSession",
    "arn:aws:ssm:*::document/AWS-StartNonInteractiveCommand"]},
  {"Sid":"ManageSessions","Effect":"Allow","Action":["ssm:TerminateSession","ssm:ResumeSession"],
   "Resource":"arn:aws:ssm:*:*:session/*"},
  {"Sid":"ReadCreds","Effect":"Allow",
   "Action":["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret","secretsmanager:ListSecretVersionIds"],
   "Resource":"arn:aws:secretsmanager:*:*:secret:aws*cyberark*/*"},
  {"Sid":"Discovery","Effect":"Allow","Action":["ssm:DescribeInstanceInformation","ssm:DescribeSessions","ssm:GetConnectionStatus","ec2:DescribeInstances","secretsmanager:ListSecrets"],"Resource":"*"}
]}
```
Design notes: `ec2:*:*` (account/region wildcards) keeps the set reusable across accounts — scoping is the tag, not the ARN. `DescribeSecret`+`ListSecretVersionIds`+`ListSecrets` are needed for **console** secret viewing (CLI `GetSecretValue` alone doesn't light up the console).

⚠️ **TerminateSession self-scope trap (hit live, COEXT-105281):** do NOT scope session terminate/resume to `session/${aws:username}-*`. `aws:username` is populated ONLY for IAM users — for SSO/assumed-role principals it is **empty**, so the ARN resolves to `session/-*` and never matches the real session id (`<role-session-name>-<rand>`, e.g. `dzvenyhorodskyi@eisgroup.com-abc`). Symptom: connect works (StartSession + the shell/RDP/secret all succeed) but `AccessDeniedException ... ssm:TerminateSession on resource: .../session/<email>-<rand>` fires at disconnect; sessions then linger until server auto-expiry. There is NO IAM Resource policy variable equal to the SSO role-session-name, so self-only scoping is impossible for SSO — use `session/*` (the worst case is an operator killing another active SSM session, not an escalation). Reproduce as the role: start a session, `aws ssm terminate-session --session-id <id>` → if `${aws:username}` scope is in place you get denied on `session/None`. **A permission-set policy edit by the IdC admin takes effect immediately on the live assumed-role session — no re-login / re-assume needed** (verified: terminate went from AccessDenied to success on the next call). So an engineer who hit the error just retries; don't tell them to log out.

## Verification — what you CAN and CANNOT self-check
- **Can** (account-side, any admin): role provisioned → `aws iam list-roles | grep <PermSetName>` shows `AWSReservedSSO_<name>_<hash>`; group synced + members → `aws identitystore list-groups/list-group-memberships/describe-user` (identity store `d-90676df1bc`, region us-east-1) — these work under EIS-IaC AdministratorAccess.
- **Can** (if added to the set yourself): assume it via a sibling AWS profile (`sso_role_name=<PermSet>`, same account/region, reuse SSO token) and run the full matrix incl. a **negative test** — session to a non-tagged instance MUST return AccessDenied.
- **CANNOT**: confirm the permission set is assigned to the **GROUP** vs only your user — `sso-admin` reads are denied to non-IdC-admins, and the provisioned IAM role's existence only proves *someone* is assigned. **The only proofs of group assignment are: an IdC-admin console check, or one group-member engineer doing `aws sso login` and seeing the role appear for the account.** Don't claim 100% without one of those.

## Headless SSO + test mechanics
- Device login in a non-TTY harness: run `aws sso login` as a **persistent background task** (survives across tool calls so the device code stays valid for approval); a foreground `&` dies with its shell and invalidates the code.
- `aws ssm start-session` errors `Cannot perform start session: EOF` without a TTY → wrap: `script -q /dev/null aws ssm start-session ...`.
- Interactive shell capture races the prompt → `{ sleep 6; printf 'cmd\n'; sleep 4; printf 'exit\n'; } | script -q /tmp/o aws ssm start-session --target <id>`.
- RDP-over-SSM check: background `AWS-StartPortForwardingSession portNumber=3389,localPortNumber=13389`, then `nc -z localhost 13389`.

## Jira mechanics for the handover
- Move a worklog between tickets: `DELETE /issue/<k>/worklog/<id>` (204) then re-`POST` on the right key. Find your id by filtering `worklogs[].author.name` + `timeSpentSeconds`.
- Resolve (COEXT transition id `5`) requires only `{"resolution":{"name":"Fixed"}}`. Assign: `PUT /issue/<k>/assignee {"name":"<user>"}`. Worklog `started` `YYYY-MM-DDT08:00:00.000+0000` lands same-day in both PDT and EEST.

See also [[coext105281-cyberark-caa-uat]], [[eishelp-ad-group-requests]], skill `cyberark-eis-install`.
