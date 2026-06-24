---
name: eis-opensearch-log-masking
description: >-
  Stand up an AWS OpenSearch Service domain in an EIS client/UAT env for application-log
  collection + data-masking testing, and wire the Filebeat → Logstash → OpenSearch shipping
  pipeline (the MassMutual pattern, masking in Logstash). Use when a ticket asks to "deploy
  OpenSearch", "log masking testing", "ship/route application logs to OpenSearch", "OpenSearch
  Dashboards URL/access", set up Filebeat/Logstash for a cluster, configure SAML on OpenSearch
  Dashboards, or grant users OpenSearch access. Encodes the non-obvious blockers: the
  service-linked-role first-domain trap, the Terraform provider's missing saml_options
  (SAML applied via API), the Logstash-OSS xpack/ssl config bugs, the ESO eks01-prefix creds
  trick, containerd log paths, build-host kubectl-over-SSM for private clusters, and E2E from
  inside the VPC. Reference: COEXT-105505 (CAA UAT, aws0caatestos01 on aws0caatesteks01).
---

# EIS OpenSearch + log-masking pipeline (CAA UAT reference: COEXT-105505)

Goal shape: deploy a VPC-internal OpenSearch domain, ship cluster/app logs into it via
**Filebeat → Logstash → OpenSearch** (masking lives in the Logstash filter, owned by SecOps),
expose Dashboards with **SAML SSO**, and grant named users access. Domain = Terraform/Atlantis;
shippers = ArgoCD components; SAML = AWS API (provider gap).

## Ownership split (state this on the ticket early)
- **Infra (us):** OpenSearch domain (TF) + Filebeat & Logstash ArgoCD components + SAML config + access.
- **CAA/CICD:** index strategy / index separation (per the wiki OpenSearch Index Strategy).
- **SecOps:** the actual masking/redaction rules in the Logstash `filter` block.
- Interactive SAML login is the end user's final click.

## 1. Domain — inline Terraform, NOT a module
`lower/test/services/opensearch_custom.tf` (single `aws_opensearch_domain`, one consumer; promote
to an `eis-opensearch` module only if a 2nd project needs it). Reuse the stage's existing
`data.aws_vpc.core`, `data.aws_subnets.private_eks`, `local.prefix_lists`, `local.project_prefix`,
`local.tags`, `data.aws_caller_identity.current`.
- Engine **`OpenSearch_2.17`** (≥2.15 if they want the native `redact` ingest processor).
- Single-AZ `t3.small.search`, gp3 20GB, no dedicated master (UAT test box). FGAC works on 1 node.
- FGAC internal user DB + master user (`random_password`) → store in Secrets Manager; resource
  policy open (`es:*`), SG+VPC+FGAC are the real controls. encrypt-at-rest + node-to-node + TLS1.2.
- **SG ingress = 443 from the pod CIDR (`local.prefix_lists["eks"]`) + the `administrative`
  prefix list (VPN path).** NOT `workspaces-test` — users reach UAT over VPN = administrative
  (reviewer correction on COEXT-105505). Use named prefix lists, not raw CIDRs.
- checkov skips (inline `#checkov:skip`, UAT rationale, mirror `rds_cloudwatch_logs_custom.tf`):
  `CKV_AWS_247` (AWS-owned KMS key), `CKV_AWS_317`/`CKV_AWS_84` (audit/domain logging),
  `CKV_AWS_318` (3 dedicated masters). The repo `.checkov.yaml` already skips `CKV_AWS_149`/`382`.
- Apply via **IaC Atlantis** (`lower/test/services`, exec-order 33). NEVER local `terraform apply`.

### Service-linked-role trap (first OpenSearch domain in an account)
First `CreateDomain` errors: `ValidationException: Before you can proceed, you must enable a
service-linked role to give Amazon OpenSearch Service permissions to access your VPC`. AWS
**auto-creates** `AWSServiceRoleForAmazonOpenSearchService` as a side effect of that failed call →
just **re-plan + re-apply** and it succeeds. Do NOT add `aws_iam_service_linked_role` to TF — once
the SLR exists it conflicts (`EntityAlreadyExists`). After a partial apply, re-plan (state now has
the SG/secret) so the fresh plan only shows what's left.
Domain creation takes ~15–20 min (`aws_opensearch_domain` blocks until active).

