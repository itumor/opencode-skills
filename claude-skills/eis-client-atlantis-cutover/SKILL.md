---
name: eis-client-atlantis-cutover
description: Move a client Terraform project off the shared EIS IaC Atlantis onto the project's OWN aws0<code>atlantis01 EC2 host. Use when the user says "switch to the project/EC2 Atlantis", "connect <client> Atlantis to GitLab", "flip use_iac to false", "point the webhook at the client's Atlantis", or when a client env has finished provisioning and should stop borrowing the shared IaC Atlantis. Encodes the ORDERING rule that makes or breaks it (two commits/two applies, never one), the four files that change, the `role_networkhub` exception, the webhook swap, and the orphaned-lock aftermath on the old host. Reference run: NN Japan MR !6 (COEXT-106779); pending run: AFA/American Fidelity.
---

# Client Atlantis cutover — shared IaC Atlantis → `aws0<code>atlantis01`

Every new client project is provisioned **through the shared EIS IaC Atlantis** (chicken-and-egg: the
project's own Atlantis host doesn't exist until `lower/infra/services` applies). Once
`aws0<code>atlantis01` is up and configured, the project switches to it. That switch **rewrites the
trust policy of the roles Atlantis assumes**, so the order of operations is the whole job.

Prefix note: `<prefix>` = `${region_code}${project_code}` (e.g. `aws02afa`, `aws06nnlj`), so the host
and roles are `aws02afaatlantis01`, `aws02afaatlantis01-plan-Role`, `aws02afaatlantis01-apply-Role`.

## Preconditions — all four, or don't start

