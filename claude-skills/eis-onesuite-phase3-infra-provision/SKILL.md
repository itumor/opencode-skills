---
name: eis-onesuite-phase3-infra-provision
description: >
  Phase 3 of the EIS OneSuite platform-provisioning chain — provision the Shared/infra stage
  (network + toolchain EC2 fleet) of a new isolated client environment. Covers the network-hub RAM
  MR that shares the hub TGW + DNS resolver into the new account's OU, then the infra
  bootstrap→core→services applies driven through IaC Atlantis (NOT local terraform apply — the
  Atlantis assume-roles are trust-locked). Use when the user says "provision the infra/Shared stage
  for <client>", "apply infra bootstrap/core/services", "stand up the toolchain EC2 fleet
  (gitlab/jenkins/nexus/atlantis/sonar/keycloak/grok/sis/selenoid)", "the new account can't see the
  shared TGW", "add the SaaS OUs to ram_principals", "RAM-share the transit gateway / DNS resolver",
  or "why can't I terraform-apply the EIS Atlantis role locally (AccessDenied)". Sibling phases:
  eis-onesuite-phase0-prereqs (P0), eis-account-vending (P1), eis-onesuite-phase2-terraform-scaffold
  (P2), eis-onesuite-phase4-dev-provision (P4), eis-ansible-project-template (P5),
  argocd-cluster-onboarding (P6), eis-onesuite-phase7-app-handoff (P7); master:
  eis-onesuite-platform-provision.
---

# Phase 3 — Provision the Shared / `infra` stage

Provisions the **Shared services VPC + toolchain EC2 fleet** for a new isolated EIS client
environment. Assumes Phases 0–2 are done: account vended + StackSet-baselined (`eis-account-vending`),
and the Terraform repo scaffolded + pushed to `main` with the Atlantis webhook wired
(`eis-onesuite-phase2-terraform-scaffold`).

**Inputs you need from earlier phases:**
- `project_code` (e.g. `axajp`), repo path `iac/projects/aws/<repo>/terraform`, GitLab project id.
- `account_id_default` (the vended 12-digit ID), the account's SaaS OU id(s).
- Backend bucket `aws0<prefix>tfstate` already created by the account-vending StackSet.
- Atlantis execution-order groups from the rendered `atlantis.yaml`: **infra bootstrap=11, core=12,
  services=13** (dev core=22, services=23).

---

## Step 0 — Hard constraint: you (almost always) CANNOT `terraform apply` locally

The rendered providers assume `aws0iacdeveks01-atlantis-{plan,apply}-Role` in the new account
(see `lower/infra/global.tfvars` → `role_default`/`role_networkhub = "aws0iacdeveks01-atlantis"`).
That role's **trust policy is locked to the IaC Atlantis principal** — your SSO AdministratorAccess
session gets `AccessDenied` on `sts:AssumeRole`. Verify once, then stop trying:

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<account_id_default>:role/aws0iacdeveks01-atlantis-plan-Role \
  --role-session-name probe --profile <client-sso-profile>
