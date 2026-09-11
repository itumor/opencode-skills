---
name: eks-managed-argocd-sso-and-rbac
description: Use when changing who can log into the EIS hub Argo CD or with what role, or when someone proposes an SSO/IdP change for it — "give team X access to Argo CD", "add EDITOR/VIEWER roles", "wire CyberArk/Okta/Entra SSO into Argo CD", "map an AD or Identity Center group to Argo CD", "can we use our IdP with the EKS Argo CD capability". Also use before touching `argocd.tf` in eis-iac at all, because two lines in it can plan a destroy of the GitOps hub for all nine clusters. Encodes what the AWS-managed capability can and cannot do, the multi-role `rbac_role_mapping` Terraform pattern, the five silent footguns (incl. VPCE-endpoint hosts-file requirement), and the CyberArk access-model decision matrix (endpoint/SWS vs proxy/PSM vs identity-source swap).
---

# EKS managed Argo CD — SSO and RBAC

## 0. Facts to establish before proposing anything

1. **The hub is the AWS-managed capability, not self-managed Argo CD.** No `argo-cd` helm chart exists
   in `iac/argocd/argocd`. Created in
   `projects/aws/eis-iac/terraform/lower/dev/services/argocd.tf` via
   `terraform-aws-modules/eks//modules/capability` (v21.15.1), on `aws0iacdeveks01`, managing 9 spokes.
   Anything from the upstream/self-managed Argo CD playbook (Dex, `argocd-cm` SSO, `/api/dex/callback`)
   **does not apply**.
2. **Auth is IAM Identity Center only.** No local users, no custom SSO providers. Third-party IdPs are
   supported *only* by federating them behind IdC.
3. **The org IdC identity source is Active Directory**, and an instance has **exactly one** identity
   source. Confirm with the SID test: `grep -rE 'S-1-5-21-' iac/argocd/argocd/clusters` — SIDs in
   Headlamp/Grafana/dashboard values mean AD-sourced. Only an IdC admin (EISHELP/OPS) can change it.

## 1. What the managed capability cannot do

No Config Management Plugins, no notifications controller, no UI extensions/banners, no `argocd-rbac-cm`
or `argocd-params` (only a subset of `argocd-cm`), sync timeout fixed at 120s, one namespace for
Application/ApplicationSet/AppProject CRs, deployment targets by **EKS cluster ARN only**, no
`argocd login` / `argocd admin`, **max 1000 identities per capability**. Roles are exactly
`ADMIN` / `EDITOR` / `VIEWER`, uppercase, and `EDITOR`/`VIEWER` reach Applications only through
AppProject roles.

## 2. The Terraform pattern for more than one role — live-verified 2026-09-01, `eis-iac!19`

The scaffold you'll actually find in `eis-iac` starts with a **singular** `idc_group_name`/`rbac_role`
pair per capability (one group, one role, hardcoded). Confirmed empirically via `terraform providers
schema -json`: `rbac_role_mapping` is a **`set` of blocks**, so adding a second entry is a pure additive
set-membership change (existing mapping untouched by identity, not just by intent) — no forced
replacement of the capability. Generalize to N roles per capability with an index-flattened data source,
not a `role_groups` map keyed by role name (a plain map can't express two groups mapped to the *same*
role, and loses ordering):

