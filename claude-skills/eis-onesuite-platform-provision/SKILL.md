---
name: eis-onesuite-platform-provision
description: >-
  Master orchestrator for standing up a brand-new full-blown EIS OneSuite client/POC
  environment end to end — a complete isolated Dev environment in its own AWS account + VPC,
  modeled on Credit Agricole (CAA) Dev: account vending, Terraform infra (network + toolchain
  EC2 fleet + EKS/RDS/MSK/LBs), Ansible delivery toolchain (GitLab/Jenkins/Nexus/SonarQube/
  Keycloak/OpenGrok/Sisense/Selenoid), ArgoCD cluster onboarding, and the app-layer handoff.
  Use when the user says "provision a new OneSuite environment", "onboard a new client/POC end
  to end", "stand up a full dev environment like CAA", "new full-blown dev env", "create a new
  full client environment from scratch", or "do the whole EISSAASDEV-302 provisioning". This is
  the conductor: it sequences the 8 phases (P0–P7) and invokes each phase's own skill in order.
  Do NOT use for single-layer asks (just a new terraform project, just onboarding a cluster,
  just an ansible repo) — go straight to that phase's skill instead.
---

# EIS OneSuite — Full Platform Provisioning (Master Orchestrator)

> ⚠️ **Maturity:** this skill set is distilled from a **single first run — EISSAASDEV-302 (AXA Japan
> / axajp)** — and is **not yet battle-tested**. Validate + correct each phase on the **next customer
> onboarding** before treating it as canonical. Known still-open items from the first run: the
> `infra/bootstrap` import reconciliation (eis-s3 `attach_policy`/`aws_s3_bucket_policy` + StackSet
> drift) and the Vault `secret2/data/<project_code>` population script. Treat phase steps as a strong
> guide, not gospel; cross-check against the CAA reference project as you go.

This skill conducts the **end-to-end** provisioning of a new, isolated, full-blown EIS OneSuite
client/POC Dev environment — its **own AWS account, own VPCs, own delivery toolchain (GitLab/
Jenkins/Nexus/etc.), own EKS cluster**, modeled on **Credit Agricole (CAA) Dev**. It does not do
the work itself; it **sequences 8 phases and delegates each to a dedicated skill** via the Skill
tool.

