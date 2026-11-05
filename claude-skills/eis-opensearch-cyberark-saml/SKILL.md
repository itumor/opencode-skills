---
name: eis-opensearch-cyberark-saml
description: Use when an AWS OpenSearch Dashboards domain must sign in through CyberArk Identity (Idira) SAML, or must switch from Cognito/IdC to CyberArk - "configure CyberArk as IdP on <domain>", "SAML metadata attached", "roles key Role / session 28800", "open 443 from the PSM to OpenSearch", "which AD groups get access", "reader groups / app logs only", and on login errors after SAML is on - "Unable to Launch Application / You do not have access", a 500 at /_dashboards/_opendistro/_security/saml/acs/idpinitiated, "InResponseTo ... while no InResponseTo was expected", "SAML url not accepted". Full A-Z cycle - Terraform (eis-opensearch >= v1.4.1), Cognito disable + removal, FGAC admin/reader roles, CyberArk-side asks, E2E. Reference COEXT-111310 aws11caashareos01 (CAA upper share), 2026-10-14.
---

# OpenSearch Dashboards via CyberArk SAML (A to Z)

Reference delivery: COEXT-111310, CAA `aws11caashareos01` (acct 144905517910, eu-west-3), 2026-10-14.
MRs: eis-opensearch !10 (v1.4.1), credit-agricole/terraform !233 (443), !238 (SAML), !239 (reader
roles docs), !240 (Cognito removal). Memory: [[coext111310-psm-opensearch-443]].
Tool: `~/.claude/scripts/opensearch-fgac.py` (master-role SigV4 req, drop-backend-role, authn-request decode; `--selftest`).
Related: [[eis-opensearch-cognito-idc-login]] (the Cognito path this replaces), headlamp-cyberark-oidc-integration.

## 0. What the ticket really asks (typical CAA shape)
1. CyberArk as SAML IdP: metadata XML attached to Jira, IdP entity ID, `Roles key: Role`, `Session TTL 28800` (seconds = 480 min).
2. Open 443 from the CyberArk PSM host (e.g. `aws11caasharepsm01`). That host runs the CyberArk connector behind CyberArk's **App Gateway** (`<id>-gw.gateway.id.cyberark.cloud`), so the 443 rule is what makes the gateway work. Skill: open-port-host-to-service (SG-to-SG rule).
3. "Provide a list of AD groups". We answer: admin + one read group per stage (step 5).

The CyberArk admin (CAA: Denys Zvenyhorodskyi, `dzvenyhorodskyi`) owns the app; we own the domain.

## 1. Gather + check (read-only)
- Download the attachment via Jira REST (python, token from `~/.zshrc`; see eis-jira-rest-ops). `xmllint --noout`; entityID must equal the ticket IdP entity ID; check the signing cert expiry.
- `aws opensearch describe-domain --query 'DomainStatus.{Cognito:CognitoOptions,Saml:AdvancedSecurityOptions.SAMLOptions,FGAC:AdvancedSecurityOptions.Enabled}'` - save as before-state.
- Consumer TF usually already has a `saml` block in `var.opensearch` (opensearch_custom.tf); the XML goes to `files/opensearch/<domain>-idp-metadata.xml` **with a trailing newline** (end-of-file-fixer fails CI otherwise).

## 2. Terraform: Cognito -> SAML in ONE apply
Traps (all hit live):
- **Removing `cognito_options` is a no-op**: aws provider `SuppressMissingOptionalConfigurationBlock` (v6.38.0 domain.go:463). Cognito stays on and SAML enable fails. Disable explicitly: `opensearch_cognito_options = { ..., enabled = false }` (needs eis-opensearch **>= v1.4.1**; v1.4.0 also rejected Cognito+SAML in validation).
- Keep the Cognito pool in this apply (rollback = `enabled = true`, `saml = null`). Remove it in a follow-up (step 6).
- tfvars:
```hcl
saml = {
  idp_entity_id           = "https://<tenant>.id.cyberark.cloud/<app-id>"
  idp_metadata_file       = "files/opensearch/<domain>-idp-metadata.xml"
  master_backend_role     = "elk_<proj>-stage-prod_admin"   # AD group NAME (CyberArk sends names)
  roles_key               = "Role"
  session_timeout_minutes = 480
}
cognito = { saml_metadata_url = "<old>", enabled = false }
```
- Expected Atlantis plan: domain in-place `cognito_options.enabled true -> false`; `aws_opensearch_domain_saml_options` create; domain_policy "known after apply" (same statement, no-op); anything else = carried drift (CAA share always shows guardduty `RDS_DATA_RISK`).
- Disruption: BLIP. Blue/green ~15 min (14m41s) + SAML options ~16 min. Ingest continues; Dashboards login down until CyberArk side done. Watch: `describe-domain-change-progress`.
- Local CI: gitlab-ci-local fails structurally on module fetch (fake job token) - run `pre-commit run --files <changed>` from repo root + `terraform validate` instead; worktrees need a `--no-local` scratch clone for gcl.

