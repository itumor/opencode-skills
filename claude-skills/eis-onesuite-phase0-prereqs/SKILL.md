---
name: eis-onesuite-phase0-prereqs
description: Phase 0 of standing up a brand-new EIS OneSuite client/POC environment — the up-front coordination gates that must be nailed down (and the external-team asks kicked off) BEFORE any account vending or terraform apply. Covers OU placement, account name + root-email convention, CIDR sub-allocation from a reserved /21 (incl. the /23-breaks-infra-auto-calc trap), Route53 DNS zone, the IdC↔Cognito SAML chicken-and-egg (ACS URL + audience), the TGW RAM-share-into-SaaS-OUs gap, Vault secret2/data/<project_code> population, registry pull-secret reuse, the Selenoid golden-image role, cost/BoM sign-off, service quotas, Atlantis webhook, and the private (WorkSpaces) vs public+WAF access model. Use when the user says "stand up a new OneSuite/SaaS environment", "onboard a new client/POC env", "what do we need before vending the account", "start the Phase 0 prereqs", "kick off the coordination gates", or is at the very start of a full new-environment build and needs the checklist of who-owns-what + how each is resolved. This is the first phase of the master skill eis-onesuite-platform-provision; the next gated phase is eis-account-vending (Phase 1).
---

# EIS OneSuite — Phase 0: Pre-reqs & Coordination Gates

Phase 0 is the **coordination layer** of a full new-environment build. Almost nothing here is
`terraform`/`ansible` — it is inputs you must lock down and external-team asks you must kick off
**before** spending money (account vending) or running any apply. Several items (network, DNS, IdC,
Vault) live in **other teams' hands**, so they have lead time — open them on day 1.

This is the **first phase** of `eis-onesuite-platform-provision`. The phase chain:

| Phase | Skill | Owns |
|---|---|---|
| **0** | **`eis-onesuite-phase0-prereqs`** (this) | coordination gates / inputs |
| 1 | `eis-account-vending` | vend the AWS account → `account_id_default` |
| 2 | `eis-onesuite-phase2-terraform-scaffold` | copier the `client` TF project |
| 3 | `eis-onesuite-phase3-infra-provision` | infra stage (VPC/TGW/DNS + toolchain EC2) |
| 4 | `eis-onesuite-phase4-dev-provision` | dev stage (EKS/RDS/MSK/LBs) |
| 5 | `eis-ansible-project-template` | toolchain config (GitLab/Jenkins/Nexus/…) |
| 6 | `argocd-cluster-onboarding` | onboard EKS into the ArgoCD hub |
| 7 | `eis-onesuite-phase7-app-handoff` | handoff to delivery team |

**Reference run: EISSAASDEV-302 (AXA Japan / `axajp`).** Concrete values from that run are inline
below — substitute your client's. Canonical external runbook: **wiki.eisgroup.com/spaces/Devops** →
"EIS OneSuite Platform Creation Workflow" Steps 1–4 + "Vault – Rules and Structure" + TF Modules
Catalog (Aurimas, 2026-06-18).

---

## 0. Decide the shape of the env FIRST (this gates everything else)

Two top-level decisions drive every gate below. Get them in writing from the infra owners
(EISSAASDEV-302: Girts Baltaisbrencis / Aurimas Kerpauskas / Sigitas Vilkelis; approach
re-litigation owner Viktoras Zalpys):

1. **New isolated env vs namespace-on-existing-cluster.** A new full env = own VPC + EKS + toolchain
   fleet (expensive, ~weeks). A namespace beside an existing cluster is far smaller. **Confirm the
   new-env approach is STILL greenlit before vending** — if it's overturned the whole TF scaffold is
   discarded. (EISSAASDEV-302: greenlit new-env, full CAA-parity fleet.)
2. **Access model — Private (WorkSpaces) vs Public+WAF.** This is load-bearing: it decides whether you
   provision an IGW, public ALB, public ACM and `eis-waf`, or go internal-only reached via Amazon
   WorkSpaces over the TGW. See §10. (EISSAASDEV-302: **Private/WorkSpaces, no public surface**.)

