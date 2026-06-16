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
