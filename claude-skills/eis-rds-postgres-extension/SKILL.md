---
name: eis-rds-postgres-extension
description: >-
  Enable a PostgreSQL extension that requires shared_preload_libraries (pgaudit, pg_cron,
  pg_stat_statements, pg_partman bgw, etc.) on an EIS RDS instance managed by the eis-rds
  Terraform module. Use whenever someone asks to "enable pgaudit", "turn on DB audit logging",
  "enable an RDS extension", set shared_preload_libraries / pgaudit.log, or hits the Postgres
  error "<ext> must be loaded via shared_preload_libraries". ALSO use when an HDS / SOC2 / audit
  certification ticket asks for database audit logs on RDS, or when a customer asks for the change
  "with no downtime" (this skill explains why a reboot is unavoidable and how to minimize it).
  ALSO use for the companion DB-log asks that usually follow an audit-logging request: changing
  PostgreSQL on-instance log retention (rds.log_retention_period), publishing RDS logs to CloudWatch
  (enabled_cloudwatch_logs_exports), or setting a CloudWatch log-group retention — these are
  zero-downtime and don't need a reboot.
  Covers the eis-rds custom-parameter-group flip, the Atlantis apply, the maintenance-window-gated
  reboot, running CREATE EXTENSION against a private RDS from an EKS pod, and end-to-end verification.
---

# Enabling a shared_preload_libraries Postgres extension on EIS RDS

Reference implementation: **COEXT-105501** — pgaudit on `aws0caatestrds01` (CAA UAT), 2026-06-15.

## The one thing to tell the customer first

**There is no zero-downtime path.** `shared_preload_libraries` is a **static** Postgres parameter — the extension only loads after a **DB reboot**. If the instance is **single-AZ** the reboot is a real outage (~1 min observed). Multi-AZ reboot-with-failover and Blue/Green still cause a brief blip, and are overkill for a lower env. Two things *are* zero-downtime: the `terraform apply` (the param goes `pending-reboot`, nothing restarts) and any *dynamic* params (e.g. `pgaudit.log`). So the honest framing is: "apply is invisible; there's a ~1–3 min outage only at the activating reboot, which we'll do in a maintenance window."

Dynamic vs static — check with `ApplyType` before promising anything:
```bash
aws rds describe-db-parameters --db-parameter-group-name <pg> \
  --query "Parameters[?ParameterName=='shared_preload_libraries'].[ParameterValue,ApplyType,ApplyMethod]" --output text
```

## Step 0 — Recon the instance

```bash
export AWS_PROFILE=<account> AWS_REGION=us-west-2
aws rds describe-db-instances --db-instance-identifier <rds> \
  --query 'DBInstances[0].{MultiAZ:MultiAZ,Engine:Engine,EngineVersion:EngineVersion,Status:DBInstanceStatus,PG:DBParameterGroups[0]}' --output json
```
Note MultiAZ (sets outage expectation) and the current parameter group. If it's `default.postgresNN`, the instance is on the **AWS default group** — you must create a custom one (static params can't be set on a default group anyway). **Read the current `shared_preload_libraries` value and APPEND to it** — RDS ships `pg_stat_statements,pg_tle` (and adds `rdsutils,rds_casts` itself); clobbering them breaks other features.

## Step 1 — Terraform change (eis-rds custom parameter group)

**First check the wiring exists at all** — `create_db_parameter_group`/`parameters` are eis-rds module inputs, but not every consumer project's wrapper passes them through. `grep -n "create_db_parameter_group" lower/<stage>/services/{rds.tf,variables.tf}` before touching tfvars. Credit-agricole has it (added directly to its rendered files for pgaudit/Fivetran, never promoted to the upstream Copier template — confirmed by `grep -rn create_db_parameter_group terraform/template/client` returning nothing), but sibling projects pinned at the **same module ref** (e.g. nnl-japan at `v2.1.0`, same as CAA) can still lack it (verified COEXT-108341). **axa-japan lacks it too** (verified 2026-08-18, module ref `v2.0.1` — different ref than nnlj/CAA, so this is not version-gated, it's just missing from every consumer except CAA). Assume it's missing until grep proves otherwise. If missing, add it first, with a CUSTOM marker since you're editing a template-owned file:
```hcl
# variables.tf, inside the rds object type
# CUSTOM [RDS-CustomParamGroup] | <JIRA> | wire eis-rds custom parameter group passthrough
create_db_parameter_group = optional(bool, false)
parameters                = optional(list(map(string)), [])
```
```hcl
# rds.tf, inside module "rds"
# CUSTOM [RDS-CustomParamGroup] | <JIRA> | wire eis-rds custom parameter group passthrough
create_db_parameter_group = each.value.create_db_parameter_group
parameters                = each.value.parameters
```

