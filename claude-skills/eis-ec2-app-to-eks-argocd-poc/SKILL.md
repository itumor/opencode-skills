---
name: eis-ec2-app-to-eks-argocd-poc
description: Use when moving an Ansible/EC2-hosted app (Nexus, SonarQube, Jenkins, Keycloak, OpenGrok, Datadog PL, GitLab ...) to EKS via ArgoCD as a POC on pref-dev (aws0prefdeveks01), "Migrate <X> from EC2 to EKS POC" Jira tickets (GENESIS-4255xx/4475xx), or when a stateful app on EKS needs RDS + S3 + IRSA + secrets + DB bootstrap automated end to end. Reference implementation = Nexus GENESIS-425582 (2026-10-16..19). Gives the phase order, the gates, the exact file patterns, the E2E/resilience/rebuild proofs, and every trap hit on the way.
---

# EC2 app -> EKS (ArgoCD) feasibility POC

Reference run: **Nexus 3.97.0 CE, GENESIS-425582**. Full A-Z write-up + diagram: `iac/docs/nexus-poc-a-to-z.md`.
Outcome wording for Jira: **feasibility POC**. Data migration, client cutover, prod recovery = future work. EC2 hosts untouched.

## 0. Before any code (1-2 h, zero AWS cost)
1. Ticket + candidate row: `iac/docs/ec2-to-eks-migration-candidates.md`. Jira keys: `scratchpad keys.json` pattern (one ticket per app).
2. **Licence/edition gate.** Find the limits of the free edition (Nexus CE: 40k components / 100k requests/day, SAML Pro-only). Write them into the decision section. Never assume a feature works on the free edition: prove it.
3. **Local spike** (docker, throwaway DB + S3 mock) for anything uncertain: storage backend on free edition, DB init, first-start password, EULA/onboarding gates. Record HTTP codes. Ask the user to decide at the gate with the evidence.
4. **Chart review:** `helm template` the upstream chart with intended values; read StatefulSet, config Job, secret wiring. Note defaults that must be overridden (Nexus: `persistence.enabled=false`, `chownDataDir`, `updateStrategy: {}`, LDAP email attr).
5. Plan (plan mode) with: MR list + order, gates, three-plan Terraform evidence, rollback split (app / infra / data), validation matrix. Get it reviewed.

## 1. AWS side: one MR in `projects/aws/pto-reference/terraform`, `lower/dev/services` (Atlantis project `lower-dev-services`)
| Piece | Pattern (Nexus files) |
|---|---|
| RDS | separate `module "rds_<app>"` (NOT `var.rds["NN"]`: that for_each drags Fivetran PG/SG). `eis-rds?ref=v2.0.1` (v2.1+ breaks plan role). Explicit backups 7, deletion_protection, final snapshot. `rds_nexus.tf` |
| S3 | `terraform.tfvars` `s3["<app>-blobs"]` via existing `module "s3"` |
| IRSA | `eks.tf` `local.irsa_custom.<app>` -> role `<eks>-<key>-Role`, policy file `files/iam/eks/<app>-s3.json` scoped to ONE bucket. Trust sub `system:serviceaccount:<ns>:<sa>` |
| Secrets | `<app>_secrets.tf`: `aws_secretsmanager_secret` for_each + `import {}` for any hand-made secret, ephemeral `random_password` -> `secret_string_wo` (+`_wo_version`). Names under `<eks_name>/<app>/...` = ESO read scope (`irsa.tf:30` `secret:<prefix><eks_name>/*`). Master DB secret OUTSIDE that prefix. `# eis-raw-ok:` + `checkov:skip=CKV_AWS_149` with reason. `nexus_secrets.tf` |
| DB bootstrap IRSA | second irsa_custom `<app>-db-bootstrap` reading ONLY the master secret ARN |
| RDS master | `rds_password = random_password.<app>_master.result`, bump `rds_password_version` to take over |
Gates: `terraform fmt -check` (prints filename = FAIL), `validate` with own creds, tflint, checkov `--config-file .checkov.yaml`, trivy per file, `gitlab-ci-local` in a plain clone (module 403 = local-only), push by user (pre-push guard), pipeline green, **targeted** Atlantis plan (full plan carries Fivetran SG + coredns drift on pref-dev - never apply that), audit every resource, Disruption line, user applies, then merge.