⚠️ **"region" ambiguity:** an "Asian region" / "Japan" ask usually refers to the **application**
config (ref-impl branch + regional config), NOT the AWS region. EIS infra lands in **`us-west-2`
(`aws0`, AWS Oregon)** like every other env. Confirm, don't assume.

---

## The checklist (owner + status pattern)

Track every item as `[owner] STATUS — note`. STATUS ∈ `TODO / IN-PROGRESS / BLOCKED / DONE / N-A`.
External items go IN-PROGRESS the moment you've sent the ask. Items 1–2 above + 1–14 below.

| # | Gate | Owner | EISSAASDEV-302 status |
|---|---|---|---|
| 1 | Approach still greenlit | infra owners (Girts/Viktoras) | DONE (new-env) |
| 2 | CIDR sub-allocation from reserved /21 | you + network team | DONE |
| 3 | Root DNS zone in Route53 | DNS team (Aurimas) | DONE |
| 4 | IdC SAML metadata URL ↔ Cognito ACS/audience | IdC admin (Aurimas) + you | DONE |
| 5 | Customer on-prem VPN | infra owners | N-A (none) |
| 6 | Access model (Private/WorkSpaces vs Public+WAF) | infra owners | DONE (Private) |
| 7 | TGW RAM-shared into SaaS OUs | you (network-hub MR) | DONE (MR !9 merged) |
| 8 | Vault `secret2/data/<code>` created + populated | Vault owner + you | IN-PROGRESS (knowledge gap) |
| 9 | Registry pull-secret | shared — reuse | DONE (no new seed) |
| 10 | Selenoid golden-image AMI | you (ansible role, Phase 5) | TODO (deferred to P5) |
| 11 | SSO permission set assignment | IdC admin (Markuss) | DONE |
| 12 | Service quotas | — | N-A (fresh acct OK) |
| 13 | Atlantis webhook on new repo | you (Phase 2 onboard) | DONE (hook id 14) |
| 14 | Cost / BoM sign-off | business owner | DONE |

Below: how each is resolved.

---

## 1. OU placement + account name + root-email convention

New **lower-env** SaaS client accounts go under **`SaaS / Lower`**.

- EIS Org `o-kthbmcbbdg`, root `r-mgtl`, **management account `455655288646`**.
- OU IDs (verify with `aws organizations list-organizational-units-for-parent`):
  - **`SaaS`** parent = **`ou-mgtl-qjjf0akp`**
  - **`SaaS / Lower`** = **`ou-mgtl-10u4x9xu`** ← lower-env clients land here
  - **`SaaS / Upper`** = **`ou-mgtl-fhbvbnpo`**
- **Account name** convention: `<Client> <Tier>` where Tier ∈ `LW`/`Lower`, `UP`/`Upper`.
  (EISSAASDEV-302: ticket said `AXA Japan LW`; vended as **`AXA Japan Lower`**.)
- **Root email** convention: **`eis-pnt-aws+<project_code>@eisgroup.com`** (plus-addressing, one inbox).
  (EISSAASDEV-302: `eis-pnt-aws+axajp@eisgroup.com`.)
- **`project_code`** is the short, lowercase, regex-safe id used everywhere (bucket names, host names,
  cluster name, Vault path, prefix-list keys). Lock it early — renaming later is painful.
  (EISSAASDEV-302: `axajp`, changed from `axaj` mid-flight per Girts — confirm before scaffolding.)

The actual `CreateAccount` + OU-move + StackSet baseline happens in **Phase 1
(`eis-account-vending`)** — that skill owns the management-account-only gotcha. Phase 0 only **decides**
the name/email/OU/code.

---

## 2. CIDR sub-allocation from the reserved /21  ⚠️ /23-breaks-infra-auto-calc trap

Ask the network team to **reserve a `/21`** for the project, then sub-allocate. A 2-VPC lower env
(Shared + Development) uses two `/23`s out of the `/21`, leaving the back half for future stages.

