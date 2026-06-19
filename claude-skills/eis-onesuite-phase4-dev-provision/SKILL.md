---
name: eis-onesuite-phase4-dev-provision
description: Phase 4 of EIS OneSuite platform provisioning — provision the Development stage of a new client env via Atlantis (lower/dev/core exec-order 22 → lower/dev/services 23): eis-vpc Development /23 with secondary pod CIDR (no IGW), eis-eks K8s 1.35 (system/app/build node pools), eis-rds PostgreSQL, eis-msk Kafka, internal eis-alb, single-AZ static-IP eis-nlb, private eis-acm, eis-s3 (observascope + app), and EFS. Wires the bld build-host instance role into the EKS access_mapping and captures the EKS ARN / internal ALB target-group ARN+DNS / IRSA role ARNs that Phase 6 ArgoCD onboarding needs. Use when the user says "provision the dev stage", "apply lower/dev", "stand up the EKS cluster + RDS + MSK for <client>", "do Phase 4 of the OneSuite provisioning", or after Phase 3 (infra/toolchain) is green and the dev VPC + data plane + load balancers must come up. Private model only — NO public ALB, NO eis-waf, NO public ACM.
---

# EIS OneSuite — Phase 4: Development stage (EKS + data + LBs)

Phase 4 of the master flow `eis-onesuite-platform-provision`. Sequence:
P0 `eis-onesuite-phase0-prereqs` → P1 `eis-account-vending` → P2 `eis-onesuite-phase2-terraform-scaffold` → **P3 `eis-onesuite-phase3-infra-provision`** → **P4 (this)** → P5 `eis-ansible-project-template` → P6 `argocd-cluster-onboarding` → P7 `eis-onesuite-phase7-app-handoff`.

## What it is
The Development stage is the **dev VPC + the EKS data plane**. Two Atlantis projects, applied in execution order:

| Order | Atlantis project / state | Modules (`terraform/modules/aws/*`) |
|---|---|---|
| 22 | `lower-dev-core` → `lower/dev/core` | `eis-vpc` Development (`/23` + secondary pod CIDR, **no IGW**), `eis-tgw` spoke attach to Network Hub, `eis-dns` private + stage zone delegation, `prefix_lists` (local/administrative/workspaces/eks/eis/all) |
| 23 | `lower-dev-services` → `lower/dev/services` | `eis-eks` (K8s 1.35, node pools system/app/build), `eis-rds` PostgreSQL, `eis-msk` Kafka, `eis-alb` **internal**, `eis-nlb` single-AZ static IP, `eis-acm` **private**, `eis-s3` (observascope + observascope-loki + velero-backups + app), `efs` |

There is **no `dev/bootstrap`** — the dev state bucket (`aws0<code>dev` workspace inside `aws0<code>tfstate`) is created back in `infra/bootstrap` (Phase 2/3). Prereq: Phase 3 infra/core + infra/services are applied green (TGW Active, prefix lists exist, the `bld01` host + its `<prefix>bld01-Role` exist — the access-entry wiring in step 5 depends on the role already existing, see Gotcha 1).

**Private access model (locked):** no IGW, internal ALB, single-AZ NLB for the static IP, private ACM. Reached from EIS Amazon WorkSpaces over the TGW (the `workspaces` prefix list gates ingress). **Do NOT add a public ALB, eis-waf, or a public/DNS-validated ACM cert** — none of that exists in this model. (If a restricted ingress is ever wanted without going public, apply the FV 37-IP allowlist as an EC2 managed prefix list on the internal ALB SG — kept available, not implemented here.)

## Steps

1. **Confirm Phase 3 green.** `lower-infra-core` + `lower-infra-services` applied; TGW attachment Active; the toolchain fleet incl. `bld01` exists. Verify the build-host role exists (it gates step 5):
   ```bash
   AWS_PROFILE=axajp aws iam list-roles --query "Roles[?contains(RoleName,'bld01')].RoleName" --output text
   # expect: aws0<code>bld01-Role
   ```