## 3. Verify the SP side + hand values to CyberArk
```bash
python3 -I ~/.claude/scripts/opensearch-fgac.py --endpoint https://<custom-endpoint> authn-request
```
Prints the real AuthnRequest: `Issuer` = SP entity ID (`https://<custom-endpoint>`, no slash), `AssertionConsumerServiceURL` = `https://<custom-endpoint>/_dashboards/_opendistro/_security/saml/acs`. Custom endpoint, never the `vpc-...es.amazonaws.com` one.
In-domain check (master role): `req GET /_plugins/_security/api/securityconfig` -> `saml_auth_domain` http_enabled, roles_key, sp.entity_id, idp.entity_id; `rolesmapping/all_access` contains the admin group.

## 4. CyberArk-side asks (send in one comment)
- Permissions: assign the AD groups to the app (**default = nobody**; symptom: `Unable to Launch Application - You do not have access to this application`, CyberArk `/run` page, after auth).
- SAML attribute `Role` = AD group names (multi-value).
- **CyberArk limit**: the app takes the SP entity ID *or* a separate ACS, not both, so ACS ends up `.../saml/acs/idpinitiated`. Consequence: login works **only from the CyberArk portal** (CAA: `https://eisgroupfr.cyberark.cloud` -> OpenSearch app). Opening the Dashboards URL directly = SP-initiated -> 500, log line `The Response has an InResponseTo attribute: ONELOGIN_... while no InResponseTo was expected` (ES_APPLICATION_LOGS). Accepted; tell users to start from the portal.
- Before CyberArk you may see the Idira "Your session is being monitored / Step recording" screen (auth.alero.eu): that is CyberArk session recording, click Continue - not an error.

## 5. FGAC roles (in-domain, master role, runbook - not Terraform)
- Admin: nothing to do; SAML `master_backend_role` maps the admin group to `all_access` (+ security_manager).
- Readers (client + developers): one role per stage, app logs only. **Take the pattern from live index names, not from a design doc**: `_cat/indices?h=index` (strip the date). The cd-common Logstash writes `<stage>-<cluster>-<ns>-application-*`, `<ns>-dependency-*`, `infrastructure-*`; CAA shipped `-app-*` (matched nothing, readers saw 0 logs until 2026-11-03, MR !281). Check the new pattern against the families (fnmatch) before PUT. Template/ISM/shipper roles on `<stage>-<cluster>-*` cover all families.
```json
{"cluster_permissions":["cluster_composite_ops_ro"],
 "index_permissions":[{"index_patterns":["stage-<cluster>-*-application-*"],"allowed_actions":["read","indices:admin/mappings/get","indices:admin/resolve/index"]}],
 "tenant_permissions":[{"tenant_patterns":["global_tenant"],"allowed_actions":["kibana_all_read"]}]}
```
  Map `log_reader_<stage>` -> `{"backend_roles":["elk_<proj>-<stage>_r"]}` and nothing else. **Never** map readers to `opensearch_dashboards_read_only`: on AWS it is the `readonly_mode` role, security-dashboards-plugin marks every app except home/dashboards/overview `inaccessible` (Discover only with `allow_discover`, not settable on AWS) -> readers see only "Dashboards" in the nav (CAA 2026-11-04). Read-only global tenant comes from `kibana_all_read` in the role itself. **Not** `opensearch_dashboards_user` either (grants `kibana_all_write` on global tenant).
- Apply with `req PUT /_plugins/_security/api/roles/<name> <file>`; read back (server adds empty `fls`/`masked_fields`). Keep the JSON + runbook step in the repo (CAA: `docs/terraform/custom/opensearch/`, runbook step 7) - docs MR, no Atlantis plan.
- The auto-mode classifier may deny in-domain writes ("Modify Shared Resources"): hand the exact command to the user.
- **Index patterns** (readers have `kibana_all_read`, cannot create them): create in the global tenant via `POST _dashboards/api/saved_objects/index-pattern/<id>` (`osd-xsrf: true`, `securitytenant: global`), one admin pattern `<stage>-<cluster>-*` + one reader pattern = the reader role's pattern (else Discover hits forbidden indices). An API-created pattern has **no saved field list** -> Discover "Could not locate that index-pattern-field (id: @timestamp)", no histogram; the UI "Reload field list" did not persist. Fix: `GET _dashboards/api/index_patterns/_fields_for_wildcard?pattern=<pat with * as %2A>&meta_fields=_source&meta_fields=_id&meta_fields=_index` -> `PUT saved_objects/index-pattern/<id>` `{"attributes":{"fields":"<.fields|tojson>"}}`, then hard-reload the browser. CAA runbook step 7 has the `d()`/`f()` helpers.

## 6. Remove Cognito (follow-up MR)
- tfvars `cognito = null` -> plan: ~10 destroys, all in `module.opensearch_cognito[...]`, no domain change (disabled block stays, ignored).
- eis-cognito v1.3.0 hardcodes `deletion_protection = "ACTIVE"`: user runs right before apply `aws cognito-idp update-user-pool --user-pool-id <id> --deletion-protection INACTIVE` (resets other pool settings - irrelevant, pool is deleted next).
- Before/with it: remove the Cognito authenticated-role ARN from `all_access` (a recreated role name would regain admin): `opensearch-fgac.py ... drop-backend-role all_access <arn>` (full PUT; PATCH has no `test` op, bare index remove races).
- Ask the IdC admin (Markuss) to delete the old IdC SAML app.