EISSAASDEV-302 layout (reserved **`10.34.128.0/21`**):

| VPC / stage | CIDR | Range |
|---|---|---|
| **Shared** (`lower/infra`) | `10.34.128.0/23` | .128.0–.129.255 |
| **Development** (`lower/dev`) | `10.34.130.0/23` | .130.0–.131.255 |
| reserved (future `test` etc.) | `10.34.132.0/22` | — |

- **Pod CIDR** (`100.64.x`, CGNAT VPC-local, NOT TGW-routed) and **EKS service CIDR**
  (`10.202.0.0/16`, k8s-internal) keep the **copier defaults** — they're not globally routed, so
  reusing the same values across clients (e.g. CAA) is safe.

⚠️ **THE TRAP — `/23` Shared VPC overflows the template's auto-subnet calc.** The `client` template's
**infra** auto-subnet math assumes a **`/22`**: it places TGW subnets at `base+3` (→ `10.34.131.x`),
which **overflows a `/23` and collides with the Development range**. Fix: in the **Shared** stage only,
set **`intra_auto_calculate: false`** and **hand-size the subnets** inside the `/23`. The Development
`/23` auto-calc is fine — the lower-stage generator is designed for `/23` and stays in range.

Hand-sized Shared subnets that work (EISSAASDEV-302, render-validated against template **v1.3.0**):
```yaml
infra_cidr: 10.34.128.0/23
intra_auto_calculate: false
infra_private_subnets:            # EC2 toolchain fleet, 2 AZs (256 IPs)
  - 10.34.128.0/25                # us-west-2a
  - 10.34.128.128/25              # us-west-2b
infra_tgw_subnets:                # TGW attachment, 2 AZs
  - 10.34.129.208/28              # us-west-2a
  - 10.34.129.224/28              # us-west-2b
```
Development `/23` auto-subnets resolve inside `10.34.130.0/23` (public `…131.0/28`+`…131.16/28`,
private `…130.0/26`+`…130.64/26`, eks `…130.128/26`+`…130.192/26`, tgw `…131.208/28`+`…131.224/28`).
These exact answers feed **Phase 2** (`eis-onesuite-phase2-terraform-scaffold`).

---

## 3. Root DNS zone in Route53

The DNS team creates the **public hosted zone** for the project root domain. ArgoCD ingress and all
`*.dev.aws0.<domain>` URLs hang off it; private zones are created later by `eis-dns` in the infra/core
apply (Phase 3).

- Domain convention: **`<project_code>-eis.cloud`**. (EISSAASDEV-302: **`axajp-eis.cloud`**, ArgoCD
  ingress `dev.aws0.axajp-eis.cloud`.) ✅ zone already placed on Route53 by Aurimas.
- Hand the domain to Phase 2 copier as `domain_name`.

---

## 4. IdC ↔ Cognito SAML — the chicken-and-egg

EIS Cognito user pools federate to **IAM Identity Center (IdC)** via SAML. There is a circular
dependency between the two sides; resolve it in this order:

1. **IdC admin creates a SAML app** in Identity Center and gives you the **metadata URL**.
   (EISSAASDEV-302: app "AXAJP Lower Cognito" `ins-7223ce427d94d53c`; metadata URL
   `…/saml/metadata/NDU1NjU1Mjg4NjQ2X2lucy03MjIzY2U0MjdkOTRkNTNj`.)
2. You set that URL as the Cognito IDP `metadata_url` in
   **`lower/infra/services/terraform.tfvars`** (Phase 3). The **`eis-cognito` module derives the
   Cognito hosted-UI domain from the pool name** → `<project_code>` (e.g. `axajp`).