The eis-rds module exposes `create_db_parameter_group` + `parameters` (a `list(map(string))`). In an EIS client project (e.g. credit-agricole), the instance lives in `lower/<stage>/services/terraform.tfvars` under the `rds` map. Mirror any existing custom-param sibling (e.g. dev's Fivetran CDC block). Example for pgaudit:

```hcl
rds = {
  "01" = {
    # ...existing keys...

    # --- pgaudit: DB audit logging for <ticket> ---
    create_db_parameter_group = true
    parameters = [
      {
        name         = "shared_preload_libraries"
        value        = "pg_stat_statements,pg_tle,pgaudit"  # APPEND, don't clobber
        apply_method = "pending-reboot"                      # static -> must be pending-reboot
      },
      {
        name  = "pgaudit.log"
        value = "role, ddl"                                  # dynamic; whatever the ticket asks
      }
    ]
  }
}
```
Run `terraform fmt -check`. `terraform validate` will complain "Module not installed" locally (no `terraform init` without GITLAB_TOKEN) — that's fine, Atlantis inits in CI.

## Step 2 — MR, and the rebase-not-merge trap

Branch off fresh `origin/main`, conventional commit (`feat(rds): <TICKET> - ...`), push, open MR, get review (Markuss/Markuss-class approver for module/infra; assign + Slack ping).

**If main moves while the MR is open (someone else's MR merges that touches the same `lower/<stage>/services/` dir): `git rebase origin/main`, NEVER `git merge`.** The EIS terraform CI lints *every* commit with `conventional-pre-commit` + `jira-conventional-lint`; a raw `Merge remote-tracking branch...` message fails the pipeline and the MR won't merge ("requires a passing pipeline"). Rebase = linear history, only your conventional commit gets linted. Approvals survive a force-push here (verified). After rebasing, **always re-plan** — a stale branch plan will try to *destroy* resources the other MR just created (see Step 3). See [[coext105281_module_ci_merge_commit_fix]] and [[tf_sequential_mr_plan_dep]].

## Step 3 — Atlantis apply (zero-downtime) + merge

`glab mr note create <MR> --message "atlantis plan"`, poll the `pnt_terraform_build` note. **Inspect the plan**: expect `db_parameter_group` created + `db_instance` updated-in-place (param-group association → pending-reboot). `0 to destroy` is the safety check — if it wants to destroy anything (e.g. another MR's `*-udep01` access entries), your branch is stale → rebase (Step 2). Unrelated drift in the same project dir (e.g. an S3 SSE config) rides along on apply; flag it but it's usually benign.

Then `atlantis apply`, confirm `Apply complete! Resources: N added, M changed, 0 destroyed`, then `glab mr merge <MR> --yes --remove-source-branch`. Merging matters: if main lacks the change, the next plan from main reverts your param group.

## Step 4 — Maintenance-window-gated reboot (the outage)

Post a heads-up + sign-off request in the customer ops channel (**#caa-saas** for CAA; Roman Terletskyy / Maksym Koshyk gate, Sigitas approves) [[feedback_patching_validate_pto_first]]. Wait for approval / objection window before rebooting. Then:

```bash
aws rds reboot-db-instance --db-instance-identifier <rds>          # no --force-failover on single-AZ
# poll until back up AND the static param actually took:
aws rds describe-db-instances --db-instance-identifier <rds> \
  --query 'DBInstances[0].[DBInstanceStatus,DBParameterGroups[0].ParameterApplyStatus]' --output text
# wait for: available  in-sync
```
`ParameterApplyStatus: in-sync` (was `pending-reboot`) is the proof the reboot loaded the static param.

## Step 5 — CREATE EXTENSION against a PRIVATE RDS (the useful trick)

EIS RDS instances are in private subnets, but the eis-rds SG **already allows the EKS pod subnets**. So skip SSM tunnels — run an ephemeral psql pod in the cluster (you have cluster-admin via AdministratorAccess SSO → `oc-team` access entry):

```bash
aws eks update-kubeconfig --name <cluster> --alias c1
PW=$(aws secretsmanager get-secret-value --secret-id <rds>/credentials \
     --query SecretString --output text | python3 -c "import sys,json;print(json.loads(sys.stdin.read())['password'])")
kubectl --context c1 run pgext-setup --rm -i --restart=Never --image=postgres:17-alpine \
  --env="PGPASSWORD=$PW" --command --timeout=120s -- \
  psql "host=<endpoint> port=5432 user=postgres dbname=<db> sslmode=require" -v ON_ERROR_STOP=1 -A -t \
  -c "CREATE EXTENSION IF NOT EXISTS pgaudit;" \
  -c "SELECT 'EXT='||extname||' v'||extversion FROM pg_extension WHERE extname='pgaudit';" \
  -c "SELECT 'SPL='||setting FROM pg_settings WHERE name='shared_preload_libraries';" \
  -c "SELECT 'PGAUDITLOG='||setting FROM pg_settings WHERE name='pgaudit.log';"
```

Secret `<rds>/credentials` keys: `host,password,port,username` (master user = `postgres`, which has `rds_superuser`).

**GOTCHA:** `kubectl run -i` sometimes doesn't stream psql stdout back (you only see "pod deleted"). Re-run capturing to a file with `-A -t`; a `NOTICE: extension "pgaudit" already exists, skipping` on the second run confirms the first run actually worked.

## Step 6 — Verify E2E + report

Assert against the DB's own catalogs (`pg_extension`, `pg_settings`) — not just `SHOW` — for:
1. extension present (`pg_extension`),
2. extension name in `shared_preload_libraries` (proves reboot worked),
3. config param set (e.g. `pgaudit.log = role,ddl`).

**Honesty note for the report:** this verifies the extension is *loaded and configured*. It does NOT verify an audit event renders end-to-end (a DDL by an audited role producing a log line in CloudWatch/PG logs). If the ticket needs that proof, run a test DDL as an audited role and grep the logs — say so explicitly rather than implying it was tested.

Then comment the result on the Jira ticket (@-mention the requester, e.g. `[~akerpauskas]`) with the three verification lines. See [[eis-jira-rest-ops]] for the REST mechanics, [[coext105501_caa_uat_pgaudit]] for the worked example.

---

## Companion: log retention + publish logs to CloudWatch (ALL zero-downtime, no reboot)

These three asks almost always follow an audit-logging request ("keep logs longer", "ship them to CloudWatch"). None need a reboot — skip Step 4 entirely for these.

**1. On-instance log retention (`rds.log_retention_period`)** — a *dynamic* parameter, **measured in minutes**: default `4320` (3 days), max `10080` (7 days). Append to the same `parameters` list:
```hcl
{ name = "rds.log_retention_period", value = "10080" }   # 7 days; no apply_method = immediate
```

**2. Publish logs to CloudWatch (`enabled_cloudwatch_logs_exports`)** — eis-rds already wires `rds_enabled_cloudwatch_logs_exports` to the wrapped module ([eis-rds/main.tf:150](terraform/modules/aws/eis-rds/main.tf)) but EIS consumer projects do **not** pass it, and the `rds` object variable can't be extended from a `_custom.tf` (object types are monolithic). Add it inline on the `module "rds"` block with a marker:
```hcl
# CUSTOM CloudWatchLogs | <JIRA> | publish postgres logs to CloudWatch
rds_enabled_cloudwatch_logs_exports = ["postgresql"]   # postgres log type; "upgrade" only for major upgrades
```
Enabling export is an in-place `ModifyDBInstance` — no reboot.

**3. CloudWatch log-group retention** — the module does NOT manage the log group; RDS auto-creates `/aws/rds/instance/<db>/postgresql` with **indefinite** retention. Declare it in a `*_custom.tf` to enforce retention:
```hcl
resource "aws_cloudwatch_log_group" "rds_postgresql" {
  #checkov:skip=CKV_AWS_158:<reason — CloudWatch default at-rest encryption sufficient, CMK not in scope>
  name              = "/aws/rds/instance/${local.project_prefix}rds01/postgresql"
  retention_in_days = 365
  tags              = { Issue = "<JIRA>" }
}
```
**checkov GOTCHA (will block CI):** the credit-agricole `.checkov.yaml` skip-list contains `CKV_AWS_338` (retention ≥1yr — satisfied by 365) but NOT `CKV_AWS_158` (log-group KMS encryption). A new `aws_cloudwatch_log_group` without a CMK fails the blocking `terraform_checkov` pre-commit hook → add the inline `#checkov:skip=CKV_AWS_158` with a reason.
**Ordering:** if export isn't enabled yet the group doesn't exist, so TF creates it cleanly. If a prior auto-created group exists → `terraform import aws_cloudwatch_log_group.rds_postgresql /aws/rds/instance/<db>/postgresql` then re-apply.

**Verify (zero-downtime, no reboot):** `rds.log_retention_period`→`10080`; `EnabledCloudwatchLogsExports`→`["postgresql"]`; log-group `retentionInDays`→`365`; and `aws logs describe-log-streams --log-group-name /aws/rds/instance/<db>/postgresql` shows streams (proves logs are *actually publishing*, the real E2E signal).

## Gotcha: pgaudit.log perpetual no-op plan diff (RDS value normalization)
RDS stores comma-list param values **normalized without spaces** — `pgaudit.log = "role, ddl"` is stored as `"role,ddl"`. Terraform then shows `aws_db_parameter_group ... will be updated in-place` on EVERY plan of that stage (config "role, ddl" → state "role,ddl"), forever — a benign no-op that pollutes every MR's plan there. **Import does NOT fix it** (param group already in state; it's a value-format mismatch, not a missing resource). Fix = align config to the stored form: `value = "role,ddl"` (no space). Dynamic param, in-place, no reboot (verified COEXT-105501 — after the fix the param shows zero diff). General rule: a param-group value that keeps re-planning usually means RDS normalized the stored value (spaces/case/order) — match config to it.

## Gotcha: pg_cron silently no-ops unless `cron.database_name` matches the app's real DB
`cron.database_name` (pg_cron's GUC for which DB its background worker lives in) defaults to **`postgres`** at the engine level. RDS instances commonly have `DBName` set to something else entirely (e.g. `aws06nnljdevrds01`, matching the instance name, not a `postgres` db) — check with `aws rds describe-db-instances --query 'DBInstances[0].DBName'`. If `cron.database_name` is left at default and the app schedules jobs from its own (non-`postgres`) database, `cron.schedule()` calls register in the wrong DB's pg_cron tables and the launcher bgworker (which only runs in `cron.database_name`) never picks them up — extension shows "loaded" but jobs silently never fire. Fix: add it as a second static param in the same `parameters` list (same reboot, no extra cost):
```hcl
{ name = "cron.database_name", value = "<actual DBName>", apply_method = "pending-reboot" }
```
Verify with `SHOW cron.database_name;` post-reboot, and confirm a real scheduled job executes (`SELECT * FROM cron.job_run_details` after a minute) — not just that the extension is present. Verified COEXT-108341 (nnl-japan, `aws06nnljdevrds01`).

**Second confirmed instance (axa-japan, 2026-08-18, no ticket filed yet):** same gap, surfaced via a live env-recreate failure instead of a proactive audit. axajp's app-side `database_manager` tool drops+recreates the app DB on every env recreate, then tries `CREATE EXTENSION pg_cron` inside it — traceback:
```
psycopg2.errors.RaiseException: can only create extension in database postgres
DETAIL:  Jobs must be scheduled from the database configured in cron.database_name, ...
HINT:  Add cron.database_name = 'axajp_qaa_v20' in postgresql.conf to use the current database.
```
`axajp_qaa_v20` is a **versioned QA db name** (`_v20` suffix) — if `database_manager` bumps that suffix on future recreates, a hardcoded `cron.database_name = axajp_qaa_v20` in tfvars fixes this run and breaks again next one. Confirm with the app/delivery team whether the name is stable or incremented per recreate *before* wiring a static fix — if it's incremented, the durable fix belongs in `database_manager`'s own connection logic (always target the `cron.database_name`-configured DB for the extension-creation step), not in Terraform. Tracked in memory [[axajp-nnlj-rds-param-passthrough-gap]].

## pg_cron specifics (no prior art in the iac tree as of 2026-08-18)
Grepped the whole monorepo for `pg_cron` / `shared_preload_libraries` in `*.tf`/`*.tfvars` — zero pg_cron hits anywhere. The only worked `shared_preload_libraries` example in the tree is the pgaudit one above (CAA UAT). Same mechanism applies (static param, append-don't-clobber, pending-reboot), but pg_cron has its own extra param:
```hcl
{ name = "shared_preload_libraries", value = "pg_stat_statements,pg_tle,pg_cron", apply_method = "pending-reboot" },
{ name = "cron.database_name", value = "<db>" }   # dynamic; pg_cron's bgworker only schedules jobs against THIS db
```
`cron.database_name` defaults to `postgres` — if the target app DB isn't `postgres`, set it explicitly or `cron.schedule()` calls made while connected to the app DB silently land in the wrong catalog. `CREATE EXTENSION pg_cron;` itself must be run while connected to whichever DB `cron.database_name` points at (same Step 5 ephemeral-pod trick, just point `dbname=` at that DB). Otherwise identical to pgaudit: reboot-gated, verify via `pg_extension` + `shared_preload_libraries` setting, plus `SELECT * FROM cron.job;` to confirm the bgworker is actually scheduling.

## Atlantis delivery order (do NOT deviate) [[feedback_atlantis_apply_before_merge]]
`atlantis plan` (verify 0 destroy) → review/approval → **`atlantis apply` → confirm `Apply complete!` green → run the live verification above → THEN `glab mr merge` LAST**. Never merge before a verified-green apply — the open MR is your revert path if apply or verification fails. (SSO often expires mid-task; `aws sso login --profile <p>` is interactive/browser — if blocked, the apply output proves resources changed, but hold the merge until you can run the live value checks.)