# Expect: AccessDenied (trust = IaC Atlantis). This is correct, not a misconfig.
```

➡️ **All Phase-3 applies run through IaC Atlantis** on MR comments. Do not bypass with local apply
even "in emergency" here — the role chain won't let you. (The `add-lower-stage` /
`generate-new-project` "local bootstrap apply" path does NOT apply to this multi-account setup.)

The `role_default → aws0<prefix>atlantis01` switch happens **later** (after the `atlantis01` host
exists in Phase 5). For all of Phase 3, `role_default` stays `aws0iacdeveks01-atlantis`
(chicken-and-egg: the project's own Atlantis host isn't provisioned yet).

---

## Step 1 — network-hub RAM MR (GATES everything; additive; reviewer Markuss)

The shared hub TGW + DNS resolver are RAM-shared **only to specific OUs**. A brand-new SaaS account
won't see them until its OU is added to `ram_principals`. Without this, `infra/core`'s TGW spoke
attach + DNS resolver rules fail. (For EISSAASDEV-302 this was network-hub **MR !9, MERGED+APPLIED**
2026-06-18 — replicate the pattern for a new client/OU.)

Repo: `iac/projects/aws/network-hub/terraform`, file **`lower/infra/core/terraform.tfvars`**.

1. Clone if not local, then branch off `main`:
   ```bash
   git -C /Users/eramadan/gitwork/iac/projects/aws/network-hub/terraform pull --ff-only
   git -C /Users/eramadan/gitwork/iac/projects/aws/network-hub/terraform checkout -b feat/<client>-ram-share-EISSAASDEV-302
   ```
2. In `lower/infra/core/terraform.tfvars`, add the new account's OU ARN(s) to **BOTH** lists —
   `tgw.ram_principals` AND `resolver.ram_principals`. Additive only; do not remove or reorder
   existing principals. OU ARN form: `arn:aws:organizations::<mgmt-acct>:ou/o-<org>/<ou-id>`
   (org `o-kthbmcbbdg`, mgmt `455655288646` for EIS). For AXA Japan the OU was **SaaS/Lower
   `ou-mgtl-10u4x9xu`** (+ SaaS/Upper `ou-mgtl-fhbvbnpo` was added too, to cover future upper envs).
   If the tfvars share at OU granularity already (CAA pattern), you add the OU; if it shares per
   org-root you may not need a change — `grep -n "ram_principals" lower/infra/core/terraform.tfvars`
   first and match the existing granularity.
3. Run the local scanner on the diff before pushing (`verify-iac-changes` skill).
4. Push, open MR, reviewer **Markuss (mzivarts)** (terraform/iac routing).
5. **Apply-before-merge order** (EIS golden rule — see memory "Atlantis: apply before merge"):
   after Markuss approves, comment `atlantis apply` on the MR. **Verify the plan reads
   `N added, 0 changed, 0 destroyed`** (N = number of new RAM share associations, e.g. 4 for two
   OUs × {tgw,resolver}). A non-zero `destroyed`/`changed` means you edited an existing principal —
   STOP and fix. Only after the apply is green do you **merge**. (Reference: !9 applied as
   `4 added, 0 changed, 0 destroyed`.)
6. RAM shares here are **auto-accept org-wide**, so no manual accept in the new account is needed
   once the OU is a principal. Confirm with `aws ram get-resource-share-associations --profile
   <client-sso-profile> --association-type PRINCIPAL` (should list the hub TGW + resolver shares
   as `ASSOCIATED`).

**Gate cleared** = TGW + resolver RAM shares visible/associated in the new account. Now Phase-3
infra can attach.

---

## Step 2 — The initial-provisioning trigger question (scaffold already on `main`)

Open question to resolve with Markuss before applying: when the scaffold is already merged to `main`
with **no MR diff**, how do you make Atlantis run the first apply? Two viable patterns:

- **(A) `atlantis plan -p <project>` per stage, in execution order.** Comment on a tracking MR
  (or the repo's default Atlantis comment surface) `atlantis plan -p lower-infra-bootstrap`, review,
  `atlantis apply -p lower-infra-bootstrap`; repeat for `-p lower-infra-core` then
  `-p lower-infra-services`. Project names come straight from `atlantis.yaml`
  (`lower-infra-bootstrap` / `lower-infra-core` / `lower-infra-services`). This is the cleanest for
  an already-merged scaffold because it targets one project at a time and respects ordering manually.
- **(B) Re-seed via branch→MR.** Branch off `main`, touch the stage's tfvars (or just open the MR
  with the scaffold delta if `main` predates a needed edit), let autoplan fire per changed dir, then
  `atlantis apply` in execution-order groups (11→12→13) on that MR.

Default to **(A)** unless Markuss specifies otherwise — it avoids a no-op MR and gives explicit
per-project control. Either way, **apply strictly in execution order 11 → 12 → 13** and apply each
before merging (apply-before-merge). If using (B), Atlantis honors `execution_order_group` so a
single `atlantis apply` on the MR runs them in order; verify the comment output applies bootstrap
first.

> If autoplan doesn't fire at all on the MR, the webhook may be missing — Phase 2 created hook id 14
> → `atlantis-iac.dev.aws0.iac.aws.eislab.cloud/events`. See `atlantis-debug` skill.

---

## Step 3 — `infra/bootstrap` (order 11) — adopt the StackSet-created state + roles (≈no-op)

`lower/infra/bootstrap` is **mostly `imports.tf`** adopting resources the account-vending StackSet
already created: the state bucket `aws0<prefix>tfstate` + bucket policy/PAB/SSE/versioning, the
`<role_default>-{plan,apply}-Role` Atlantis roles, the `state_access` policy, and the role↔policy
attachments.

1. In the scaffold, `lower/infra/bootstrap/imports.tf` ships **fully commented out** (verbatim from
   the template — see the CAA reference). **Uncomment the `import { }` blocks** because the account
   was vended via the StackSet (bucket + roles pre-exist), so they must be adopted, not created.
   - The first block also uncomments `data "aws_caller_identity" "current" {}`.
   - `local.project_prefix` resolves to `aws0<project_code>` (e.g. `aws0axajp`); `local.vars.role_default`
     = `aws0iacdeveks01-atlantis` for now.
2. Commit that uncomment as part of the bootstrap MR/branch (it IS a real diff Atlantis can plan).
3. `atlantis plan -p lower-infra-bootstrap`: expect the imports to **adopt** existing resources →
   plan should be **0 to add, 0 to change, 0 to destroy** (pure import, ≈no-op). If you see "to add"
   for the bucket, the imports didn't match — check the bucket name is exactly `aws0<prefix>tfstate`
   and the role names match `role_default`.
4. `atlantis apply -p lower-infra-bootstrap`, confirm green, then proceed. (Lower stages have **no
   bootstrap** — only infra does; the dev state bucket is also created here.)

---

## Step 4 — `infra/core` (order 12) — Shared VPC + TGW spoke + private DNS + prefix lists

`lower/infra/core` builds the network. Key files: `vpc.tf`, `tgw.tf`, `dns.tf`, `prefix_lists.tf`,
`terraform.tfvars`. **No `vpn.tf` content** for the private/no-customer-VPN model (the file may exist
but `eis-vpn`/`vpn.tf` resources are empty — confirm `vpc.tf`/`tgw.tf` carry no VPN wiring).

| Module | What it does here |
|---|---|
| `eis-vpc` | **Shared** VPC, `create_igw=false` (private; template default), **custom hand-sized subnets** |
| `eis-tgw` (v3.0.x) | spoke attach to Network Hub via `providers = { aws = aws.networkhub, aws.peer = aws }`; consumes the RAM-shared TGW from Step 1 |
| `eis-dns` | private hosted zone(s): `<domain>` + `aws0.<domain>` (e.g. `axajp-eis.cloud` + `aws0.axajp-eis.cloud`); resolver rules consume the RAM-shared resolver |
| `prefix_lists` | `aws_ec2_managed_prefix_list` for `local`/`administrative`/**`workspaces`**/`eks`/`eis`/`all` — the **`workspaces`** prefix gates ingress in the WorkSpaces-private access model |

**CIDR / `/23` Shared trap (critical):** if the Shared VPC is a `/23` (it is for axajp:
`10.34.128.0/23`), the template's infra auto-subnet calc assumes a `/22` and places TGW subnets at
`base+3` → overflows into the Development `/23`. The Phase-2 scaffold must already have set
`intra_auto_calculate: false` + hand-sized subnets inside the `/23` (see
`eis-onesuite-phase2-terraform-scaffold`). **Verify before applying:**
```bash
grep -nE "intra_auto_calculate|10\.34\.(128|129)" \
  /Users/eramadan/gitwork/iac/projects/aws/<repo>/terraform/lower/infra/core/terraform.tfvars
