---
name: eis-onesuite-phase7-app-handoff
description: >-
  Phase 7 (final) of EIS OneSuite platform provisioning — hand off a live, fully-provisioned EKS
  cluster + delivery toolchain (GitLab/Jenkins/Nexus/SonarQube/Keycloak/ArgoCD) to the delivery
  team so they can install the ref-impl 26.100 application stack. This skill does NOT do IaC-repo
  work; it produces a self-contained handoff document with the cluster URL, kubeconfig/RBAC access,
  GitLab/Jenkins/Nexus/SonarQube endpoints, the ArgoCD app-deployment path, and the
  Asian-region/master-branch app-config note, then tracks the delivery-owned DoD app items.
  Use when: "hand off the cluster to delivery", "write the platform handoff doc", "the toolchain is
  live, give the app team access", "delivery team needs kubeconfig / GitLab / Jenkins endpoints",
  "what does the app team install on the new env", "ref-impl 26.100 handoff", "Asian region / master
  branch app config", or after argocd-cluster-onboarding finishes a new OneSuite env and someone asks
  "what's left". Comes AFTER eis-onesuite-phase4-dev-provision (infra), eis-ansible-project-template
  (toolchain config), and argocd-cluster-onboarding (cluster components). Reference run:
  EISSAASDEV-302 (AXA Japan / axajp).
---

# Phase 7 — Application-layer handoff to the delivery team

This is the **final** phase of `eis-onesuite-platform-provision`. Phases 0–6 stood up a complete,
isolated Dev environment (own VPC, EKS cluster, delivery toolchain, ArgoCD). Phase 7 is **not IaC
work** — the application stack (web-studio, eis-smartform, Flowable, docgen, eissuite-integration,
product-studio) is installed by the **delivery team** on the new dedicated GitLab/Jenkins using the
normal ref-impl 26.100 flow. Our job is to hand them a clean, working, documented environment and
get out of the way.

**Pre-conditions (verify ALL before writing the handoff — do not hand off a half-built env):**
- Phase 4 (`eis-onesuite-phase4-dev-provision`) applied green: `aws0<code>deveks01` cluster live,
  RDS/MSK/internal-ALB/NLB provisioned, IRSA roles created.
- Phase 5 (`eis-ansible-project-template`) ran clean: GitLab/Jenkins/Nexus/SonarQube/Keycloak/OpenGrok/
  Sisense UIs reachable + healthy.
- Phase 6 (`argocd-cluster-onboarding`) shows **100% Synced+Healthy, no failed hooks**.

---

## Step 1 — Collect the live coordinates (run these, paste real values into the doc)

Do NOT hand-write endpoints from memory — query the live env. Use the project's SSO profile
(reference: `axajp`).

```bash
# Cluster name + region (reference: aws0axajpdeveks01 / us-west-2)
CLUSTER=aws0axajpdeveks01
REGION=us-west-2
PROFILE=axajp        # the new account's SSO profile (reference: 586117079971)

# 1a. Cluster API endpoint + ARN
aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --profile "$PROFILE" \
  --query 'cluster.{arn:arn,endpoint:endpoint,status:status,version:version}' --output table

# 1b. Generate kubeconfig context for verification (delivery team runs this themselves with THEIR access)
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --profile "$PROFILE"
kubectl get nodes -o wide          # expect Ready system/app/build pools
kubectl get applications -n argocd # expect all Synced+Healthy (the ArgoCD apps)

# 1c. Internal ALB DNS + target-group ARN (private; reachable only over TGW / WorkSpaces)
aws elbv2 describe-load-balancers --region "$REGION" --profile "$PROFILE" \
  --query "LoadBalancers[?Scheme=='internal'].{name:LoadBalancerName,dns:DNSName}" --output table
```

The toolchain UIs follow the standard private-DNS pattern off the root domain
(`<root-domain>` reference = `axajp-eis.cloud`; ArgoCD ingress `dev.aws0.axajp-eis.cloud`). Confirm
each resolves **from a WorkSpace** (private model — nothing is internet-exposed). Typical hostnames
(verify against the actual Route53 private zone / ansible inventory, do not assume):

| Service | Host (private, reference axajp) | Source of truth |
|---|---|---|
| GitLab | `git01.aws0.<root-domain>` | Phase-5 ansible `git01`, R53 private zone |
| Jenkins | `jnk01.aws0.<root-domain>` | Phase-5 ansible `jnk01` |
| Nexus | `nexus01.aws0.<root-domain>` | Phase-5 ansible `nexus01` |
| SonarQube | `sonar01.aws0.<root-domain>` | Phase-5 ansible `sonar01` |
| Keycloak | `keycloak01.aws0.<root-domain>` | Phase-5 ansible `keycloak01` |
| OpenGrok | `grok01.aws0.<root-domain>` | Phase-5 ansible `grok01` |
| Sisense | `sis01.aws0.<root-domain>` | Phase-5 ansible `sis01` |
| ArgoCD | `argocd.dev.aws0.<root-domain>` (hub-managed) | Phase-6 ingress |
| gen-dashboard | `dashboard-monitoring.dev.aws0.<root-domain>` | Phase-6 component |
| Headlamp | `headlamp.dev.aws0.<root-domain>` | Phase-6 component |

