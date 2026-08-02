---
name: eis-onesuite-external-deps
description: Use at the START of a new EIS OneSuite client/POC onboarding (Phase 0) to identify and PRE-FILE every external-team dependency before the build sprint — AD/IdC groups, DNS forward, Red Hat Cloud Access, Vault access/seed/cert-approle, TGW+DNS RAM share, IdC SAML app, and AWS account vending. Use when the user says "prepare external dependencies", "what do we need from other teams", "pre-onboarding requests", "file the prereq tickets", "external team setup before onboarding", or is planning a new environment and external lead time is the long pole. Carries who-owns-what, the right Jira project/type + precedent ticket per ask, lead times, which phase each blocks, and the eliminate→pre-file→automate strategy. The full ready-to-file request templates live in the kit doc docs/EXTERNAL-DEPENDENCY-PACK.md.
---

# Phase-0 external-team dependency setup (OneSuite)

External work is **"ask a human → wait"** — the wait, not the apply, is the long pole of the onboarding calendar. Beat it on three levels:

- **L3 — eliminate the per-customer ask** (delegated self-service or one-time OU-scoped grant → new client inherits it, zero tickets).
- **L2 — pre-file what's left on day 0, in parallel** (slowest SLAs burn down together, not serially).
- **L1 — automate the filing** from the `onesuite.yaml` intake (deterministic, mirrors a known-good precedent).

Until L3 lands, the discipline is **L2: nothing external discovered late, everything filed the same day, each ask routed to the right team + contact + precedent id.**

## The dependency register (substitute `<code>` / `<zone>` / `<account>`)

| Dependency | Team · contact | Jira / channel | Lead | Blocks | Cardinality |
|---|---|---|---|---|---|
| **TGW + DNS-resolver RAM share** to the SaaS OU | Network/platform | network-hub MR (not a ticket) | — | P3 connectivity | **one-time-OU** (inherit) |
| **Red Hat Cloud Access** for the account | Cloud team (cloud-queue); SME dzvenyhorodskyi | COEXT | 1-3d | P3 EC2 fleet (RHEL AMIs owner 309956199498) | per-account |
| **Account vending** (CreateAccount + StackSet) | mgmt-acct holder (Markuss); acct 455655288646 only | mgmt-account action | <1d | P1 | per-account |
| **AD/IdC groups + `<code>_build` SA** (returns SIDs) | OPS / AD team · Bogdan Kokkin | EISHELP "Access Request" (precedent EISHELP-110634) | 2-5d | P6 RBAC + P5 SSH/Jenkins; dashboard SSO | per-customer |
| **DNS forward** of `<zone>` (+ reverse zones per /24) | PnT DNS · Alexei Roudnev (aroudnev); confirm IPs w/ Markuss | EISHELP "Access Request" (precedent EISHELP-110743) | 3-7d | laptop/browser access to ALL URLs; P7 sign-off | per-customer |
| **Vault access** (AD-group READ on `secret2/data/<code>/*`) | Vault/Platform · Olha Isachenko | COEXT (not GENESIS) | 1-3d | P5/P6 secret reads | per-customer |
| **Vault populate** (~16 paths) | **WE seed** (Cloud won't — data-leak policy) | — (our task; mirror caa/common/ansible) | our 0.5d | P5/P6 | per-customer |
| **Vault cert approle** `sslupdate-certificates` (ssl RW) | Vault-admin · Olha | COEXT (precedent GENESIS-431673) | 1-3d | P3 LE cert auto-deploy | per-customer |
| **IdC SAML app** + group **assignment** + **attribute mapping** | IdC admin · Markuss; acct 455655288646, instance ssoins-7223b6f6cff32a78 | IdC-admin action | 1-3d | dashboard SSO sign-in (the longest axajp chase) | per-customer |
| **Upstream Nexus proxy account** `nexus_<code>-proxy` + grant `nexus_genesis-members` on `sfoeisgennexus01` | OPS / Nexus admin | EISHELP "Access Request" | 1-3d | P3 Nexus proxy pulls (GENESIS docker/npm/mvn) — else 401 | per-customer |

## Day-0 checklist (fire all the same day)
1. Fill `onesuite.yaml` (intake) → derive `<code>/<zone>/<account>` + the AD-group + Vault path sets.
2. Open ONE tracking epic; one routed sub-task per dependency above; link Related → parent env ticket.
3. File **all per-customer/per-account** asks together — AD groups, DNS forward, Vault access+approle, RHEL access, vending request — copy bodies from `docs/EXTERNAL-DEPENDENCY-PACK.md` (parameterized, mirror the precedent field-ids; EISHELP createmeta 400s — copy raw field-ids from the precedent ticket, don't rely on createmeta).
4. Confirm the **one-time-OU** items (TGW/DNS RAM) are already in place for the SaaS OU; if a brand-new OU, file that first (it gates P3).
5. Seed Vault yourself once access lands; trigger the IdC SAML app create+assign+attr-map with Markuss early (it gates dashboard SSO and is easy to miss).
6. Track the epic; nudge on SLA breach. The DNS forward + IdC SAML app are the usual long poles.

## Traps (from the axajp first run)
- **AD groups go to EISHELP/OPS, not COEXT.** Client Vault work goes to **COEXT, not GENESIS** (per Olha).
- **Request the full 14-group + 1-SA set in ONE ticket** + ask OPS to return SIDs — axajp filed piecemeal and paid the lead time repeatedly. RBAC binds on **SID**, not name.
- **DNS: give PnT the expanded reverse-zone list + explicit resolver IPs (10.34.0.185/10.34.1.189) up front**; don't say "network-hub" (PnT rejects the term); reverse zones are mandatory.
- **IdC SAML "No access" has two non-obvious gates beyond the AD group:** the app **assignment** AND the **attribute mapping** (wizard defaults → "No access" even with assignment + membership correct). See [[cognito_saml_idc_repoint]].
- **Vault seeding is ours** — budget 0.5d to populate `secret2/data/<code>` mirroring caa/common/ansible.
- **Upstream Nexus proxy account is NOT auto-created.** The client Nexus config references `nexus_<code>-proxy` (pw seeded by us in Vault `secret2/data/<code>/identities/cicd_team/cicd/default_proxy_user`), but OPS must CREATE that user on `sfoeisgennexus01` + grant `nexus_genesis-members` — **mirror the working `nexus_caa-proxy`**. Missing → every proxied pull = `401 Unauthorized`, yet the `docker_compose_nexus` role finishes **green** (proxy/group creates accept `status_codes:[201,400]`, swallowing failures) so it *looks* done. axajp lost a day to this. File the EISHELP ask on day 0. Compounding: Nexus **3.92.x SSRF** also blocks the upstream (resolves to private 10.x) — see [[axajp_nexus_proxy_upstream_401]].

Full ready-to-file request bodies + the eliminate/pre-file/automate detail: **`docs/EXTERNAL-DEPENDENCY-PACK.md`** in the `onesuite-provisioning-runbook` kit. Related: [[eishelp_ad_group_requests]], [[feedback_vault_tickets_coext]], [[redhat_cloud_access_new_account]], [[account_vending_org_topology]], [[cognito_saml_idc_repoint]], [[axajp_nexus_proxy_upstream_401]]; skills `eis-onesuite-phase0-prereqs`, `eis-onesuite-platform-provision`.