## 7. E2E (before "done")
1. Data plane: `_cluster/health` green, `securityconfig` saml on, mappings read back.
2. User logs in **from the portal**; Dev Tools `GET _plugins/_security/authinfo` -> `backend_roles` has the group, `roles` has `all_access` / `log_reader_<stage>`. No SAML errors in ES_APPLICATION_LOGS after the login time.
3. Reader check once shipping starts: `_r` user sees `-*-application-*`, not `-infrastructure-*` / `-dependency-*`.

## Reaching the domain (in-domain API)
- `opensearch-fgac.py` needs `--role-arn` = the FGAC master role (CAA: `arn:aws:iam::144905517910:role/aws11caashareos01`, profile `CAA-Upper-Admin`). Without it the script crashes (`RoleArn ... None`).
- CAA domain SG `sg-06ae2bbfdb51fada8` allows 443 only from the EKS subnets 10.70.35/37 + the PSM SG. The EIS VPN (10.31.252.x) times out, there are no SSM instances, and the EKS endpoints are private (2026-11-04). Do not widen the SG.
- Working path: Claude in Chrome on the user's session -> CyberArk portal "SAML CAA Opensearch" tile -> page JS (needs admin group in the assertion):
```js
const p = async (path, method='GET', body) => (await fetch(`/_dashboards/api/console/proxy?path=${encodeURIComponent(path)}&method=${method}`,
  {method:'POST', headers:{'osd-xsrf':'true','content-type':'application/json'}, body: body && JSON.stringify(body)})).text();
```
  Check `authinfo` roles = `all_access` first. Through the gateway `_dashboards/api/saved_objects` returns 500: check index patterns in the UI (`app/management/opensearch-dashboards/indexPatterns?security_tenant=global`). Proof screenshots: `app/security-dashboards-plugin#/roles/view/<role>/mapuser`.

## Gotchas
- Reader-visible "only Dashboards in nav" = the reader is mapped to `opensearch_dashboards_read_only` (readonly_mode). Fix = empty that mapping, keep `log_reader_<stage>`. The CAA docs JSON `rolesmapping-dashboards-read-only.json` still holds the old mapping (= rollback, do not apply). The user wants payload files kept untouched.
- The global default index pattern is admin-only (`stage-aws11caastageeks01-*`), so a reader's first Discover load errors until they pick their `-application-*` pattern and the Global tenant.
- pip botocore can't read the CLI SSO cache (UnauthorizedSSOTokenError while `aws sts` works) - the script uses `aws configure export-credentials`.
- SigV4 (`curl --aws-sigv4`) fails with a signature mismatch on `,` or `*` in the URL **path** (`_cat/indices/stage-*`): list all (`_cat/indices?h=index`) and grep, or put the wildcard in a query string as `%2A`.
- After SAML login the browser lands on the CyberArk gateway host `<id>-gw.gateway.id.cyberark.cloud/_dashboards/...`, not the custom endpoint; build Discover links on that host with `?security_tenant=global`.
- `describe-domain` returns `MasterBackendRole: null`; prove the admin mapping via `rolesmapping/all_access`.
- Jira wiki: `-...-` in index names renders as strikethrough; wrap them in `{{ }}`.
- Reader-only failure triage (CAA COEXT-112355, 2026-11-04): readers mapped to `opensearch_dashboards_read_only` can also get "Something went wrong / Internal Server Error" right after portal login; DevTools shows `/_dashboards/api/core/capabilities` -> gateway `Error tunnelling to <endpoint>: Unable to process HTTP header section after 21 reads in 45000 ms`. AUDIT_LOGS show one `MISSING_PRIVILEGES` `anonymous` `GET /_plugins/_security/authinfo` (header `x-opensearch-product-origin: opensearch-dashboards`) per attempt. Admins fine. Fix = the read-only mapping rule in step 5, not the `log_reader_*` mapping.
- AUDIT_LOGS forensics with default AWS audit config (`AUTHENTICATED`/`GRANTED_PRIVILEGES` disabled): successful logins are invisible, but `MISSING_PRIVILEGES`, `FAILED_LOGIN` and `COMPLIANCE_INTERNAL_CONFIG_READ/WRITE` (doc id `rolesmapping`/`roles`/`audit` + version + effective user) are logged - use them to time user attempts and prove who changed a mapping. `PATCH _plugins/_security/api/audit` returns 200 but AWS rewrites the audit doc ~4 s later (v3 -> v4): audit categories cannot be changed over REST on a managed domain.
- Data plane from a Mac (CAA): EIS corporate VPN -> 443 connect timeout (domain SG admits only shipper subnets, PSM SG and the network-hub break-glass Client VPN SG). Connect the **AWS VPN Client** (hub Client VPN, IdC SAML) first, then `opensearch-fgac.py` works.