```hcl
# variables.tf — was idc_group_name/rbac_role (singular), now a list
variable "argocd_capabilities" {
  type = map(object({
    cluster_key                   = string
    namespace                     = string
    enable_ecr_access             = bool
    enable_codeconnections_access = optional(bool, false)
    role_mappings = list(object({
      idc_group_name = string
      rbac_role      = string
    }))
  }))
  default = {}
}

# data.tf — flatten (capability_key, role_mapping_index) so each pair gets its own group lookup
locals {
  argocd_role_mapping_pairs = {
    for pair in flatten([
      for cap_key, cap in var.argocd_capabilities : [
        for idx, rm in cap.role_mappings : {
          key = "${cap_key}:${idx}", idc_group_name = rm.idc_group_name, rbac_role = rm.rbac_role
        }
      ]
    ]) : pair.key => pair
  }
}
data "aws_identitystore_group" "argocd_admins" {
  for_each          = local.argocd_role_mapping_pairs   # was var.argocd_capabilities
  identity_store_id = data.aws_ssoadmin_instances.this[0].identity_store_ids[0]
  provider          = aws.identity_center
  alternate_identifier { unique_attribute {
    attribute_path = "DisplayName", attribute_value = each.value.idc_group_name } }
}

# argocd.tf
rbac_role_mapping = [
  for idx, rm in each.value.role_mappings : {
    role     = rm.rbac_role
    identity = [{ id = data.aws_identitystore_group.argocd_admins["${each.key}:${idx}"].group_id, type = "SSO_GROUP" }]
  }
]
```

Key format `"<capability_key>:<index>"` (e.g. `"01:0"`, `"01:1"`) — this is a **data source**, so the key
churning on every edit (old key drops, new key appears) is a harmless read, not a destroy/create like it
would be on a managed resource. `terraform plan` after this change should show exactly one thing on the
capability resource: a `+ rbac_role_mapping { ... }` block added inside `configuration.argo_cd`, with the
pre-existing role's block appearing unchanged. Verify with `terraform show -json <planfile>` and diff
`before`/`after` on `configuration[0].argo_cd[0].rbac_role_mapping` by exact group id — don't just eyeball
the colored diff.

IdC group DisplayNames carry the `@exigengroup.com` suffix. `SSO_USER` works too, but groups keep the
lookup stable and the identity count low.

## 3. Five footguns

1. **`arns[0]`** — `idc_instance_arn = data.aws_ssoadmin_instances.this[0].arns[0]` is order-dependent.
   The moment a second instance is visible from the account (an IdC *account instance*, for example) the
   capability can silently repoint. Pin the ARN.
2. **`for_each = … length(identity_store_ids) > 0 ? var.argocd_capabilities : {}`** — an empty or failed
   IdC lookup makes Terraform plan a **destroy of the hub Argo CD for all 9 clusters**. Pin the store id
   and drop the guard; read the plan's change lines regardless. `eis-iac` applies **locally**, no
   Atlantis gate to catch it.
3. **`DisplayName` lookup vs group rename** — rename a group in AD/SCIM and the plan stays green while
   everyone silently loses the role. (CyberArk SCIM specifically: renaming the destination group creates
   a *new* IdC group and leaves the old one with no members.)
4. **The capability URL changes if the capability is recreated** —
   `https://<id>.eks-capabilities.<region>.amazonaws.com`. Anything pinned to it (Git webhooks, a
   CyberArk web app, an SWS policy) goes stale without an error. Also: never drop
   `network_access.vpce_ids` — that is the only thing keeping the URL private.
