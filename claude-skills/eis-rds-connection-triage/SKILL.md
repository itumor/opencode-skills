---
name: eis-rds-connection-triage
description: >-
  Triage a client-reported RDS connection drop ("PSQLException: FATAL: terminating connection
  due to administrator command", app got disconnected, "was the DB rebooted/failed over") on an
  EIS OneSuite RDS instance. Use whenever asked to check RDS Events/CloudTrail for a reboot,
  failover, maintenance action, or parameter group change, or when a recurring RDS storage/CPU
  alert notification needs explaining. Covers the full triage ladder (RDS Events → CloudTrail →
  Postgres error logs → app pod logs) and the MaxAllocatedStorage=AllocatedStorage false-alert
  pattern. Reference case: GENESIS-442705 / COEXT-109898, aws06nnljdevrds01 (NN Life Japan, nnlj).
---

# EIS RDS connection-drop triage

## Step 0 — profile + region
OneSuite client accounts aren't all us-west-2. Check [[aws_profiles]] first (e.g. `NNJapanLower` →
217508029688 → ap-northeast-1 for nnlj). `aws sso login --profile <p>` if the session expired
(`SSO session ... expired` on `sts get-caller-identity` — this is a stale session, not a missing
permission).

## Step 1 — rule out AWS control-plane actions (fast, usually clean)
```bash
aws rds describe-db-instances --db-instance-identifier <rds> \
  --query 'DBInstances[0].[DBInstanceStatus,MultiAZ,PendingModifiedValues]'
aws rds describe-events --source-identifier <rds> --source-type db-instance --duration 4320
aws cloudtrail lookup-events --start-time <T-3d> --end-time <now> \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=<rds>
```
Zero hits on both = no reboot/failover/maintenance/param-change from AWS's side. This is usually
where people stop — **don't**. It only proves the control plane didn't act; it says nothing about
what actually terminated the session.

## Step 2 — the recurring storage/CPU "near max" alert is probably a config bug, not capacity
`FATAL: terminating connection...` reports often arrive bundled with "storage near max" RDS Event
notifications. Don't conflate them — check separately:
```bash
aws rds describe-db-instances --db-instance-identifier <rds> \
  --query 'DBInstances[0].[AllocatedStorage,MaxAllocatedStorage,StorageType]'
aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value=<rds> \
  --start-time <T-12h> --end-time <now> --period 3600 --statistics Average
```
If `AllocatedStorage == MaxAllocatedStorage`, storage autoscaling has **zero headroom** — RDS's
native autoscaling monitor fires the "approaching maximum storage threshold" notification on a
schedule purely because allocated equals the ceiling, **regardless of actual usage** (verified
case: 1024/1024 GiB allocated, only ~29 GiB actually used, alert fired every ~2h anyway). This is
not a disk-full problem; it's a provisioning mistake (someone set Max = current instead of higher).
Fix: bump `MaxAllocatedStorage` above `AllocatedStorage`. Used storage isn't a direct API field —
derive it: `used = AllocatedStorage - (FreeStorageSpace bytes / 1024^3)`.

## Step 3 — if Step 1 is clean, go to the Postgres error log itself
`FATAL: terminating connection due to administrator command` (SQLSTATE 57P01) is sent by the
Postgres backend itself — a JDBC driver cannot fabricate this exact string from a generic network
reset. If Postgres sent it, it's in the log (default `log_min_messages` always captures FATAL).
```bash
aws rds describe-db-log-files --db-instance-identifier <rds> \
  --query 'sort_by(DescribeDBLogFiles, &LastWritten)[].[LogFileName,LastWritten]'
aws rds download-db-log-file-portion --db-instance-identifier <rds> \
  --log-file-name error/postgresql.log.<YYYY-MM-DD-HH> --output json
# check AdditionalDataPending / Marker in the JSON — if truthy, you only got a partial file, page further
```
Retention is `rds.log_retention_period` (minutes; default 4320 = 3 days) — check the parameter
group before assuming a window is covered.

## Step 4 — get the exact timestamp from the app side, not just "yesterday"/"today"
RDS-side telemetry (Events, CloudTrail, Postgres logs) is worthless without a precise timestamp to
correlate. If the reporter only says "yesterday", go find the app's own log line instead of waiting
for them to dig it out:
```bash
aws eks update-kubeconfig --name <cluster> --alias <alias>   # e.g. aws06nnljdeveks01
kubectl --context <alias> -n <app-namespace> get pods
for POD in $(kubectl --context <alias> -n <ns> get pods -o name | sed 's|pod/||'); do
  HITS=$(kubectl --context <alias> -n <ns> logs "$POD" --since=72h --tail=20000 </dev/null 2>/dev/null \
    | grep -ic "administrator command")
  [ "$HITS" != "0" ] && echo "$POD: $HITS"
done
```
**GOTCHA:** don't nest `kubectl logs | grep` inside a `while read POD; do ...; done < file` in the
same shell — it's prone to consuming the outer loop's stdin and silently dying after one iteration
with no error. Use `for POD in $(cat file)` instead, and always redirect the inner kubectl's own
stdin from `/dev/null`.
Once found, extract exact timestamps from the JSON log line (app logs are usually structured JSON
— parse with `python3 -c "import json; ..."`, don't trust raw grep context lines for the time).

## Step 5 — the unresolved case: app got the FATAL, Postgres log shows nothing
Verified once (nnlj, 2026-09-14, `billing-app-0`, three occurrences in 50 seconds): app-side stack
trace shows the exact PSQLException, but the Postgres error log for that exact hour — confirmed
complete via `AdditionalDataPending: None` — has zero FATAL/termination lines, only routine
checkpoints. Ruled out before concluding "unexplained": no RDS Proxy in the account
(`aws rds describe-db-proxies`), no read replicas, and any suspicious app env var like
`genesis_postgres_url` pointing at a k8s service — check `kubectl get svc <name>` actually resolves
before trusting it over the real `DB_HOST`/`JDBC_URL` env vars.
**Not yet root-caused** — see [[nnlj_rds_admin_kill_investigation]] for the open thread and what to
check next (live `SHOW log_min_messages`, `pg_stat_activity` via an ephemeral psql pod per
[[eis_rds_postgres_extension]] Step 5, or ask the observability/DBA team directly whether anything
runs `pg_terminate_backend` against the instance).

## What to hand back
Report Steps 1–4 findings as facts with the exact commands/timestamps, not a guess dressed as a
conclusion. If Step 5's mystery isn't resolved, say so explicitly — "AWS control plane and RDS
logs show nothing; app clearly got the message; root cause still open" is a more useful answer than
a confident-sounding wrong one.