## 2. SAML — applied via the AWS API, NOT Terraform (provider gap)
**`aws_opensearch_domain` has no `saml_options` block** — `terraform validate` errors "Blocks of
type saml_options are not expected here." So SAML for Dashboards is configured **out of band**:
```
aws opensearch update-domain-config --domain-name <dom> --region <r> \
  --advanced-security-options file://aso.json    # {"SAMLOptions":{...}} only → partial update keeps FGAC
```
`SAMLOptions`: `Enabled`, `Idp.{EntityId,MetadataContent}` (the IdP metadata XML), `MasterBackendRole`
(SAML group → all_access), `RolesKey`, `SubjectKey`, `SessionTimeoutMinutes`. Because TF can't see
it, SAML is **safe from drift** — record the metadata + config in the repo as docs (a comment + the
`files/saml/idp-metadata.xml`) for reproducibility; no resource change.
- `MasterBackendRole` shows `null` in the config query but it DOES work — it creates the
  `all_access` rolesmapping `backend_roles:[<group>]`. Verify/own it via the Security API
  (`_plugins/_security/api/rolesmapping/all_access`) — PUT to dedupe/preserve.
- CAA used CyberArk Identity (`*.id.cyberark.cloud`), `roles_key=Role`, `subject_key=Subject`,
  group `DevOps`, 480-min session. Get the metadata as a Jira attachment; validate it
  (entityID, IDPSSODescriptor, X509Certificate).
- E2E: domain `SAMLOptions.Enabled=true`; `GET /_dashboards/` → **302 → `/_dashboards/auth/saml/
  captureUrlFragment`** proves SAML is active. (A brief 503 right after the config update is the
  domain settling — re-check.) The interactive CyberArk click-through is the user's.

## 3. Filebeat → Logstash → OpenSearch (MassMutual pattern), via ArgoCD
Don't ship Filebeat → OpenSearch direct; mirror MAM: **Filebeat → Logstash → OpenSearch, masking in
Logstash.** Components live in `iac/argocd/argocd` (the `all-components` ApplicationSet turns
`components/<name>` + `clusters/<cluster>/<name>/values.yaml` + a `cluster-component-config.yaml`
entry into an Application; this cluster forces `syncProject: apps-allowed` → auto-sync+prune, so
**merge = deploy**). Mirror gen-dashboard's registration shape. Logstash syncWave BEFORE Filebeat.
- **Filebeat:** vendor the official Elastic chart, image `filebeat-oss:8.12.x`, `output.logstash`
  → `logstash.<ns>.svc:5044`. 8.x is fine here (it talks to Logstash, not OpenSearch — no
  product-check problem). No OpenSearch creds on Filebeat.
- **Logstash:** image `opensearchproject/logstash-oss-with-opensearch-output-plugin` (bundles the
  `logstash-output-opensearch` plugin; stock Elastic logstash lacks it). `input{beats{5044}}` →
  `filter{ <masking placeholder — SecOps> }` → `output{opensearch{ hosts/user/password ssl index }}`.