2. **Configure `lower/dev/core/terraform.tfvars`.** The Development `/23` auto-subnet calc is *correct* (unlike the Shared `/23` in Phase 2 which needed `intra_auto_calculate:false`). Confirm the copier-rendered CIDR and the secondary pod CIDR are inside the stage range. For axajp:
   - VPC CIDR `10.34.130.0/23`, **no IGW** (`create_igw=false` is the copier default in both stages).
   - Secondary pod CIDR `100.64.48.0/20` (subnets `100.64.48.0/21`, `100.64.56.0/21`) — VPC-local CGNAT, **not TGW-routed**, safe to reuse across clients.
   - EKS service CIDR `10.202.0.0/16` (k8s-internal, copier default).
   - Dev `/23` auto-resolves: public `10.34.131.0/28`+`.16/28`, private `10.34.130.0/26`+`.64/26`, eks `10.34.130.128/26`+`.192/26`, tgw `10.34.131.208/28`+`.224/28` — all inside `10.34.130.0/23`. ✓ (render-validated against template v1.3.0)
   - TGW attach + DNS stage-zone delegation + prefix lists carry the copier defaults; **no `eis-vpn`** (no customer VPN).

3. **Configure `lower/dev/services/terraform.tfvars`.** Clone the CAA `dev/services` shapes (`projects/aws/credit-agricole/terraform/lower/dev/services/terraform.tfvars`) but **drop the CAA-specific extras** — Fivetran/Redshift/Glue/SFTP (`fivetran_hybrid.tf`, COEXT-98265) and the portal-broker/member/pdf S3 buckets (COEXT-103502/104484) are NOT in the POC scope. Keep the lean core maps:

   - **`eks["01"]`** (K8s 1.35, private):
     ```hcl
     version           = "1.35"
     service_ipv4_cidr = "10.202.0.0/16"
     alb_public_allowed_prefix_lists    = ["administrative"]   # internal ALB SG ingress (NOT public)
     control_plane_allowed_prefix_lists = ["local"]
     nlb_enable                 = true   # static IP front for ALB
     nlb_client_services_enable = true   # EIS users reach client resources via istio proxy
     nlb = { single_az = true, az_index = 1, allowed_prefix_lists = ["administrative"], enable_cross_zone_load_balancing = true }
     oidc_preset    = "cognito"
     oidc_dashboard = "k8s_dashboard"
     ```
     **Node pools** = system / app / build (CAA-parity, 2 AZs each):
     ```hcl
     node_pools = {
       "system-0" = { instance_settings = "system",      zone_idx = 1, min = 1, max = 2 }
       "system-1" = { instance_settings = "system",      zone_idx = 2, min = 0, max = 2 }
       "app-0"    = { instance_settings = "application",  zone_idx = 1,          max = 5 }
       "app-1"    = { instance_settings = "application",  zone_idx = 2, min = 0, max = 5 }
       "build-0"  = { instance_settings = "build",        zone_idx = 1 }
       "build-1"  = { instance_settings = "build",        zone_idx = 2 }
     }
     tags = { Issue = "EISSAASDEV-302" }
     ```
     `access_mapping` — see step 5 (keep `argocd`, `oc-team`, `cicd-team`; add `ci`/`ci-etcs` for the build/jenkins hosts).
   - **`rds["01"]`** PostgreSQL: `allocated_storage` (e.g. 1024 for parity, size down for POC), `allowed_prefix_lists = ["administrative"]` (pod + infra EC2 subnets are already allowed by the module). Skip the Fivetran logical-replication parameters unless asked. If a `shared_preload_libraries` extension (pgaudit etc.) is later requested → skill `eis-rds-postgres-extension`.
   - **`msk["01"]`** Kafka: `{ tags = { Issue = "EISSAASDEV-302" } }` (module defaults size it).
   - **`s3`** — POC core only: `observascope`, `observascope-loki` (both `versioning.enabled = false`), `velero-backups` (`versioning.enabled = true`, AES256), plus any app bucket the delivery team needs. **Omit** Fivetran/portal buckets.
   - **`velero`** = `{ enabled = true, bucket_key = "velero-backups", namespace = "velero", service_account = "velero", enable_volume_snapshots = true }`.
   - **`efs`** = `{ "01" = { attach_policy = true, policy_name = "efs_csi_driver" } }`.
   - ACM is **private** (issued + DNS-validated against the private `axajp-eis.cloud` zone) — copier default for the private model; no public/internet validation.

