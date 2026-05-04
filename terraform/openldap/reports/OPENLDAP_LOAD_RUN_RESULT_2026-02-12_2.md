# OpenLDAP Load Run Result (2026-02-12, Run 2)

## Command executed
```bash
PHASE1_DURATION_SEC=3 PHASE1_RATE=1 \
PHASE2_RATES=1,2 PHASE2_DURATION_SEC=3 PHASE2_COOLDOWN_SEC=1 \
PHASE3_DURATION_SEC=3 \
PHASE4_STEADY_SEC=3 PHASE4_SWITCH_PAUSE_SEC=1 \
PHASE5_DURATION_SEC=3 PHASE5_RATE=1 \
READ_INTERVAL_MS=1000 PROBE_LAG=1 \
terraform/openldap/tools/load/run_load.sh --phase all
```

## Run metadata
- run_id: `20260212T105929Z`
- run_dir: `terraform/openldap/tools/load/runs/20260212T105929Z`
- completed_utc: `2026-02-12T11:03:23Z`
- endpoints source: `terraform/openldap/out.text` (verified)

## Outcome summary
- Phases completed: `0,1,2,3,4,5`
- Orchestrator/script status: `success` (no script crash)
- Write success: `100%` for every phase segment
- Replication lag (observed in this short run): about `1.2s - 1.26s` p95
- Reconciliation: `stale_reads_count=0`, duplicates files empty

## Phase highlights
- phase1_live: write_total `3`, write_ok `3`, lag_p95_ms `1225`
- phase1_dr: write_total `3`, write_ok `3`, lag_p95_ms `1254`
- phase2_live_r1: write_total `3`, write_ok `3`
- phase2_live_r2: write_total `6`, write_ok `6`
- phase2_dr_r1: write_total `3`, write_ok `3`
- phase2_dr_r2: write_total `6`, write_ok `6`
- phase2 max sustainable rate selected by script: `2 wps`
- phase3_soak: write_total `3`, write_ok `3`, lag_p95_ms `1218`
- phase4_switch_pre/post/recovery: each write_total `3`, write_ok `3`
- phase5_ga: write_total `3`, write_ok `3`, lag_p95_ms `1208`
- phase5_direct: write_total `3`, write_ok `3`, lag_p95_ms `1231`

## Notes
- Expected warning: `PHASE4_FAILURE_CMD not set; unplanned failure simulation skipped`.
- No additional script edits were required during this run.

## Artifacts
- Summary: `terraform/openldap/tools/load/runs/20260212T105929Z/reports/SUMMARY.md`
- Writes: `terraform/openldap/tools/load/runs/20260212T105929Z/reports/write_samples.csv`
- Reads: `terraform/openldap/tools/load/runs/20260212T105929Z/reports/read_samples.csv`
- Lag samples: `terraform/openldap/tools/load/runs/20260212T105929Z/reports/lag_samples.csv`
- Reconcile summary: `terraform/openldap/tools/load/runs/20260212T105929Z/reports/reconcile_summary.csv`
