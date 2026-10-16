---
name: eis-opensearch-cognito-idc-login
description: Use when humans need to log into an AWS OpenSearch Dashboards domain on an EIS account that has no CyberArk (upper stage/prod/share) — "give us Dashboards access", "OpenSearch login via SSO/IdC/AD group", "Cognito for OpenSearch", "can we use OIDC for OpenSearch" (no: SAML or Cognito only), "add a person to OpenSearch". Builds the Headlamp pattern: eis-cognito Dashboards pool federated to an IAM Identity Center SAML app, eis-opensearch cognito_options passthrough, OpenSearch app-client SSO step, FGAC mapping, E2E. No users in code. Reference: COEXT-109331 aws11caashareos01, 2026-10-09.
---

# OpenSearch Dashboards login: Cognito federated to IAM Identity Center

Reference delivery: CAA `aws11caashareos01` (COEXT-109331 / COEXT-110965, CAA !226, eis-cognito v1.3.0,
eis-opensearch v1.4.0). Memory: [[opensearch-dashboards-cognito-idc-federation]], [[feedback-no-users-in-code-reuse-team-pattern]].

## 0. Pick the method first
| Need | Method |
|---|---|
| Account has CyberArk (lower UAT) | SAML via CyberArk (wiki 786413434) |
| Read-only groups needed now | SAML direct to the domain (IdC app audience = domain URL; group id -> FGAC role natively) |
| Admins only, team wants the Headlamp pattern | **this skill** (Cognito federated) |
AWS-managed OpenSearch has NO plain OIDC. With Cognito every user gets ONE authenticated role, so everyone admitted is the same FGAC role.

## 1. Prereqs (external, start early)
- AD groups via EISHELP Access Request (memory eishelp-ad-group-requests). Check they reached IdC: `aws identitystore list-groups --identity-store-id d-90676df1bc --region us-east-1 --filters AttributePath=DisplayName,AttributeValue=<name>@exigengroup.com`. Sync took ~20 h on 2026-10-08/09; ask the IdC admin if a fresh group is missing while `headlamp_caa_*` resolve.
- IdC custom SAML 2.0 app: only the IdC admin (instance owned by 455655288646; we lack sso:CreateApplication). Ask for the metadata URL first; ACS/audience come after the pool exists (step 3).

## 2. Terraform (consumer stack of the domain)
```hcl
module "opensearch_cognito" {   # eis-cognito >= v1.3.0
  source   = "git::https://sfo-devopsgit01.eqxdev.exigengroup.com/iac/terraform/modules/aws/eis-cognito.git?ref=v1.3.0"
  for_each = { for key, cfg in var.opensearch : key => cfg if cfg.cognito != null }
  project_prefix = local.project_prefix
  config         = null
  tags           = each.value.tags
  opensearch_dashboards = {
    domain_name       = local.opensearch_domain_names[each.key]
    saml_metadata_url = each.value.cognito.saml_metadata_url
    issue             = each.value.issue
  }
}
# module "opensearch" (eis-opensearch >= v1.4.0):
opensearch_cognito_options = each.value.cognito != null ? {
  user_pool_id     = module.opensearch_cognito[each.key].opensearch_dashboards.user_pool_id
  identity_pool_id = module.opensearch_cognito[each.key].opensearch_dashboards.identity_pool_id
  role_arn         = module.opensearch_cognito[each.key].opensearch_dashboards.service_role_arn
} : null
```
- tfvars: `cognito = { saml_metadata_url = "https://portal.sso.us-east-1.amazonaws.com/saml/metadata/..." }`. No users, no groups.
- Regenerate `.terraform.lock.hcl` (eis-cognito brings hashicorp/local) for linux/darwin amd64+arm64.
- Never add the Cognito resources to the opensearch module's `depends_on` (memory tf-module-depends-on-defers-data-sources: SG replace).
- Expected plan: ~10 add (pool, hosted-UI domain, SSO IdP, identity pool + roles attachment, 2 roles, policy, attachment, eis-cognito random_password) + domain `cognito_options` in-place + domain policy no-op re-render.
- Disruption: **BLIP, blue/green** (~15 min on a 9-node domain), memory opensearch-cognito-options-blue-green.

## 3. After apply (in order)
1. Read pool id; send the IdC admin: ACS `https://<domain>.auth.<region>.amazoncognito.com/saml2/idpresponse`, audience `urn:amazon:cognito:sp:<pool id>`, attribute mapping as the Headlamp app, assign admin groups only.
2. Add `SSO` to the app client OpenSearch created (keeps all other fields): template `~/.claude/change-runs/COEXT-109331-110965.cognito-appclient.sh` (set POOL_NAME). Re-run after any later domain config change.
3. Map the authenticated role into FGAC, additive: `PATCH _plugins/_security/api/rolesmapping/all_access` `[{"op":"add","path":"/backend_roles/-","value":"<...-cognito-auth role ARN>"}]` as the master role (template `...indomain-cognito.sh`).
4. Verify: `...verify-cognito.sh <out>` must be 0 FAIL (domain cognito on + Processing false, pool MFA/no self sign-up/domain, SSO IdP, app client lists SSO, identity pool unauth off + provider, `/_dashboards/` 302 to hosted UI). Each user logs in (VPN -> SSO button) and runs `GET _plugins/_security/authinfo`; pool shows `sso_<email>` EXTERNAL_PROVIDER.

## 4. Module release traps
- eis-cognito / eis-opensearch main pipeline goes red on the merge-commit lint after every MR merge -> `publish_release` skipped. Fix per run: `glab api -X POST "projects/<id>/pipeline?ref=main"` then play publish_release (memory gitlab-merge-commit-lint-ff-fix).
- Local terraform-docs 0.24 vs pin 0.20: `python3 ~/.claude/scripts/tfdocs-regen-020.py`; the user sends eis-* module branches (agent pre-push hook fails terraform_docs).

## 5. Verified 2026-10-09 (reference run)
- Logins: eramadan 11:31, mzivarts 12:37 (pool users `sso_<email>`, EXTERNAL_PROVIDER). Aliaksei pending as of 10-14.
- Blue/green on enable took 14m40s on the 9-node domain; plan it as BLIP.
- Scripts used: `COEXT-109331-110965.cognito-appclient.sh`, `...indomain-cognito.sh`, `...verify-cognito.sh` (0 FAIL expected).
- After login works, the shipper is a separate track: CI/CD (Jenkins, Aliaksei Kudzko). See memory [[caa-jenkins-hosts]].