> **Private-access reminder:** there is **no public ALB, no IGW, no WAF**. All of the above are
> reachable only from EIS-provided Amazon WorkSpaces routed over the TGW. The handoff doc MUST tell
> the delivery team this explicitly, and that they need a WorkSpace (or hub-routed access) — a laptop
> on the open internet will time out and they'll think the env is broken.

---

## Step 2 — Sort out delivery-team RBAC / kubeconfig access (do NOT just share your admin creds)

The delivery team needs cluster access of their own. Two layers, both required:

1. **AWS access into the account** — they need an IdC permission-set assignment to the new account
   (reference `586117079971`). This is a Markuss/IdC-admin action, same channel as the provisioning
   access. If they are an external/scoped team, use `eis-idc-scoped-ssm-access` instead of broad
   admin. Confirm the assignment landed before claiming handoff (you cannot self-verify another
   user's IdC assignment — they confirm by logging in).
2. **EKS access entry** — their IAM principal (or a shared delivery role) must be mapped into the
   `eis-eks` `access_mapping` in `lower/dev/services/terraform.tfvars`, the same mechanism used for
   the `bld01` build host (skill `eis-build-host-provision`). Mind the **`ec2_group` substring-matcher
   trap** (the mapping uses a `.*<group>.*` regex — a group name that contains another double-binds
   and fails apply). If the delivery team will deploy from `bld01` / Jenkins, the build-host instance
   role access entry from Phase 4 already gives them in-cluster deploy rights — document that path
   rather than minting new entries.

In the handoff doc, give them the **commands**, not your tokens:
```bash
aws sso login --profile <their-delivery-profile>
aws eks update-kubeconfig --name aws0<code>deveks01 --region us-west-2 --profile <their-delivery-profile>
kubectl auth can-i create deployments -n <app-namespace>   # should say "yes" once their entry applies
```

---

## Step 3 — Document the ArgoCD app-deployment path

The platform ArgoCD (Phase 6, hub `iac/argocd/argocd`) manages **infra/platform components only**
(istio, ESO, LB controller, autoscaler, observascope, gen-dashboard, headlamp, velero). The
**application** ref-impl stack is delivery-owned and deploys via the **dedicated project GitLab +
Jenkins** stood up in Phase 5 — it is NOT added to the platform ApplicationSet by us.

Spell this boundary out in the doc so nobody adds app charts to the platform hub repo:
- **Platform components** → `iac/argocd/argocd/clusters/aws0<code>deveks01/` (managed by us; the
  hub ApplicationSet matrix generator syncs them; reviewer routing argocd/helm/gitops → eramadan).
- **Application workloads** → delivery team's own GitLab repos on the new `git01`, built by Jenkins
  `jnk01`, images pushed to Nexus `nexus01`, deployed into app namespaces on the cluster. If they
  want their own ArgoCD-style GitOps for the app, they wire it against the project GitLab — not the
  EIS platform hub.
- Namespace visibility: if a new app namespace doesn't show in gen-dashboard, that's the
  `gen-dashboard-namespace-visibility` skill (add it to `oneSuiteDashboardConfig.namespaces`) — note
  it as a known follow-up.

---

## Step 4 — Capture the Asian-region / master-branch app-config note (load-bearing)

The ticket's "Asian region" wording refers to **application configuration**, NOT the AWS region (infra
is `us-west-2` like every EIS env). The delivery team must configure the ref-impl 26.100 app for the
**Asian region**, building from the **`master` branch**, **same setup as the NN Japan FV**. Put this
verbatim in the handoff so it isn't mistaken for an infra change:

> **App config:** ref-impl **26.100**, **Asian-region** configuration, built from **`master`** branch
> (mirror the NN Japan FV app setup). docgen is deployed **from `master`**. Commercial Flowable.

---

## Step 5 — List the delivery-owned DoD app items (out of scope for the IaC monorepo)

These belong to delivery, not to us — list them in the handoff so the ticket DoD is traceable and
nobody waits on the IaC team to do them:

- **web-studio** — installed + connected to the env.
- **eis-smartform** — installed.
- **commercial Flowable** — deployed.
- **docgen** — deployed **from `master`**.
- **eissuite-integration** — installed, AND **align `jwt-allowed-clock-skew-sec` between the v12 and
  v20 apps** (see **GENESIS-335532** comment — a clock-skew mismatch breaks JWT validation across the
  v12/v20 boundary; both sides must use the same value). Call this out as a known integration gotcha.
- **product-studio environment** — listed/registered for UI-driven deployment.
- **full automation / nightly suite** — wired (Selenoid ASG from Phase 5 backs the E2E runs).