| # | Gate | Check |
|---|---|---|
| 1 | `<prefix>atlantis01` EC2 exists | `aws ec2 describe-instances --profile <p> --filters Name=tag:Name,Values=<prefix>atlantis01` |
| 2 | Ansible `atlantis.yaml` playbook has run on it (docker_compose_atlantis) | the host serves HTTPS on its FQDN; `inventory/group_vars/atlantis.yaml` exists in the client ansible repo |
| 3 | **DNS delegation done** — `<prefix>atlantis01.infra.<region_code>.<domain>` resolves **from the GitLab server**, not just from your laptop | this is the IT/JCP-support ticket; file it EARLY, it is the long pole (AFA workshop #3 stalled here) |
| 4 | The Vault entry literally named **`GitLab webhook secret`** is known | you REUSE it; do not regenerate — see [[onesuite-scaffold-silent-gates]] gate 4 |

## The four file changes

| File | Change |
|---|---|
| `lower/infra/bootstrap/terraform.tfvars` | `iam.atlantis.use_iac: true → false` |
| `lower/infra/global.tfvars` | `role_default = "<prefix>atlantis01"` |
| `lower/dev/global.tfvars` (and every other stage's `global.tfvars`) | `role_default = "<prefix>atlantis01"` |
| GitLab → Settings → Webhooks | URL host → the new Atlantis; **same secret token**, same triggers (push, note/comment, merge request) |

**`role_networkhub` does NOT change** — it stays `aws0iacdeveks01-atlantis`. The Network Hub account
(729852324759) trusts only the shared IaC Atlantis principal; the client's EC2 role is not trusted
there. Verified on nnl-japan post-cutover.

What the flag actually drives (`lower/infra/bootstrap/`):
```hcl
# locals.tf
atlantis_name = var.iam.atlantis.use_iac ? "aws0iacdeveks01-atlantis" : "${local.project_prefix}atlantis01"
# iam.tf  → module "iam_atlantis"  name = "${local.atlantis_name}-${each.key}-Role"
trusted_arns = [var.iam.atlantis.use_iac
  ? "arn:aws:iam::182399717428:role/aws0iacdeveks01-atlantis-Role"          # IaC account
  : "arn:aws:iam::${local.vars.account_id_default}:role/${local.atlantis_name}-Role",  # this account's EC2 role
  one(data.aws_iam_roles.admin_permission_set.arns)]                        # + SSO AdministratorAccess
```
So flipping the flag **renames the plan/apply roles**. `aws_iam_role_policy_attachment.this` carries
`lifecycle { create_before_destroy = true }` precisely so the new role + attachments exist before the
old ones are destroyed — the running Atlantis does not revoke itself mid-apply.

## THE ORDERING RULE — two commits, two applies. Never one.

The merged diff looks like a single 4-line change. Applying it as one change **fails**: the moment
`role_default` flips, every provider assumes `<prefix>atlantis01-plan-Role`, which does not exist
until the bootstrap apply creates it → assume-role failure at plan time.

```
Commit A  ──  use_iac: true → false            (ONLY this file)
   └─ atlantis plan  -p lower-infra-bootstrap  (runs on the OLD/shared IaC Atlantis)
   └─ atlantis apply -p lower-infra-bootstrap  ← the LAST act of the shared Atlantis in this account
        creates <prefix>atlantis01-{plan,apply}-Role + attachments,
        destroys aws0iacdeveks01-atlantis-{plan,apply}-Role attachments (create_before_destroy)

Commit B  ──  role_default → <prefix>atlantis01 in ALL stage global.tfvars
   └─ swap the GitLab webhook URL (same secret) BEFORE re-planning
   └─ atlantis plan   ← now served by the NEW host; expect all projects to plan green
   └─ approve → atlantis apply anything still pending → merge LAST
```

Evidence (read it if you doubt the order): `iac/projects/aws/nnl-japan/terraform` **MR !6**
(COEXT-106779, merged 2026-07-28). Note timestamps show apply of `lower-infra-bootstrap` at 13:14
creating `aws06nnljatlantis01-{plan,apply}-Role` and destroying the deposed `aws0iacdeveks01-atlantis-*`
attachments, **then** commit `d3b6c789` at 13:17 flipping `role_default`, then re-plans of all 5
projects. Final squashed commit `2a7bb13` hides that ordering — do not copy it as one step.

## Verify

```bash
aws iam get-role --profile <p> --role-name <prefix>atlantis01-plan-Role \
  --query 'Role.AssumeRolePolicyDocument.Statement[].Principal.AWS' --output json   # → this account's atlantis01-Role + SSO admin
aws iam get-role --profile <p> --role-name aws0iacdeveks01-atlantis-plan-Role 2>&1  # → NoSuchEntity
grep -n 'role_default\|role_networkhub' lower/*/global.tfvars                       # → <prefix>atlantis01 / aws0iacdeveks01-atlantis
```
Then comment `atlantis plan` on any open MR — the reply must come from the **new** host (check the
Atlantis UI link in the comment) and every project must plan without an assume-role error.

## Aftermath traps

- **Orphaned locks on the OLD Atlantis.** Any lock the shared IaC Atlantis held for this repo survives
  the cutover, and `atlantis unlock` from a comment now routes to the NEW host ("all unlocked" while
  the orphan lives on). Clear it on the old host headlessly — skill **`atlantis-lock-troubleshooting`**.
- **Apply is approval-gated on both hosts.** `apply_requirements: [approved, undiverged]` is set in
  both the shared Atlantis (`argocd/argocd/components/atlantis/values.yaml`) and the client role
  (`ansible/roles/docker_compose_atlantis/defaults/main.yml`). An unapproved MR cannot apply.
- **Group allowlist differs per host.** Shared: `iac:plan, iac:apply, iac:unlock`. Client template /
  CAA: `iac:plan, oc-team:apply, oc-team:unlock` — i.e. **apply/unlock move to `oc-team`**. If your
  user isn't in the allowlisted group on the new host, apply silently isn't offered. Check
  `inventory/group_vars/atlantis.yaml` in the client's ansible repo before the session.
- **Renovate/CI still points at the repo, not the host** — nothing to change there.

## Rollback

Revert Commit B, then Commit A, and re-apply `lower-infra-bootstrap`. The shared Atlantis can no
longer do it (its role is gone), so run that one apply either **on the new host** (it still holds
apply rights until the revert lands) or **locally with SSO AdministratorAccess** — the plan/apply
roles also trust the account's admin permission set (`data.aws_iam_roles.admin_permission_set`), which
is the deliberate escape hatch. See [[eis-iac-terraform-local-apply]] for local-apply mechanics.

## Current fleet state (2026-08-31)

| Project | `use_iac` | `role_default` |
|---|---|---|
| credit-agricole, nnl-japan, pto-reference | `false` | own `atlantis01` |
| **american-fidelity (AFA)** | **`true`** — cutover PENDING, host `aws02afaatlantis01` (10.34.108.16) already running | `aws0iacdeveks01-atlantis` |
| axa-japan, v20-sandbox, pto-cicd, anlab | `true` | shared |
| network-hub | `true` | `aws0iacdeveks01-atlantis-nhub` (never cuts over) |

AFA is blocked only on precondition 3 (the domain-delegation ticket). See
[[project_afa_american_fidelity_lower]].
