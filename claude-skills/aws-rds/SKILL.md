---
name: aws-rds
description: Generic AWS RDS operations — parameter groups vs option groups, shared_preload_libraries requiring a reboot, Multi-AZ failover behavior, snapshot/restore and point-in-time recovery, read replicas and their lag/promotion caveats, storage autoscaling, and the apply_method (immediate vs pending-reboot) convergence trap on parameter changes. Use whenever the user mentions RDS, a database parameter/option group, "enable an RDS extension" (pgaudit, pg_cron, pg_stat_statements, etc.), Multi-AZ, read replica lag, RDS maintenance windows, or a Terraform aws_db_instance/aws_db_parameter_group plan that "never converges." Not tied to any one company's account; for EIS/OneSuite's RDS Postgres extension rollout (pgaudit etc.), prefer this repo's own eis-rds-postgres-extension skill first.
---

# AWS RDS

RDS is a managed relational database service (Postgres, MySQL, MariaDB, SQL Server, Oracle) where AWS owns the underlying OS/patching, and most engine-level tuning happens through parameter groups rather than direct config file edits.

## Parameter groups vs option groups

- **Parameter group**: engine runtime settings (`max_connections`, `shared_buffers`, `pgaudit.log`, `log_statement`, etc.) — analogous to `postgresql.conf`/`my.cnf`.
- **Option group**: engine *features* that need extra infrastructure wiring (e.g. Oracle native network encryption, SQL Server TDE) — fewer of these matter on Postgres/MySQL than on commercial engines.

A custom instance always needs its own custom parameter group — the default one (`default.postgres15`, etc.) is not modifiable in place.

## The reboot trap: shared_preload_libraries

Any parameter under `shared_preload_libraries` (pgaudit, pg_cron, pg_stat_statements, pg_partman's background worker, etc.) is a **static** parameter — it's read once at postmaster startup, so changing it requires an actual instance reboot before it takes effect, no matter how the change was applied. This differs from **dynamic** parameters that apply on next connection or immediately.

```bash
aws rds describe-engine-defaults --db-parameter-group-family postgres15 \
  --query "EngineDefaults.Parameters[?ParameterName=='shared_preload_libraries']"
```

Check `ApplyType` (`static` vs `dynamic`) per parameter before promising a zero-downtime change — static parameters cannot skip the reboot, and there's no way around it short of blue/green (create a new instance with the setting already baked in via snapshot restore, then cut over).

## The apply_method convergence trap (common with Terraform)

RDS parameter changes take an `apply_method` of `immediate` or `pending-reboot`. If you set a parameter value that happens to equal the engine's own default, and mark it `pending-reboot`, RDS may just apply it immediately anyway (nothing to defer) — so a subsequent `terraform plan` sees the live parameter's `ApplyStatus` as `in-sync` while Terraform's state still expects `pending-reboot`, and the plan never converges, showing a permanent diff. Fix: set `apply_method` to match what RDS actually reports for that parameter (check `describe-db-parameters`), not what seems logically correct in isolation.

## Multi-AZ vs read replicas — don't conflate them

| Feature | Purpose | Data path |
|---|---|---|
| **Multi-AZ** | High availability — a synchronous standby in another AZ, automatic failover on primary failure (typically 60-120s). Not readable. | Sync replication, standby is a failover target only. |
| **Read replica** | Horizontal read scaling, can be promoted to standalone but that's a manual, disruptive action (breaks replication permanently). | Async replication — can lag, check `ReplicaLag` CloudWatch metric before routing read traffic that needs freshness. |

Multi-AZ failover changes the instance's underlying IP but not its endpoint DNS name — application code should always use the RDS endpoint, never a resolved IP, or failover becomes invisible to nothing (it'll just be broken).

## Snapshot / restore / point-in-time recovery

- **Manual snapshot**: persists until explicitly deleted, survives instance deletion.
- **Automated backup + PITR**: continuous, restorable to any second within the retention window (`BackupRetentionPeriod`, up to 35 days) — but restoring creates a **new** instance with a new endpoint; RDS never restores in place.
- Cross-region/cross-account snapshot copy needs its own KMS key re-encryption step if the source is encrypted — a snapshot encrypted with a key that only exists in the source account/region cannot be shared or copied as-is.

## Storage autoscaling

`max_allocated_storage` lets RDS grow storage automatically under sustained pressure, but it will not scale down, and there's a cooldown between scaling events (roughly 6 hours) — a spiky workload can hit the ceiling of one scaling step before the next is allowed, so autoscaling is a safety net against slow growth, not protection against a sudden spike.

## Maintenance windows

Even with a defined maintenance window, RDS applies parameter-group changes marked `pending-reboot` only on an actual reboot — which does not happen automatically inside the maintenance window unless the change is also flagged for auto-apply, or the instance is manually rebooted. Minor engine version auto-upgrades do respect the maintenance window; a config-only pending-reboot change usually does not, unless explicitly triggered.