- **Containerd (EKS ≥1.24/1.35):** mount **`/var/log` read-only ONLY** (covers `/var/log/containers`
  symlinks + `/var/log/pods` targets) + a RW hostPath for the Filebeat registry. **DROP** MAM's
  `docker.sock` + `/var/lib/docker` (don't exist on containerd). Confirm the path via the live
  Alloy/observascope-logging shipper on the same cluster (it reads `/var/log/pods/...`).

### Logstash-OSS config bugs (both crash the pod — found via E2E, fix before/with deploy)
1. **`xpack.monitoring.enabled` in `logstash.yml`** → FATAL `Setting "xpack.monitoring.enabled"
   doesn't exist` (the OSS image has no X-Pack). **Remove all `xpack.*` settings.**
2. **Bare `${VAR}` in `logstash.conf`** (e.g. `ssl => ${OPENSEARCH_SSL}`) → `ConfigurationError`
   (Logstash grammar rejects unquoted `${...}`; env interpolation only works inside quoted strings).
   Quote them (`"${VAR}"`) or hardcode (`ssl => true`).

### Logstash/Filebeat creds via ESO without an IAM change (the eks01-prefix trick)
The cluster's ESO IRSA policy (`aws0caatesteks01-eso-Policy`) allows GetSecretValue on
`secret:aws0caatesteks01/*`. **Store the shipper's OpenSearch creds in a secret under that prefix**
(e.g. `aws0caatesteks01/logstash-opensearch`) and point the `ExternalSecret` there — no IAM change,
no mzivarts. (Hardening: a scoped write-only FGAC user instead of the master cred.) ⚠️
`aws iam simulate-principal-policy` **falsely returns `implicitDeny` for IRSA roles** even when the
attached policy clearly allows it — trust the policy document, not simulate, for IRSA.

## 4. Access for named users
FGAC internal users (create in Dashboards → Security, or via `_plugins/_security/api/internalusers/
<u>` with master creds from the build host, mapping `opendistro_security_roles:["all_access"]`), OR
SAML group → all_access (above). To grant an SSO/CyberArkOperator role secret-read, it's an IdC
permission-set edit (mzivarts) — verify it landed with `aws iam simulate-principal-policy
--policy-source-arn <reserved-sso-role-arn> --action-names secretsmanager:GetSecretValue` (you can't
assume the SSO role, but you can simulate it).

## 5. Private-cluster access + E2E from inside the VPC (build host over SSM)
The spoke EKS API is private; the build host (e.g. `aws0caatestbld01`, tag query
`*caatest*bld*`) sits in the VPC with cluster access. Drive it via SSM `send-command`:
- `aws eks update-kubeconfig --name <cluster> --region <r> --kubeconfig /tmp/caakc` then ALWAYS pass
  `--kubeconfig /tmp/caakc` to kubectl (SSM runs as root with a HOME quirk → default config not found).
- OpenSearch is reachable from the build host (SG allows the admin prefix list which covers
  10.x). Authed curl (base64 the `caa-os-admin:<pw>` to dodge special-char shell quoting):
  `/_cat/indices/<idx>-*?v`, `/_count`, `/_cluster/health`, `/_plugins/_security/api/rolesmapping`,
  `/_dashboards/` (302→saml).
- E2E proof of the pipeline = the `caa-uat-app-logs-*` indices populate with docs (started at 6.4k,
  grew to ~470k as Filebeat shipped the node log backlog). After a ConfigMap fix, force a fresh
  Logstash pod (`kubectl delete pod -n logstash --all`) and `kubectl rollout restart ds/filebeat-*`
  so Filebeat reconnects to the now-up Logstash.
- Apply SAML/secrets/admin from the build host or with a `Credit-Agricole`-style AdministratorAccess
  profile (separate from the Atlantis CI role).

## Day-2 recovery: endpoint dead / basic-auth 401 after a config change (COEXT-105505, 2026-06-22)
A SAML/config `update-domain-config` triggers a **blue/green** that can leave the domain's **VPC endpoint ENIs dead** — 443 times out **VPC-wide** (confirm from a 2nd in-VPC host, e.g. the build host, to rule out the client/PSM side) while the node is healthy internally (CloudWatch Nodes=1, ClusterStatus.red=0, disk fine) and SG/NACL/route are all permissive and CloudTrail shows no change. Tell-tale: all domain ENIs (`describe-network-interfaces` by the domain SG) show `available`/detached.
- **Fix = reprovision** to rebuild the ENIs: the reliable trigger is an instance change. `t3.large.search` does NOT exist for OpenSearch (t3 stops at `t3.medium`); the 8 GB-class node is **`m6g.large.search`**. `t3.small.search` is too small for sustained log ingestion (JVM ~80%, wedges) — size up.
- Two blue/greens can't overlap — `update-domain-config` returns `A change/update is in progress`; wait for `DomainProcessingStatus=Active` (NOT just `Processing=false` — it sits in `Modifying` through the "Deleting older resources" stage). Watch `describe-domain-change-progress`.
- **Then basic-auth often returns 401 for ALL internal users (master + others)** — the blue/green desynced the `.opendistro_security` internal-user DB. Re-setting the master to the *same* password is a **no-op and does NOT fix it**. Set a **NEW** master password via `update-domain-config --advanced-security-options 'file://{"MasterUserOptions":{...}}'` (applies in ~1 min, no full blue/green) → re-init succeeds → auth 200. SAML logins are unaffected (separate authc), so the user (Dashboards/SSO) may be fine even while basic-auth/the pipeline is 401.
- After the new master password: `put-secret-value` to BOTH the master secret (`aws0caatestos01/master-credentials`) AND the shipper creds secret (`aws0caatesteks01/logstash-opensearch`); force ESO resync (`kubectl annotate externalsecret --all force-sync=$(date +%s) --overwrite` + delete the target k8s secret so ESO recreates it) and `kubectl rollout restart deployment -n logstash` + `daemonset -n filebeat`. Verify the index `_count` climbs again.
- ⚠️ TF drift wrinkle: the domain's `master_user_password` is write-only (Terraform can't read it back), so an API-set new password is NOT auto-reverted by a plan — but TF state still holds the original `random_password`. If a future apply ever re-sends `master_user_options`, it would reset the password away from SM. Codify/ignore as needed.
- Codify the resize in TF (`instance_type`) so Atlantis doesn't revert it; SAML stays API-only (no provider block).
- ⚠️ **A master-credential re-init RESETS the whole security config**: setting a new master password (the 401 fix above) **drops the injected `saml_auth_domain` AND wipes custom rolesmappings** (e.g. `all_access` reverts to just `caa-os-admin`). Symptom: SAML login → `{"statusCode":500,"Internal Error"}`, and Dashboards → Security → Authentication shows only `basic_internal_auth_domain` (no SAML), even though `describe-domain` SAMLOptions still says `Enabled=true`. **Re-applying the identical SAMLOptions is a NO-OP** (AWS sees Enabled=true, won't re-inject). **Fix: toggle SAML off then on** — `update-domain-config --advanced-security-options '{"SAMLOptions":{"Enabled":false}}'` → wait Active → re-apply the full SAMLOptions (Enabled=true + Idp + MasterBackendRole + RolesKey + SubjectKey + SessionTimeoutMinutes) → wait Active. This re-injects `saml_auth_domain` into authc. Then re-add the rolesmapping via the security API (basic auth works): `PUT _plugins/_security/api/rolesmapping/all_access {"backend_roles":["DevOps"],"users":["caa-os-admin"]}`. Verify authc keys include `saml_auth_domain` (GET `_plugins/_security/api/securityconfig` → config.dynamic.authc). **ORDER LESSON: fix master/basic-auth FIRST, then (re)apply SAML last** — doing a master re-init after SAML means redoing SAML.

## Apply/merge reality
Domain = Atlantis (mzivarts approves TF/Atlantis applies, [[feedback-terraform-approver-mzivarts]]).
ArgoCD MRs = GitLab merge → auto-sync (no Atlantis); eramadan can merge. When mzivarts is OOO,
ArgoCD MRs still ship; TF applies need a backup approver. CI on argocd repo: `pluto`/`checkov` jobs
often hang on runners — trust `kubeconform`/`render_manifests`/`helm_unittest` green.

See also: [[coext-105505-opensearch-caa-uat]], [[glab-eis-host-api-access]],
[[eis-idc-scoped-ssm-access]], [[jira-eisgroup-datacenter-access]], skill `eis-ssm-session-hardening`.