## 2. Cluster side: `argocd/argocd` playground only (`components-playground/<app>`, `clusters/aws0prefdeveks01/<app>`)
| Piece | Pattern |
|---|---|
| Wrapper chart | `Chart.yaml` deps: `deployment-template` (`file://../../templates/deployment-template-playground`) + upstream chart pinned; `templates/{template.yaml,secrets.yaml,smoke-test-job.yaml}` copied from headlamp |
| Secrets | `secrets: [admin, db, ...]` -> ExternalSecret `<name>-secret` from `<secretPath>/<name>`. **Override `secretPath`** in cluster values (cluster-level rnd/cicd path is inherited otherwise) |
| Images | every image by digest (`docker buildx imagetools inspect`); `tag: "-"` + digest for floating-tag images |
| Storage | StatefulSet `RollingUpdate`, PVC `retainDeleted/retainScaled`, gp3 SC `ebs-csi-default-sc` |
| DB bootstrap | PreSync SA (wave -10) + Job (wave 0): aws-cli init fetches master via IRSA into memory emptyDir, postgres client runs idempotent SQL (role, db OWNER, extension), password via psql `\getenv`, read-only FS, uid 70. `templates/db-bootstrap.yaml` |
| App config | upstream config Job as **PostSync + BeforeHookCreation** (else selfHeal recreates it). Repos/roles/realms/blob stores in values = rebuildable. Upsert scripts: `case` on the GET code, 200 = PUT, 404 = POST, anything else exit 1 (never treat 429/401/5xx as "missing"); code list from live `/service/rest/swagger.json` |
| Metrics | check Prometheus `serviceMonitorSelector` (pref-dev `{}` = all) AND curl the metrics path in-pod anonymously. Nexus 3.97: `/service/rest/metrics/prometheus` = 401, chart SM path `/service/metrics/prometheus` 301s there -> needs metrics-only user + basicAuth secret, never admin creds |
| AD login | LDAPS `exigengroup.com:636`, bind `CN=ldap,CN=users,DC=exigengroup,DC=com`, pw = Vault `secret2/<proj>/automation/ldap:adpassword` copied once into `<eks>/<app>/ldap`. AD root CA = Vault `secret2/ansible/automation/ldap:ad_ca_certificate_pem` (SHA-1 `39:CA:F2:08:...:21:17`), public, in values -> Secret -> JVM truststore. Group CN = role id. Check the user's real groups with a LDAP-source user lookup before choosing the admin group |
| Ingress | `useClusterGateway`, host `<app>.dev.aws0.pref.eislab.cloud` (wildcard cert); non-HTTP ports (docker 5002) = port-forward only |
| Registration | `clusters/aws0prefdeveks01/cluster-component-config.yaml` `<app>: {namespace, wave}` |
Docs: copy the A-Z into `argocd/argocd docs/` with a `!/docs/<f>` .gitignore line (docs-only MR has no pipeline, by design).
Gates: helm template (cluster values + component + cluster-app values), kubeconform, checkov/trivy on rendered new objects, gitlab-ci-local (scaleops 401 WARNs = local-only), push, MR reviewer eramadan, pipeline 13/13, **PR-Agent: read every round, answer each item with evidence** (hook `push-feedback.sh` does the waiting), user merges, refresh Argo if the CodeConnections mirror lags.

## 3. Proof (scripts, never claims)
Pattern script: `~/.claude/scripts/nexus-e2e.sh` (`check|setup|artifacts|docker|counts|--selftest`, port-forward on a free port, creds via `curl -K -` stdin, `ADMIN_STAGE=AWSPREVIOUS` during rotation).
1. infra + pod + ExternalSecrets (fully-qualified CRD `externalsecrets.external-secrets.io`, retry) + IRSA env.
2. DB = PostgreSQL, non-master user, TLS (`pg_stat_ssl`).
3. IRSA positive (own bucket) + negative (other bucket AccessDenied).
4. Real artifacts: upload, download, sha256 equal; docker push/pull digests; proxies; anonymous refused.
5. URL origin proof: marker request through DNS -> ALB -> istio -> pod log.
6. Resilience: pod delete; PVC + pod delete (counts equal); RDS reboot (no pod restart, pool reconnect, writes after).
7. **Rebuild from scratch:** empty bucket, drop DB (pod with bootstrap IRSA SA, `DROP DATABASE ... WITH (FORCE)`), delete PVC + pod -> Argo alone must rebuild everything. EULA = user.
8. AD: LDAP-source user lookup via REST, then UI login; Nexus log shows the user.