3. **Give the IdC admin back the ACS URL + audience** so they finish the IdC app config:
   - **ACS (Reply) URL:** `https://<project_code>.auth.<region>.amazoncognito.com/saml2/idpresponse`
     (EISSAASDEV-302: `https://axajp.auth.us-west-2.amazoncognito.com/saml2/idpresponse`).
   - **SAML audience (Entity ID):** `urn:amazon:cognito:sp:<pool-id>` — note the **`<pool-id>` only
     exists AFTER the infra/services Cognito apply** (Phase 3). So: hand over the ACS URL now (it's
     deterministic from `project_code`+region), and **send the audience as a follow-up** once the pool
     exists. That's the chicken-and-egg.

The metadata URL feeds Phase 2 copier as `cognito_application_url`.

---

## 5. Customer on-prem VPN

Decide whether the customer needs a site-to-site VPN into the env. If **none**, you still need the
**TGW attachment to the Network Hub** (for the EIS Nexus image registry, DNS, cross-env access) — but
you drop `eis-vpn`/`vpn.tf` from `lower/infra/core`.

(EISSAASDEV-302: **no customer VPN** — TGW-to-hub only.)

---

## 6. Access model — Private (WorkSpaces) vs Public + WAF

The §0 access decision, in detail:

- **Private (CAA-style):** **no IGW**, internal ALB + internal NLB, **no public ACM, no `eis-waf`**.
  Devs reach the env through **EIS-provided Amazon WorkSpaces routed over the TGW**; the
  **`workspaces` prefix list** gates ingress. ➕ **Confirm whether existing shared EIS WorkSpaces can
  reach the new account over the hub, or whether dedicated WorkSpaces must be provisioned for the
  client** (WorkSpaces directory + bundles + user whitelist) — if dedicated, that's a **separate
  provisioning item**. (EISSAASDEV-302 chose this.)
- **Public + WAF:** internet-facing ALB + WAFv2 deny-by-default + a `/32` IP allowlist + public ACM.
  This is what FV (`afa-fv01`) does (eis-waf, 37-IP allowlist = 4 corporate + 33 Prisma SASE egress).

⚠️ **Watch for a contradiction in the ask.** EISSAASDEV-302: Girts said "whitelist the same addresses
used for FV" (implies public+WAF), but the chosen model is Private (no public surface to whitelist).
**Surface the contradiction, don't silently pick one.** If restricted ingress is wanted without going
fully public, the same IP list can be applied as an **EC2 managed prefix list** on the internal ALB /
toolchain SGs (the L3 form, not WAF).

---

## 7. TGW RAM-share must reach the SaaS OUs  (network-hub MR)

The hub TGW is RAM-shared **auto-accept, org-wide** — **but often shared into the PTO OU only**, so a
fresh **SaaS/Lower** account **will not see it** and the spoke attachment can't form.

➕ **ACTION (yours):** open an MR on the **`network-hub`** repo
(`iac/projects/aws/network-hub/terraform`) adding **SaaS/Lower (`ou-mgtl-10u4x9xu`)** + **SaaS/Upper
(`ou-mgtl-fhbvbnpo`)** to the RAM share **principals** (both the TGW share and the DNS-resolver share).
Network Hub account = **`729852324759`**. This **gates Phase 3** (infra/core TGW attach).

(EISSAASDEV-302: **MR !9 merged + applied 2026-06-18**, approved Markuss; `atlantis apply` = 4 added,
0 changed, 0 destroyed. SaaS/Lower + SaaS/Upper now on the hub TGW + DNS-resolver RAM shares →
Phase-3 TGW gate cleared.)

---

## 8. Vault `secret2/data/<project_code>`  ⚠️ knowledge gap

Clients use the Vault path **`secret2/data/<project_code>`** (EISSAASDEV-302: **`secret2/data/axajp`**).
**Do NOT use** the old `secret2/data/rnd/cicd/3.0/…` path for new clients.

- ➕ **ACTION:** request the path be **created + assigned to your project/role**.
- ⚠️ **Populating it with secrets uses an undocumented script** (ran for CAA by Sergii Kravchenko;
  old-cloud-team siloed) — believed to **copy/transform from `secret2/data/ansible`** into the new
  path. This is a **knowledge gap → reverse-engineer or escalate.** Consult the wiki "Vault – Rules
  and Structure" doc.