**Canonical runbook (wiki-derived):** `/Users/eramadan/gitwork/iac/EIS-OneSuite-Platform-Provisioning-Runbook.md`
(EIS OneSuite Platform Creation Workflow, Steps 1–4, TF Modules Catalog, "Vault – Rules and
Structure" — wiki.eisgroup.com/spaces/Devops). Read it alongside this skill.

When NOT to use this skill: a single-layer request (one new TF project, one cluster onboard, one
ansible repo). Jump straight to that phase's skill below.

---

## 0. How to drive this orchestration

1. **Lock the decisions** (Section 2 template) with the user/stakeholders BEFORE any spend.
2. **Work the phases strictly in order P0 → P8.** For each phase, **invoke its skill via the
   Skill tool** (do not reimplement the phase here). Carry the outputs of each phase forward as
   inputs to the next.
3. **Respect the human/Atlantis gates** (Section 4) — never apply prod-mutating Terraform locally;
   it goes through **IaC Atlantis** on a GitLab MR.
4. **Track everything against the master Jira ticket** and tag all resources `Issue=<ticket>`.
5. **Close with verification (P8).** After the app-handoff (P7), invoke **`eis-onesuite-e2e-verify`**
   to run the end-to-end health sweep (account → TF stages → network → EKS/data → Cognito → ArgoCD
   all-Synced+Healthy) and **sign off the env**. The env is not "done" until P8 is green.

---

## 1. Phase → skill map (invoke each, in order)

| Phase | What it does | Skill to invoke | Status |
|---|---|---|---|
| **P0** | Pre-reqs & coordination — CIDR allocation, root DNS, IdC SAML metadata, TGW/RAM sharing, Vault path, cost sign-off, approach confirmation | **`eis-onesuite-phase0-prereqs`** (NEW) | invoke first |
| **P1** | Vend the dedicated AWS account, baseline StackSet, get the 12-digit `account_id_default` | **`eis-account-vending`** (EXISTS) | invoke |
| **P2** | Scaffold `iac/projects/aws/<client>/terraform` from the `client` Copier template; GitLab + Atlantis webhook + Renovate onboarding | **`eis-onesuite-phase2-terraform-scaffold`** (NEW) | invoke |
| **P3** | Provision the **infra** stage via Atlantis — Shared VPC + TGW + private DNS + the full toolchain EC2 fleet | **`eis-onesuite-phase3-infra-provision`** (NEW) | invoke |
| **P4** | Provision the **dev** stage via Atlantis — EKS + RDS + MSK + internal ALB/NLB + private ACM + S3; wire build host into EKS access mapping | **`eis-onesuite-phase4-dev-provision`** (NEW) | invoke |
| **P5** | Scaffold `iac/projects/aws/<client>/ansible` from the ansible Copier template; configure the delivery toolchain (GitLab/Jenkins/Nexus/Sonar/Keycloak/OpenGrok/Sisense/Selenoid) | **`eis-ansible-project-template`** (EXISTS) | invoke |
| **P6** | Onboard `aws0<client>deveks01` into the multi-cluster ArgoCD hub with the standard dev component suite | **`argocd-cluster-onboarding`** (EXISTS) | invoke |
| **P7** | App-layer **handoff** doc to the delivery team (ref-impl 26.100 on the new GitLab/Jenkins) — out of scope for the IaC monorepo | **`eis-onesuite-phase7-app-handoff`** (NEW) | invoke |
| **P8** | **End-to-end verification / sign-off** — account/IAM, all TF stages applied, network/TGW, EKS + node groups + addons, RDS/MSK, internal ALB/NLB, Cognito SAML, and ArgoCD all-Synced+Healthy; the final health gate that closes the env | **`eis-onesuite-e2e-verify`** (NEW) | invoke last |

> **Invocation rule:** at each phase, call the Skill tool with the exact skill name above. P1/P5/P6
> already exist; P0/P2/P3/P4/P7 are the `eis-onesuite-phaseN-*` skills, and P8 is
> `eis-onesuite-e2e-verify`. Do not recreate or rename them. The `eis-build-host-provision` skill is
> a helper used *inside* P3/P4 (toolchain build host + EKS access entry) — let those phase skills
> call it.

---

## 2. Locked-decisions template (fill BEFORE P0)

Confirm and record these with the business/infra owners. These map 1:1 onto the Copier answers in
P2 (terraform) and P5 (ansible).

| Param | Value to capture | Notes / default |
|---|---|---|
| AWS account name / OU | `<Client> LW` / `SaaS / Lower` | account-vending verifies the OU exists, does not create it |
| `project_code` | short kebab/lower token (e.g. `axajp`) | drives every resource name (`aws0<code>deveks01`, `aws0<code>tfstate`) |
| `full_project_name` | human name (e.g. `AXA Japan POC`) | repo path may differ (e.g. `axa-japan`) |
| Region / `region_code` | `us-west-2` / `aws0` | "Oregon" = `us-west-2`; "Asian region" in tickets = **app config**, not AWS region |
| Network Hub account | `729852324759` | fixed |
| Cluster name | `aws0<code>deveks01` | K8s 1.35 |
| Stages / VPCs | **2 VPCs**: **Shared** (`lower/infra`) + **Development** (`lower/dev`) | **dev-only** lower stage; add `test` later via the **`add-lower-stage`** skill |
| Access model | **Private (CAA-style)**: no IGW, internal ALB + NLB, reached via EIS Amazon WorkSpaces over TGW | **No public ALB / no WAF / no public ACM** by default |
| Customer VPN | **None** (TGW to Network Hub only) | no `eis-vpn`/`vpn.tf` in `lower/infra/core` |
| Toolchain fleet | **Full CAA fleet** (git01/jnk01/bld01/nexus01/atlantis01/sonar01/keycloak01/grok01/sis01/selenoidasg01) | drop `grok01`/`sis01` only to cost-cut |
| ArgoCD secret backend | **AWS Secrets Manager** | CAA-style; no Vault dependency for ArgoCD |
| Root DNS | `<code>-eis.cloud` (ArgoCD ingress `dev.aws0.<code>-eis.cloud`) | zone provisioned by DNS team in P0 |
| CIDR (reserved `/21`) | `<base>/21` → **Shared `<base>/23`** + **Development `<base+512>/23`** | second `/22` reserved for future stages |
| Vault path | `secret2/data/<project_code>` | **NOT** `secret2/data/rnd/cicd/3.0/…`; request creation in P0 |
| Master Jira | `<TICKET>` | tag all resources `Issue=<TICKET>` |

**CIDR sub-allocation pattern** (from a reserved `/21`):
- Shared VPC (`lower/infra`): first `/23`
- Development VPC (`lower/dev`): second `/23`
- Remaining `/22` reserved (e.g. for a future `test` stage)
- Pod CIDR (`100.64.x` CGNAT, VPC-local, not TGW-routed) and EKS service CIDR (`10.202.0.0/16`,
  k8s-internal) keep Copier defaults — not globally routed, safe to reuse across clients.

---

## 3. Cross-cutting gotchas (apply across phases)

- **`CreateAccount` is management-account-only.** Account vending's create step runs only in the
  Org **management account** (e.g. `455655288646`). A delegated-admin (`Audit`) account and your own
  SSO both get `AccessDenied`. If you lack mgmt creds, **hand off the create+baseline to whoever
  holds them** (e.g. Markuss) and resume at P2 with the returned 12-digit `account_id_default`.
  (Handled inside `eis-account-vending`.)
- **Role trust → applies go via IaC Atlantis, NOT local.** The bootstrap chain has the **shared
  EIS-IaC Atlantis role** (`aws0iacdeveks01-atlantis-{plan,apply}-Role`) assume into the new
  account (chicken-and-egg: the project's own `aws0<code>atlantis01` host doesn't exist yet). That
  role's **trust is locked to the IaC Atlantis principal** — your SSO admin **cannot** assume it.
  So **all infra/dev applies run through IaC Atlantis on a GitLab MR**, not `terraform apply` local.
  After the project's `atlantis01` host is provisioned (P3/P5), switch `role_default` →
  `aws0<code>atlantis01` in **both** `global.tfvars` files.
- **jira-lint / conventional-commit allowlist.** CI commit-msg lint allows
  `(feat|fix|chore|docs|refactor|test)(scope): COEXT|GENESIS|NOJIRA|EISSAASDEV-### - message`.
  **`ci` is NOT in the allowlist.** When a fix-up would collide with the lint, **rebase, don't
  merge** (merge commits trip the `--no-merges` lint loop).
- **`/23` Shared infra auto-calc trap.** The `client` template's **infra** auto-subnet calc assumes
  a `/22`: it places TGW subnets at `base+3`, which **overflows a `/23` and collides with the
  Development range**. For a `/23` Shared VPC you **must** set `intra_auto_calculate: false` and
  hand-size subnets inside the Shared `/23` (P2 Copier answers). The Development `/23` auto-calc is
  fine — the lower-stage generator is designed for `/23`.
- **SAML chicken-and-egg (Cognito).** You give the IdC team the **ACS URL**
  `https://<code>.auth.<region>.amazoncognito.com/saml2/idpresponse` and they give you the **SAML
  metadata URL** for `cognito metadata_url` in `lower/infra/services/terraform.tfvars`. But the
  **SAML audience** `urn:amazon:cognito:sp:<pool-id>` is only known **after** the infra/services
  Cognito applies — so exchange ACS↔metadata first, apply, then hand back the audience.
- **TGW is RAM-shared to the PTO OU only.** The Network Hub's TGW + DNS-resolver are auto-accept
  RAM shares scoped to **PTO OU**, so a fresh SaaS/Lower account **won't see them**. P0 must land a
  `network-hub` MR **adding the SaaS/Lower (and SaaS/Upper) OUs to the RAM principals** before the
  P3 TGW attach can succeed.
- **eis-eks `ec2_group` substring matcher.** Access-mapping `ec2_group` compiles to a
  `.*<group>.*` regex; a host-group acronym that *contains* another (e.g. a name containing `bld`/
  `jnk`) **double-binds and fails apply**. Verify host-group names are collision-free when wiring
  the build host into the EKS access mapping (P4, via `eis-build-host-provision`). Also: the entry
  is plan-time-skipped if the role doesn't exist yet → **apply the host before the access entry**.
- **eis-ec2 pin ≥ v2.2.1.** v2.0.0–v2.2.0 silently drop root `volume_size`/`type`/encryption
  (AMI-default unencrypted roots). Pin ≥ v2.2.1 in the toolchain fleet (P3) and verify volumes
  post-apply.
- **Lower stages have NO bootstrap.** Only `infra` has a bootstrap state; the dev state bucket is
  created in `infra/bootstrap`. Rendered `atlantis.yaml` for dev-only = **5 projects** (infra
  bootstrap/core/services + dev core/services).

---

## 4. Sequencing + human / Atlantis gates

Execution-order (dev-only, via Atlantis): `infra` bootstrap=**11** → core=**12** → services=**13**;
then `dev` core=**22** → services=**23**.

**Gates — do NOT cross without the named approval/condition:**
1. **Approach confirmed greenlit** (P0) before any account-vending **spend**.
2. **Cost / BoM signed off** by the business owner before P3 applies (full delivery env is
   significant for a POC).
3. **`network-hub` RAM MR merged + applied** (P0) before P3 TGW attach.
4. **Account vended + StackSet baseline present** (P1) before P2 scaffold push.
5. **Every Terraform apply goes through IaC Atlantis on an MR** — never local apply (role trust).
   Order: `atlantis apply` → wait green → smoke test → **merge LAST** (never merge first).
6. **MR reviewer routing:** terraform/iac/renovate → **Markuss (mzivarts)**;
   ansible/argocd/helm/gitops → **eramadan**.
7. **ArgoCD MRs may merge once render/validate/unittest are green** — don't wait on slow checkov.
8. **IdC permission-set assignment** for your SSO is done by the IdC admin (Markuss) after
   provisioning — wait for it; you cannot self-grant.
9. **Vault `secret2/data/<code>`** must be requested + created/assigned (P0) before P5 populates it
   (population uses an undocumented script — escalate / use the wiki "Vault – Rules and Structure").

---

## 5. Reference run: EISSAASDEV-302 (AXA Japan / axajp)

A paid POC for AXA Japan, executed as a **full-blown isolated Dev env** (greenlit by Girts/Aurimas;
approach-risk flag from Aleh→Viktoras to re-confirm reuse-vs-new). Locked values: `project_code=axajp`,
`full_project_name=AXA Japan POC` (repo `axa-japan`), region `us-west-2`/`aws0`, cluster
`aws0axajpdeveks01`, domain `axajp-eis.cloud`, reserved CIDR `10.34.128.0/21` → Shared
`10.34.128.0/23` + Development `10.34.130.0/23`, **Private** access (WorkSpaces over TGW, no public
ALB/WAF), full CAA toolchain fleet, ArgoCD backend = Secrets Manager, Vault path `secret2/data/axajp`.

**Current status (2026-06-18):**
- **P0** — root zone `axajp-eis.cloud` live on Route53 ✓; IdC SAML metadata received + wired (app
  "AXAJP Lower Cognito" `ins-7223ce427d94d53c`) ✓; **`network-hub` MR !9 MERGED + APPLIED** (SaaS/
  Lower `ou-mgtl-10u4x9xu` + SaaS/Upper `ou-mgtl-fhbvbnpo` added to TGW + DNS-resolver RAM shares →
  Phase-3 TGW gate cleared) ✓; cost signed off ✓; Atlantis webhook created (hook id 14) ✓; Vault
  `secret2/data/axajp` ⏳ (knowledge-gap on the population script — escalate).
- **P1** — account **`586117079971`** (`AXA Japan Lower`, `eis-pnt-aws+axajp@eisgroup.com`) ACTIVE
  in SaaS/Lower; StackSet baseline ran (state bucket `aws0axajptfstate`, bootstrap roles
  `aws0iacdeveks01-atlantis-{plan,apply}-Role` present); my access = AdministratorAccess via
  `oc-team` IdC; SSO profile `axajp`. Done (Markuss ran `CreateAccount` from mgmt acct
  `455655288646`). ✓
- **P2** — scaffolded + pushed: `projects/aws/axa-japan/terraform` (Copier v1.3.0, `/23` custom
  Shared subnets, fmt clean); GitLab subgroup id 1992 + project id 1579; `atlantis.yaml` → 5
  projects. **TODO:** add Markuss as reviewer; onboard Renovate. ✓ (scaffold)
- **P3** — **NEXT**: apply via IaC Atlantis (local apply impossible — SSO can't assume the IaC
  Atlantis role). Open Q to Markuss: canonical trigger for *initial* provisioning when the scaffold
  is already on `main` with no MR diff (`atlantis plan -p <stage>` per order vs re-seed branch→MR).
- **P4–P7** — pending P3.

---

## 6. Verification (end-to-end) — Phase 8

This is **P8**: invoke **`eis-onesuite-e2e-verify`** to drive the full sign-off (it covers the
private-cluster access trap, the temp-endpoint-open-then-revert diagnosis trick, and the two
first-sync failure modes). The quick checklist below is the summary it works through:

1. **Account** — `aws sts get-caller-identity` resolves; account in the correct OU.
2. **Terraform** — every Atlantis project (`lower/{infra,dev}/{bootstrap,core,services}`) plans
   clean then applies green in execution order; `pre-commit run --all-files` passes (run the
   `verify-iac-changes` skill on changed files before each MR).
3. **Network** — TGW attachment Active; dev VPC reaches the Network-Hub Nexus registry; DNS resolves.
4. **Toolchain** — GitLab/Jenkins/Nexus/SonarQube/Keycloak UIs reachable + healthy.
5. **EKS** — `kubectl get nodes` healthy; build host has cluster access via instance-role access entry.
6. **ArgoCD** — all components Synced+Healthy, no failed hooks; gen-dashboard + headlamp reachable at
   `*.dev.aws0.<code>-eis.cloud` **from a WorkSpace** (private — not from public internet).
7. **Access** — an AXA WorkSpace reaches GitLab/Jenkins/Nexus + cluster ingress over the TGW;
   confirm nothing is internet-exposed (no public ALB, no IGW).
8. **Handoff** — delivery team confirms cluster + GitLab access; app-layer DoD tracked separately (P7).

**Decommission:** tag everything `Issue=<TICKET>`; tear down cleanly at POC end via the
**`fv-cluster-decommission`** skill.