5. **VPCE endpoint has no corp-DNS record.** Confirmed live 2026-09-09: VPN alone does not resolve the
   `<id>.eks-capabilities.<region>.amazonaws.com` hostname — new users need static `hosts`-file entries
   pointing it at the VPCE's ENI IPs, not just VPN connectivity. Get current IPs with `aws ec2
   describe-network-interfaces --filters Name=description,Values="*<vpce-id>*"` (from
   `network_access.vpce_ids` on the capability). Give the user **both** ENI IPs, one line each, same
   hostname. `aws0iacdeveks01` ArgoCD hub example (`vpce-073c6400726c4aeca`):
   ```
   10.34.254.142 ed9bf53c873cffcfcc590dd58ea1acd916ce2624a733aebe0.eks-capabilities.us-west-2.amazonaws.com
   10.34.254.66 ed9bf53c873cffcfcc590dd58ea1acd916ce2624a733aebe0.eks-capabilities.us-west-2.amazonaws.com
   ```
   These IPs are only stable as long as the VPCE isn't recreated — re-verify before handing to a new user
   if it's been a while.

## 4. Someone proposes an IdP change — the decision matrix

| Ask | Answer |
|---|---|
| "Put our IdP (CyberArk/Okta/Entra) in front of Argo CD" | Only via IdC. Do **not** configure the vendor's *self-managed Argo CD SAML/Dex* guide — wrong product. |
| "Make CyberArk the identity source" | That replaces AD on the **org** instance. AWS: *"All users, groups, and assignments are deleted from IAM Identity Center"* + the Identity Store ID changes → every console login, every Cognito→IdC dashboard on 9 clusters, every AD-SID CRB dies. EISHELP/OPS decision, and almost never justified by Argo CD alone. |
| "…but the IdP is mandated" | Two contained routes: **(a)** vaulted AD service accounts (credential owned by the PAM tool, AD stays the IdP) — ~6 lines of Terraform, no AWS identity change; **(b)** an IdC **account instance** in the workload account federated to the IdP — AWS lists *Amazon EKS Capabilities* as account-instance-supported; one per account, Region-bound, no permission sets, no convert/merge. |
| "Use eksctl to create it" | No — collides with the Terraform-managed capability. |

CyberArk specifics live in memory `cyberark-sws-endpoint-vs-psm`: SWS + the Identity extension is the
**endpoint** model (the laptop needs the route, recording happens in-browser, TOTP can be injected) and
works with **any app type incl. third-party-IdP apps**; PSM is the **proxy** model (the PSM host needs
the route). Two limits to raise early: recording only covers portal-launched sessions, and **Argo CD API
tokens bypass session recording entirely**.

## 5. Verification battery

```bash
aws sso login --profile iac
aws sso-admin list-instances --profile iac --region us-east-1          # instance ARN + store id to pin
aws identitystore list-groups --profile iac --region us-east-1 \
  --identity-store-id <d-xxxx> --filters AttributePath=DisplayName,AttributeValue=<group>@exigengroup.com
aws eks describe-capability --profile iac --region us-west-2 \
  --cluster-name aws0iacdeveks01 --capability-name <name> \
  --query 'capability.{status:status,url:configuration.argoCd.serverUrl,idc:configuration.argoCd.awsIdc,net:configuration.argoCd.networkAccess,rbac:configuration.argoCd.rbacRoleMappings}'