- This is a **Phase-5 (ansible) concern**, not a Phase-3 blocker — but request the path NOW (lead
  time). The Phase-5 ansible copier takes this as the `vault` path. Vault addr:
  `https://eqx-cvops-vault01.eqxdev.exigengroup.com`.

---

## 9. Registry pull secret

The container-registry pull secret is **shared across clients** — **reuse the existing secret, no new
seed needed**. No action beyond confirming it's referenced by the standard config. (EISSAASDEV-302: ✅
shared.)

---

## 10. Selenoid golden-image AMI

There is an **Ansible role that builds the Selenoid ASG golden image** — **no manual AMI hunt**. Run
it in **Phase 5** (`eis-ansible-project-template`) **before** the Selenoid ASG (`eis-asg`) applies, so
the launch template references a real image. Phase 0 just notes it as a downstream item. Drop
`selenoidasg01` only if cost-cutting the POC.

---

## 11. SSO permission-set assignment

You need an SSO permission set assigned in the new account to operate it. Typically the IdC admin
assigns it **after** vending (you wait for it). (EISSAASDEV-302: Markuss assigned via the `oc-team`
IdC assignment → `AdministratorAccess` into `586117079971`; local SSO profile `axajp` added.) See
`eis-idc-scoped-ssm-access` for the scoped-access mechanics.

---

## 12. Service quotas

A **fresh account** generally has clean quotas — **no pre-raise needed** for a standard POC fleet.
(EISSAASDEV-302: confirmed none needed.) Re-evaluate only for unusually large sizing.

---

## 13. Atlantis webhook on the new repo

IaC Atlantis is **not an allowlist** — you just **add a GitLab webhook** on the new TF repo pointing at
IaC Atlantis so MRs autoplan. This is done during **Phase 2** repo onboarding.

- Webhook URL: **`https://atlantis-iac.dev.aws0.iac.aws.eislab.cloud/events`**
- Events: **Merge request + Note (comment) + Push**.
- Secret: the `gitlab_secret` from Secrets Manager (`…/atlantis/atlantis/atlantis-vcs`).
- (EISSAASDEV-302: hook id 14 created on `iac/projects/aws/axa-japan/terraform`.)

---

## 14. Cost / BoM sign-off

A full delivery env is expensive for a POC: **~11 EC2 hosts** (git / jnk / bld / nexus / atlantis /
sonar / keycloak / ta / grok / sis + Selenoid ASG) **plus EKS + RDS + MSK + LBs**. **Surface the bill
of materials to the business owner and get explicit sign-off before applying.** (EISSAASDEV-302: full
spend confirmed 2026-06-18; business owner Jason Thackeray.)

Also: **POC lifespan** — tag everything `Issue=<JIRA-KEY>` (EISSAASDEV-302: `Issue=EISSAASDEV-302`) and
plan a clean decommission path (`fv-cluster-decommission`).

---

## Verification — Phase 0 exit criteria

Phase 0 is "done enough to start Phase 1" when:

1. **Approach + access model + region** confirmed in writing (§0).
2. **`project_code`, account name, root email, OU** locked (§1).
3. **CIDR** reserved `/21` + sub-allocation written down, with the **Shared-`/23` `intra_auto_calculate:
   false` + hand-sized subnets** noted (§2). This is the single most-skipped trap.
4. **DNS zone** live in Route53 (§3) — `dig NS <domain>` returns AWS nameservers.
5. **IdC SAML metadata URL received** + ACS URL handed back (§4); audience flagged as
   post-Cognito-apply follow-up.
6. **TGW RAM-share** MR into SaaS OUs **merged + applied** (§7) — else Phase 3 TGW attach fails.
7. **Vault path requested** (§8); registry pull-secret confirmed shared (§9).
8. **Cost sign-off** obtained (§14).

Then proceed to **`eis-account-vending`** (Phase 1) with the locked `project_code` / account name /
root email / OU.