4. **eis-ec2 pin sanity (carried from Phase 3).** Ensure `eis-ec2 >= v2.2.1` if the dev stage references any EC2 (it shouldn't — EC2 lives in infra), and `eis-eks`/`eis-alb`/`eis-nlb`/`eis-acm` versions match the rest of the fleet. `eis-alb output "arn"` exists only in v1.0.3 (1.x) + v2.0.1+ if anything downstream needs it.

5. **Wire the build host into the EKS `access_mapping`** (skill `eis-build-host-provision`). Add to `eks["01"].access_mapping` — non-destructive, leave `argocd`/`oc-team`/`cicd-team` alone:
   ```hcl
   ci = {                          # build host(s)
     ec2_group = "bld"
     policy    = { arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy", scope = "cluster" }
   }
   "ci-etcs" = {                   # jenkins host(s)
     ec2_group = "jnk"
     policy    = { arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy", scope = "cluster" }
   }
   ```
   - **Gotcha 1 — substring-matcher collision (`eis_eks_ec2_group_substring_matcher`).** `eis-eks/data.tf` resolves `ec2_group` via `name_regex = ".*${ec2_group}.*"` (a SUBSTRING match). An acronym that *contains* an existing group double-binds: e.g. `bld` ⊂ a host named `…bld…` → two roles → two access entries for one principal → **apply fails**. For axajp the infra fleet host groups (`bld`, `jnk`, `git`, `nexus`, `atlantis`, `sonar`, `grok`, `sis`, `keycloak`, `selenoidasg`) are collision-clear of each other for `bld`/`jnk` — but **grep the chosen acronym both ways before committing**. (Stage-VPC variant uses `testbld` to dodge a key collision with the shared infra `bld01`; the AXA JP dev build node is the infra `bld01`, so plain `ec2_group="bld"` is correct here.)
   - **Gotcha 2 — host-before-access-entry ordering.** The `ec2_group` lookup runs at **plan time**. If `lower/dev/services` plans before `<prefix>bld01-Role` exists, the access entry is **silently not created** (no error). Phase 3 (infra/services, exec-order 13) must apply first; then re-plan dev/services (exec-order 23). A plain ordered `atlantis apply` honors 13-before-23; a targeted dev-first apply skips the entry.

6. **`pre-commit run --all-files`** (run skill `verify-iac-changes` on the changed `.tf`/tfvars before the MR). MR reviewer routing: **terraform/iac → Markuss (mzivarts)** (`glab ... --reviewer mzivarts`).

7. **Apply via Atlantis, in execution order** (NOT local — my SSO admin cannot assume the IaC Atlantis roles; Phase 3 established the repo webhook → IaC Atlantis). Order: `atlantis plan -p lower-dev-core` → `atlantis apply -p lower-dev-core` → `atlantis plan -p lower-dev-services` → `atlantis apply -p lower-dev-services`. Follow the project's apply-before-merge discipline: **atlantis apply → green → verify → merge LAST** (never merge first; see [[feedback_atlantis_apply_before_merge]]). Poll Atlantis notes by the captured note-ts. If a node-group upgrade later stalls on `PodEvictionFailure` → skill `eks-nodegroup-upgrade-unblock`. If Atlantis misbehaves (locks, exec-order, role-assume) → skill `atlantis-debug`.

8. **Cognito SAML audience hand-off** (this is the Cognito apply in **infra/services**, Phase 3 — but the audience can only be read *after* that apply, so it surfaces here as a downstream action). After `lower-infra-services` is applied, capture the user-pool-id and send the SAML audience to the IdC owner (Aurimas):
   ```bash
   AWS_PROFILE=axajp terraform -chdir=projects/aws/<client>/terraform/lower/infra/services output -json cognito_sso_application_metadata
   # or, if outputs aren't surfaced: aws cognito-idp list-user-pools --max-results 20 --profile axajp --region us-west-2
   ```
   The infra/services `metadata_url` was already set with Aurimas's IdC SAML metadata URL (Phase 0). You owe Aurimas back the **SAML audience** `urn:amazon:cognito:sp:<pool-id>` (the ACS URL `https://axajp.auth.us-west-2.amazoncognito.com/saml2/idpresponse` was already given). This finalizes the IdC app "AXAJP Lower Cognito" (`ins-7223ce427d94d53c`).

## Capture these outputs — Phase 6 (`argocd-cluster-onboarding`) needs them
After `lower-dev-services` applies, pull from `outputs.tf` (`AWS_PROFILE=axajp terraform -chdir=…/lower/dev/services output`):
- **EKS cluster ARN** → `arn:aws:eks:us-west-2:<account_id>:cluster/aws0<code>deveks01` (e.g. `aws0axajpdeveks01`). Verify: `aws eks describe-cluster --name aws0<code>deveks01 --query cluster.arn`.
- **Internal ALB target-group ARN** → output `alb_eks_target_group_arns` (feeds the istio-gateway-cluster helm component).
- **Internal ALB DNS name** → `aws elbv2 describe-load-balancers --query "LoadBalancers[?Scheme=='internal'].DNSName"`.
- **NLB static IPs** → output `nlb_ips` / `nlb_client_services`.
- **IRSA role ARNs** → output `eks_irsa` (a map) — Phase 6 needs `alb_controller`, `autoscaler` (cluster-autoscaler), `observascope`, `observascope-loki`. Role naming = `aws0<code>deveks01-<alb_controller|autoscaler|observascope|observascope-loki>-Role`. Velero IRSA = output `velero_irsa`.
- **Velero bucket name** → output `velero_bucket_name`.
- RDS/MSK endpoints (outputs `rds`, `msk`, both `sensitive`) → app/delivery handoff (Phase 7), not Phase 6.

## Verification
1. `aws eks update-kubeconfig --name aws0<code>deveks01 --region us-west-2 --profile axajp` then `kubectl get nodes` — system/app/build node pools healthy across 2 AZs.
2. Build-host access entry present: `aws eks list-access-entries --cluster-name aws0<code>deveks01`. SSM into `bld01` and prove cluster-admin (skill `eis-build-host-provision` E2E: `aws sts get-caller-identity` = `…bld01-Role`, `kubectl auth can-i '*' '*'` → yes; trap: export `KUBECONFIG=/root/.kube/config HOME=/root`).
3. Internal ALB Scheme == `internal`; NLB single-AZ in `us-west-2b` (az_index 1) — confirm static IPs.
4. **No public surface:** no IGW on the dev VPC, ALB not internet-facing, no eis-waf — `aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=<dev-vpc>` returns empty.
5. RDS endpoint reachable from a pod / infra subnet; MSK cluster Active.
6. All Phase-6 outputs captured and non-empty (`eks_irsa` map has the 4 IRSA keys).

## Gotchas (quick list)
- Development `/23` auto-subnet calc is FINE (only the **Shared `/23`** in Phase 2 needed `intra_auto_calculate:false`).
- Drop CAA's Fivetran/Redshift/Glue/SFTP + portal S3 buckets — POC scope is lean.
- `eis-ec2 >= v2.2.1` (root volume encryption); doesn't directly apply to dev/services but keep the fleet pin consistent.
- Cognito audience can only be read *after* the infra/services apply — don't block dev/services on it; it's a parallel hand-off.
- Tag everything `Issue = EISSAASDEV-302` for a clean decommission path later (skill `fv-cluster-decommission`).

## Reference run: EISSAASDEV-302 (AXA Japan / axajp)
- account `586117079971` (AXA Japan Lower, SaaS/Lower), profile `axajp`, region `us-west-2`.
- cluster `aws0axajpdeveks01`, dev VPC `10.34.130.0/23` + pod CIDR `100.64.48.0/20`, K8s 1.35.
- Private model: internal ALB, single-AZ NLB (us-west-2b) static IP, private ACM; no IGW/public-ALB/WAF.
- Reference impl = CAA `projects/aws/credit-agricole/terraform/lower/dev/services/` (clone shapes, drop Fivetran/portal extras).
- Reviewer = Markuss (mzivarts) for terraform/iac MRs; apply via IaC Atlantis (exec-order 22 → 23), apply-before-merge.