```

Field is `rbacRoleMappings` (**plural**) — the singular form silently returns `null` even when mappings exist.

E2E after any auth change: log in as a member of each mapped group → the role actually differs (ADMIN
can sync, EDITOR cannot change settings) → **all 9 clusters still listed** under Settings → Clusters →
one Application syncs Healthy → and, if the org instance was touched at all, an AWS console login plus
one Cognito dashboard (Headlamp) still work.

## 6. AppProject-level custom roles (view/sync-only, no capability-role coupling)

A capability-level `VIEWER`/`EDITOR` role only grants login — it does **not** surface any Applications by
itself (fact in §1: EDITOR/VIEWER reach Applications only through AppProject roles). To give a group
*view + sync* in one AppProject but *view-only* in another, add a second role block per `AppProject` CR
(alongside the existing `CLI` role) — one block per permission level:

```yaml
roles:
  - name: CLI
    ...
  - name: sync-refresh
    description: View + sync/refresh only — no create/delete/edit, no cluster/repo/project mgmt
    groups:
      - 90676df1bc-44915912-caea-4bc7-830c-da386b8fa065  # cloud-platform_adm@exigengroup.com — IdC group ID, NOT the name
    policies:
      - p, proj:apps-allowed:sync-refresh, applications, get, apps-allowed/*, allow
      - p, proj:apps-allowed:sync-refresh, applications, sync, apps-allowed/*, allow
      - p, proj:apps-allowed:sync-refresh, clusters, get, *, allow
```

The role **name is arbitrary** and unrelated to the capability-level `ADMIN`/`EDITOR`/`VIEWER` name — Argo
CD matches this policy purely by the caller's `groups` claim. Capability-level `VIEWER` plus this project
role is what grants "see + sync" here, not a project role that happens to be spelled `VIEWER`.

**Gotcha — `groups:` must be the IdC group ID, not the DisplayName.** Unlike the capability-level
`rbac_role_mapping` in Terraform (§2, which resolves `idc_group_name` through a data source), the
AppProject CR's `roles[].groups` is consumed directly by Argo CD with no name resolution — a
`DisplayName`-style entry (`cloud-platform_adm@exigengroup.com`) silently never matches, and the group's
VIEWER user sees zero Applications despite a correct capability-level role. Live in `iac/argocd/argocd`
until `argocd!389`/`!391` (EISHELP-113018) — the pre-existing `CLI` role's `oc-team@exigengroup.com` entry
has the same bug, masked because `oc-team` is mapped `ADMIN` globally and ADMIN bypasses project roles
entirely (§1). Get the ID: `aws identitystore list-groups --identity-store-id <d-xxxx> --region us-east-1
--filters '[{"AttributePath":"DisplayName","AttributeValue":"<group>@exigengroup.com"}]'`
(`GroupId` in the result); confirm the target user is a member with `list-group-memberships
--group-id <id>`.

**Gotcha — capability-level VIEWER can never see Settings → Repositories or Settings → Clusters, and no
project policy fixes it.** Per AWS docs (argocd-permissions.html): VIEWER "Cannot list clusters or
repositories"; EDITOR "Cannot manage clusters or repositories directly" either — only ADMIN gets "List and
access all clusters and repositories." A project-role `repositories, get, *, allow` policy only grants
repo-credential *use inside an Application* (and only when the repo `Secret`'s `project:` label matches —
repos are usually `project: default`, not the caller's project), it does not surface the standalone
Settings page. Don't chase this with more project policy: it's a global-role ceiling. Tell the user the
Applications list already shows `spec.source.repoURL` per app (no separate page needed), or that seeing
the Repositories/Clusters admin page requires ADMIN — which is a real scope escalation, not a rounding
error on "view-only."

**Gotcha — `clusters` resource object format.** For every other resource (`applications`,
`applicationsets`, `repositories`, ...) the object is `<project>/<name>`. For `clusters` it is the
**cluster server URL**, not a project/name glob. A line like
`p, proj:X:role, clusters, *, apps-allowed/*, allow` (copy-pasted from an `applications` line) never
matches any real server and is silently a no-op — seen live in the pre-existing `CLI` role in both
`apps-allowed-AppProject.yaml` and `apps-denied-AppProject.yaml`. Use `clusters, get, *, allow` (bare
`*`) to actually grant cluster visibility.

**Verifying the git→live path.** These CRs live under `bootstrap/clusters/<cluster>/manifest/`,
continuously reconciled (`selfHeal: true`, `prune: true`) by the `bootstrap-<cluster>` Application from
the `cluster-bootstrap` ApplicationSet. The capability has no `argocd` CLI (§1), but the standard
Application-controller refresh mechanism still works via `kubectl` — use it instead of waiting on the
default ~3 min poll interval:

```bash
kubectl --context iac-hub -n argocd annotate application bootstrap-<cluster> \
  argocd.argoproj.io/refresh=hard --overwrite
# then poll:
kubectl --context iac-hub -n argocd get application bootstrap-<cluster> \
  -o jsonpath='{.status.sync.revision} {.status.sync.status} {.status.health.status}'
```

Argo CD's RBAC engine reads the `AppProject` CR directly at request time, so once `status.sync.status`
flips back to `Synced` the new policy is already enforced — no extra propagation delay to account for.

Reference delivery: NOJIRA-000, `argocd!375` (this AppProject change) paired with `eis-iac!19` (the
capability-level `VIEWER` role mapping) — merged and live-verified 2026-09-01.

Related skills: `argocd-cluster-onboarding`, `eis-idc-scoped-ssm-access`, `cyberark-eis-install`,
`headlamp-cyberark-oidc-integration`.