```
For axajp the Shared subnets are: private `10.34.128.0/25` + `10.34.128.128/25`, TGW
`10.34.129.208/28` + `10.34.129.224/28` — all inside `10.34.128.0/23`, no overflow.

Apply: `atlantis plan -p lower-infra-core` → review (VPC, TGW attachment, zones, prefix lists; NO
IGW, NO VPN) → `atlantis apply -p lower-infra-core` → green.

**Verify after apply:**
```bash
aws ec2 describe-transit-gateway-attachments --profile <client-sso-profile> \
  --query 'TransitGatewayAttachments[].{id:TransitGatewayAttachmentId,state:State}'   # State=available
aws ec2 describe-internet-gateways --profile <client-sso-profile>                      # expect [] (no IGW)
```

---

## Step 5 — `infra/services` (order 13) — toolchain EC2 fleet + Cognito + Selenoid ASG + buckets

`lower/infra/services` ships the **full toolchain fleet out of the box** (validated render, no CAA
clone needed). Files: `ec2.tf`, `asg.tf`, `cognito.tf`, `s3.tf`, `backups.tf`, plus per-host IAM in
`files/iam/ec2/*.json`. The `short_name` auto-renders (e.g. `AXAJP`).

Default fleet (size/tune for the POC; only drop `grok01`/`sis01` if cost-cutting):

| Host | Role |
|---|---|
| `git01` | GitLab |
| `jnk01` | Jenkins |
| `bld01` | build host |
| `nexus01` | Nexus + S3 blob store |
| `atlantis01` | this project's Atlantis (the future `role_default` target) |
| `sonar01` | SonarQube |
| `keycloak01` | Keycloak OIDC |
| `grok01` | OpenGrok |
| `sis01` | Sisense |
| `selenoidasg01` | Selenoid test-automation ASG (mixed instances + spot) |

**TODO before applying:** replace the Cognito `metadata_url` placeholder in
`lower/infra/services/terraform.tfvars` with the real IdC SAML metadata URL from Phase 0. For axajp:
IdC app "AXAJP Lower Cognito" `ins-7223ce427d94d53c`, URL
`…/saml/metadata/NDU1NjU1Mjg4NjQ2X2lucy03MjIzY2U0MjdkOTRkNTNj`. The Cognito apply yields the SAML
audience `urn:amazon:cognito:sp:<pool-id>` to hand back to the IdC team; the ACS URL is
`https://<project_code>.auth.us-west-2.amazoncognito.com/saml2/idpresponse`.

**Gotchas to carry over:**
- **eis-ec2 root_block_device — pin ≥ v2.2.1.** v2.0.0–v2.2.0 silently drop `volume_size`/`type`/
  encryption → unencrypted AMI-default roots. Check the module ref before applying:
  ```bash
  grep -rn "eis-ec2.git?ref=" /Users/eramadan/gitwork/iac/projects/aws/<repo>/terraform/lower/infra/services/*.tf
  ```
  Ensure `?ref=v2.2.1` or newer. (Memory: "eis-ec2 v6 root_block_device rename".) Post-apply, verify
  every root volume is encrypted: `aws ec2 describe-volumes --profile <client-sso-profile>
  --filters Name=tag:Name,Values='aws0<prefix>*' --query 'Volumes[].{id:VolumeId,enc:Encrypted}'`.
- **eis-eks `ec2_group` substring matcher** — not exercised here (it bites in Phase 4 when wiring the
  build host into the EKS `access_mapping`), but note it now: the access-mapping `ec2_group` is a
  `.*<group>.*` regex, so a host-group acronym that *contains* another (e.g. `bld` ⊂ something)
  double-binds and fails apply. `axajp` host names are clear of `bld`/`jnk` collisions. Handled in
  `eis-onesuite-phase4-dev-provision` / `eis-build-host-provision`.
- **Selenoid golden AMI** — the ASG needs the golden image; that's built by an Ansible role in
  **Phase 5** (`eis-ansible-project-template`). If the ASG apply needs a specific AMI id and it's not
  yet built, either run the golden-image role first or let the ASG come up on the placeholder and
  refresh after Phase 5. No manual AMI hunt.

Apply: `atlantis plan -p lower-infra-services` → review (11 hosts + ASG + Cognito + S3 buckets
[nexus/ansible/audit] + AWS Backup) → `atlantis apply -p lower-infra-services` → green.

**Verify after apply:**
```bash
aws ec2 describe-instances --profile <client-sso-profile> \
  --filters Name=tag:Name,Values='aws0<prefix>*' \
  --query 'Reservations[].Instances[].{name:Tags[?Key==`Name`]|[0].Value,state:State.Name}' --output table
# Expect git01/jnk01/bld01/nexus01/atlantis01/sonar01/keycloak01/grok01/sis01 running
aws cognito-idp list-user-pools --max-results 10 --profile <client-sso-profile>   # AXAJP Lower pool present
```

---

## Step 6 — Hand-off to Phase 4

When all three infra projects are green:
- Network is up (Shared VPC, TGW attachment Active, private DNS resolving, prefix lists incl.
  `workspaces`), toolchain hosts are running, Cognito pool + S3 buckets + Backup exist.
- ➡️ Proceed to **`eis-onesuite-phase4-dev-provision`** (Development VPC + EKS + RDS + MSK + internal
  ALB/NLB + private ACM). Then Ansible config (`eis-ansible-project-template`), ArgoCD
  (`argocd-cluster-onboarding`), and app handoff (`eis-onesuite-phase7-app-handoff`).
- The toolchain VMs are *provisioned* here but *configured* in Phase 5. After the `atlantis01` host
  is configured, switch `role_default` → `aws0<prefix>atlantis01` in **both** `global.tfvars` files
  (`lower/infra/global.tfvars` and the dev stage's) and re-run plan to confirm zero-diff.

---

## End-to-end verification checklist (Phase 3 scope)
1. network-hub RAM MR applied `N added, 0 changed, 0 destroyed` and merged; new account sees TGW +
   resolver shares `ASSOCIATED`.
2. `infra/bootstrap` apply = pure import, 0/0/0; state bucket + Atlantis roles adopted.
3. `infra/core` apply green; TGW attachment `available`; **no IGW**; private zones resolve.
4. `infra/services` apply green; 9 toolchain hosts + Selenoid ASG running; root volumes encrypted
   (eis-ec2 ≥ v2.2.1); Cognito pool live with real IdC `metadata_url`.
5. All applies ran via **IaC Atlantis** (local apply correctly `AccessDenied`), in execution order
   11 → 12 → 13, **apply-before-merge** every time.

---

## Reference run: EISSAASDEV-302 (AXA Japan / axajp)
- account `586117079971` (AXA Japan Lower), OU SaaS/Lower `ou-mgtl-10u4x9xu` (+ SaaS/Upper
  `ou-mgtl-fhbvbnpo`); network hub `729852324759`; org `o-kthbmcbbdg`, mgmt `455655288646`.
- repo `iac/projects/aws/axa-japan/terraform` (project id 1579, subgroup id 1992); webhook hook id 14
  → IaC Atlantis. SSO profile `axajp`.
- Shared VPC `10.34.128.0/23` (`intra_auto_calculate: false`, hand-sized subnets); Dev VPC
  `10.34.130.0/23`. Root domain `axajp-eis.cloud` (zone pre-created on Route53).
- **network-hub MR !9 MERGED+APPLIED** 2026-06-18 (approved Markuss; `4 added, 0 changed,
  0 destroyed`) — added SaaS/Lower + SaaS/Upper to `tgw.ram_principals` + `resolver.ram_principals`.
  Phase-3 TGW gate cleared.
- Local `terraform apply` confirmed impossible: SSO admin `AccessDenied` assuming
  `aws0iacdeveks01-atlantis-{plan,apply}-Role` (trust locked to IaC Atlantis principal).
- Open: confirm with Markuss the canonical initial-provisioning trigger (Step 2, pattern A vs B) for
  an already-on-`main` scaffold before running the infra applies.
