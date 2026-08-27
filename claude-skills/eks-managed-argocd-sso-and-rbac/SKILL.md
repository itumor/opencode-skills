---
name: eks-managed-argocd-sso-and-rbac
description: Use when changing who can log into the EIS hub Argo CD or with what role, or when someone proposes an SSO/IdP change for it — "give team X access to Argo CD", "add EDITOR/VIEWER roles", "wire CyberArk/Okta/Entra SSO into Argo CD", "map an AD or Identity Center group to Argo CD", "can we use our IdP with the EKS Argo CD capability". Also use before touching `argocd.tf` in eis-iac at all, because two lines in it can plan a destroy of the GitOps hub for all nine clusters. Encodes what the AWS-managed capability can and cannot do, the multi-role `rbac_role_mapping` Terraform pattern, the four silent footguns, and the CyberArk access-model decision matrix (endpoint/SWS vs proxy/PSM vs identity-source swap).
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

## 2. The Terraform pattern for more than one role

Default scaffold maps a single group to a single role. Generalize with a role→group map (keeps the
group-lookup shape, no `aws_identitystore_user` needed) and **pin the IdC identifiers**:

```hcl
# variables.tf
role_groups = map(string)   # "ADMIN" => "argocd_admins@exigengroup.com"
variable "identity_center_instance_arn" { type = string }
variable "identity_center_identity_store_id" { type = string }

# data.tf
locals {
  argocd_role_groups = merge([
    for ck, c in var.argocd_capabilities : {
      for role, group in c.role_groups :
      "${ck}/${role}" => { capability = ck, role = role, group = group }
    }
  ]...)
}
data "aws_identitystore_group" "argocd" {
  for_each          = local.argocd_role_groups
  provider          = aws.identity_center
  identity_store_id = var.identity_center_identity_store_id
  alternate_identifier { unique_attribute {
    attribute_path = "DisplayName", attribute_value = each.value.group } }
}

# argocd.tf
rbac_role_mapping = [
  for k, v in local.argocd_role_groups : {
    role     = v.role
    identity = [{ id = data.aws_identitystore_group.argocd[k].group_id, type = "SSO_GROUP" }]
  } if v.capability == each.key
]
```

IdC group DisplayNames carry the `@exigengroup.com` suffix. `SSO_USER` works too, but groups keep the
lookup stable and the identity count low.

## 3. Four footguns

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
  --query 'capability.{status:status,url:configuration.argoCd.serverUrl,idc:configuration.argoCd.awsIdc,net:configuration.argoCd.networkAccess,rbac:configuration.argoCd.rbacRoleMapping}'
```

E2E after any auth change: log in as a member of each mapped group → the role actually differs (ADMIN
can sync, EDITOR cannot change settings) → **all 9 clusters still listed** under Settings → Clusters →
one Application syncs Healthy → and, if the org instance was touched at all, an AWS console login plus
one Cognito dashboard (Headlamp) still work.

Related skills: `argocd-cluster-onboarding`, `eis-idc-scoped-ssm-access`, `cyberark-eis-install`,
`headlamp-cyberark-oidc-integration`.