## Traps hit (do not repeat)
- `chownDataDir: false` on fresh EBS -> `AccessDeniedException /nexus-data/etc/fabric` (kubelet subPath dirs root-owned).
- Stuck Argo op on an unhealthy StatefulSet blocks new revisions: patch `operationState.phase=Terminating` (user), delete the never-Ready pod once.
- Chart LDAP step (nexus3 5.27.0 `configure.sh:260`) sed-escapes `/` before `jq --arg` -> bind pw with `/` broken. Own PostSync Job with `jq --rawfile`.
- Secret rotation by Terraform while the app keeps the old admin pw -> PostSync config Job 401 -> 429 rate limit -> selfHeal retry loop. Plan rotation together with the rebuild.
- StatefulSet `volumeClaimTemplates` gets `apiVersion/kind/status` from the API server (+ `spec.volumeMode`) -> permanent OutOfSync -> **every argocd main merge** (any component) re-syncs the app and reruns all hooks (`status.history[].revisions` = one sync per main revision, not a timer). Prove fix offline: live STS json with the 4 paths `jq del(...)` == helm render. Fix = `ignoreDifferences` for that StatefulSet's `volumeClaimTemplates` in `apps/appsets/playground-components-appset.yaml` (argocd !523); add it in the SAME MR as any new StatefulSet app. Memory: argocd_sts_vct_outofsync_reruns_hooks_every_merge.
- Helm-hook ExternalSecrets are deleted+recreated each sync: the k8s Secret vanishes for seconds (a pod start in that window fails).
- CE EULA must be accepted on every fresh DB before uploads (403 otherwise). Legal = user, never automated.
- `terraform fmt -check .` prints the file name on failure; read it, do not assume ok.
- Pre-push guard text-matches `git push` even inside a heredoc/JSON; build test input in a file.
- Blast Radius cannot prompt in the desktop session: destructive steps go to the user as `!` commands, one per message, verify each server-side.
- Reply buttons never run commands. Print every command BEFORE wrap_up; verify after (ls-remote, describe-secret, pod age).
- Squash merges rewrite SHAs: verify by `git diff <branch-sha> origin/main -- <paths>` = 0.
- Hub reads git via AWS CodeConnections mirror: Argo may lag; refresh annotation is user-run (deploy-guard). Check the target object (appset/app spec) first: !523 appset change landed in ~5 min unaided.
- Post-merge proof: app Synced + `status.history[-1].id` unchanged 15 min + hook Job creationTimestamps unchanged; recheck next morning.

## SonarQube variant (GENESIS-447522, argocd !506/!510/!514/!532)
- Chart `sonarqube` (SonarSource). LDAP is plain `sonarqube.sonarProperties` (`sonar.security.realm=LDAP`, `ldap.url=ldaps://exigengroup.com:636`, `ldap.user.request=(&(objectClass=user)(sAMAccountName={login}))`, `ldap.group.request=(&(objectClass=group)(member={dn}))`, `ldap.group.idAttribute=cn`). The bind password goes in `sonarqube.env` `LDAP_BINDPASSWORD` from `ldap-secret`. For the CA, set `caCerts.{enabled,secret}`; the chart adds `-Djavax.net.ssl.trustStore` itself.
- Group sync maps AD groups only onto SonarQube groups that already exist. A PostSync Job (`templates/ad-groups.yaml`, curl image) creates them via `/api/v2/authorizations/groups` (v1 `user_groups` was deprecated in 10.4) and runs `POST /api/permissions/add_group permission=admin`. The admin password comes from SM `<eks>/sonarqube/admin`.
- Proof: web.log `Test LDAP connection on ldaps://...: OK`; `/api/users/search` shows `externalProvider=LDAP_default` plus the groups. New AD users get a generated login (`ebrahim-ramadan83961`), and the sign-in name stays the sAMAccountName.
- Data: restore EC2 DB -> RDS, then upgrade 25.1 -> 25.12 LTA -> 26.x (one MR per hop + `POST /api/system/migrate_db`). The first pod never gets Ready, so delete it once (OrderedReady).
- Survey of other EIS EC2 Sonars (2026-10-20): plain LDAP 389. Only AXAJP syncs groups, and none grants AD groups permissions.
- Secrets script: `~/.claude/scripts/sonarqube-admin-secret-init.sh` (Vault -> SM `{ldap,admin}`, idempotent, prints no values).

## Trap: out-of-band secrets must exist BEFORE the MR is handed back
2026-10-20: !532 was merged at once, even though the description said "create SM secrets before merge". Create and verify the secrets (`describe-secret` + length) before pushing. Your login right after merge = old revision (mirror lag); check `status.sync.revisions` before debugging auth.

## Follow-ups template (put in evidence pack)
JDBC `verify-full`; CMK for secrets; eis-rds ephemeral master input; ServiceMonitor/alerts (metrics user if endpoint auth-gated); non-HTTP port exposure (NLB/Istio TCP); backup/restore drill (RDS snapshot + S3 consistency); edition usage measurement on the EC2 instances; components/ promotion (MR2) only after a go decision.