> **Owed back to us:** Aleh Varabyou (16/Jun comment) owes the list of ref-impl components that need
> their own dedicated GitLab projects on `git01`. Chase that — the delivery team can't create repos
> for components they haven't been told about. Note it as an open dependency in the handoff.

---

## Step 6 — Write and deliver the handoff doc

Assemble a single self-contained document (Confluence page under spaces/Devops, or a Jira comment on
the master ticket — reference EISSAASDEV-302). It MUST contain, with real values filled in from
Steps 1–5:

1. **Environment summary** — project code, account ID, cluster name, region, root domain, POC scope,
   `Issue=<master-ticket>` tag, **private-access caveat** (WorkSpaces/TGW only, no public surface).
2. **Cluster access** — `aws eks update-kubeconfig` command + the RBAC/IdC steps from Step 2 (who to
   ask for the permission-set assignment + access entry).
3. **Toolchain endpoints** — the live table from Step 1 (GitLab/Jenkins/Nexus/SonarQube/Keycloak/
   OpenGrok/Sisense), with the note that they resolve only from a WorkSpace.
4. **ArgoCD path + platform/app boundary** — Step 3 (what we manage vs what they manage).
5. **App config note** — Step 4 (ref-impl 26.100, Asian region, master branch, NN Japan FV parity).
6. **DoD app items + open dependency** — Step 5 (delivery-owned list + Aleh's component-repo list).
7. **Decommission path** — POC lifespan; everything tagged `Issue=<master-ticket>`; teardown via the
   `fv-cluster-decommission` skill when the POC ends.

Post the doc, comment on the master ticket linking it, and tag the delivery leads + business owner
(reference: business owner Jason Thackeray). For Jira on the on-prem `jira.eisgroup.com`, use
`eis-jira-rest-ops` (cloud Atlassian MCP cannot reach it). For the Confluence page, use the wiki
MCP under spaces/Devops next to the "EIS OneSuite Platform Creation Workflow" runbook.

---

## Verification (the handoff is "done" when)

1. **Delivery team confirms cluster access** — they ran `aws eks update-kubeconfig` with THEIR
   profile and `kubectl get nodes` / `kubectl auth can-i` succeeds (not your admin creds).
2. **Toolchain reachability confirmed from a WorkSpace** — GitLab/Jenkins/Nexus/SonarQube/Keycloak
   UIs load + auth works from the delivery team's WorkSpace; nothing is internet-exposed.
3. **ArgoCD platform components** still 100% Synced+Healthy at handoff time (`kubectl get applications
   -n argocd`); gen-dashboard + headlamp reachable at `*.dev.aws0.<root-domain>` from a WorkSpace.
4. **Doc delivered + linked** on the master ticket; delivery leads + business owner acknowledged.
5. **App-layer DoD tracked separately** — the Step-5 items are on the delivery team's board, not
   blocking the IaC env. Aleh's dedicated-GitLab-project list logged as the one open dependency.

---

## Gotchas

- **Don't share admin creds as "access."** Handing over your SSO admin profile is not a handoff — it
  evaporates and bypasses RBAC. Get them a real IdC assignment + EKS access entry (Step 2).
- **Private model surprises people.** The #1 false "it's broken" report is a delivery engineer hitting
  the URLs from a non-WorkSpace machine and timing out. Lead the doc with the WorkSpaces/TGW caveat.
- **`jwt-allowed-clock-skew-sec` (GENESIS-335532)** is a real cross-app (v12↔v20) failure mode, not a
  formality — flag it explicitly or eissuite-integration JWT auth will fail intermittently.
- **Asian region ≠ AWS region.** It's an app config (master branch, NN Japan FV parity). Infra stays
  `us-west-2`. Don't let it trigger a phantom infra change.
- **Platform hub vs app GitOps.** App charts do NOT go into `iac/argocd/argocd`. Keep the boundary
  crisp or the platform ApplicationSet starts trying to manage application workloads.
- **gen-dashboard namespace gap.** New app namespaces are invisible until added to
  `oneSuiteDashboardConfig.namespaces` (skill `gen-dashboard-namespace-visibility`) — pre-empt the
  "we can't see our services" ticket.

---

**Reference run: EISSAASDEV-302 (AXA Japan / axajp)** — account `586117079971` (SaaS/Lower), cluster
`aws0axajpdeveks01` (`us-west-2`), root domain `axajp-eis.cloud`, ArgoCD ingress
`dev.aws0.axajp-eis.cloud`, full CAA-parity toolchain fleet (git01/jnk01/bld01/nexus01/atlantis01/
sonar01/keycloak01/grok01/sis01 + Selenoid ASG), private access via WorkSpaces over TGW (no public
ALB/IGW/WAF), ArgoCD secret backend = AWS Secrets Manager, business owner Jason Thackeray.
Predecessor phases: `eis-onesuite-phase4-dev-provision` (infra), `eis-ansible-project-template`
(toolchain), `argocd-cluster-onboarding` (cluster components). Master skill:
`eis-onesuite-platform-provision`.
