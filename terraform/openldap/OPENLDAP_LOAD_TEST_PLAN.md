# OpenLDAP Load + Replication Quality Plan

## Objective
Validate that OpenLDAP MirrorMode in this project can:
- sustain target write and read load,
- keep reads continuously available,
- avoid missing or duplicated data,
- keep replication delay within acceptable bounds,
- preserve correctness during writer switch/failover.

## Scope
This plan covers LDAP on port 389 through both Global Accelerator and per-VPC NLB endpoints.

### Endpoints Under Test
- `ga_write_dns = a6ba558900a42b3c3.awsglobalaccelerator.com`
- `ga_read_dns = aa99eb27c555144df.awsglobalaccelerator.com`
- `write_lb_dns.live = openldap-mm-live-w-85bb4d1c5f42e3a2.elb.us-east-1.amazonaws.com`
- `write_lb_dns.dr = openldap-mm-dr-w-5e9af129d85de929.elb.us-east-1.amazonaws.com`
- `read_lb_dns.live = openldap-mm-live-r-0d5b45e4360d3f90.elb.us-east-1.amazonaws.com`
- `read_lb_dns.dr = openldap-mm-dr-r-94aae6c2d6961ea0.elb.us-east-1.amazonaws.com`

## Key Rules
- Write traffic must target one active master path at a time.
- Read traffic must run continuously against all read paths.
- Every successful write must become visible on all read paths.
- Test data must be uniquely traceable and fully reconcilable.

## Test Data Model
Use deterministic IDs so missing/duplicate records are easy to detect.
- DN pattern: `uid=lt-<runid>-<seq>,ou=people,dc=cae,dc=local`
- Required attributes: `uid`, `cn`, `sn`, `description`, `employeeNumber`
- `uid`: unique key (`lt-<runid>-<seq>`)
- `cn`, `sn`: synthetic values
- `description`: includes writer endpoint and timestamp
- `employeeNumber`: numeric sequence (`seq`)
- Optional custom attribute for timing: `caeWriteTsMs` (epoch ms at write)

## Metrics
Collect these metrics per test stage and per endpoint.
- Write throughput: successful adds/sec, modifies/sec, deletes/sec
- Read throughput: searches/sec
- Write success rate and LDAP error code distribution
- Read success rate and read latency (p50/p95/p99/max)
- Replication lag: commit-to-visible lag (ms) from write acknowledgment to first read visibility on each endpoint
- Replication lag: full-convergence lag (ms) until visible on all read endpoints
- Data integrity: expected count vs actual count
- Data integrity: missing IDs
- Data integrity: duplicate IDs
- Data integrity: stale reads count (record missing on one read endpoint but present on another)

## Phased Execution Plan

### Phase 0: Environment and Baseline Validation
Crate new folder for the test

### Phase 1: Low-Rate Functional Load (Correctness First)
Goal: validate end-to-end correctness with light concurrency.

Steps:
1. Start continuous read workers against `ga_read_dns`, `read_lb_dns.live`, and `read_lb_dns.dr`.
2. Select active writer path `write_lb_dns.live`.
3. Run low write rate (for example 5-20 writes/sec) for 10-15 minutes.
4. Record replication lag per write to each read endpoint.
5. Reconcile data set for missing/duplicate IDs.
6. Repeat with active writer path switched to `write_lb_dns.dr`.

Exit criteria:
- zero missing IDs,
- zero duplicates,
- stable read success during entire run,
- lag distribution captured and consistent.

### Phase 2: Throughput Ramp Test
Goal: find safe operating envelope.

Steps:
1. Keep read workers continuously active on all read endpoints.
2. Run write ramps with one writer path at a time: Step A 25 writes/sec, Step B 50 writes/sec, Step C 100 writes/sec, Step D increase until error rate or lag SLO is violated.
3. Hold each step for 10 minutes, then 5-minute cooldown.
4. Repeat full ramp for both writer paths: `write_lb_dns.live` and `write_lb_dns.dr`.

Exit criteria:
- max sustainable write rate identified,
- no unreconciled data loss,
- read service remains continuously available.

### Phase 3: Soak Test (Stability)
Goal: validate long-duration behavior.

Steps:
1. Run at 60-70% of max sustainable write rate found in Phase 2.
2. Keep continuous read load active on all read endpoints.
3. Duration: 4-12 hours.
4. Perform periodic reconciliation every 15 minutes.

Exit criteria:
- no data divergence across endpoints,
- error rates remain stable,
- lag does not show upward drift.

### Phase 4: Writer Switch and Failure Behavior
Goal: prove single-writer discipline with uninterrupted reads.

Scenario A: Planned writer switch
1. Run steady load with active writer `write_lb_dns.live`.
2. Stop writes for 30-60 seconds.
3. Verify convergence complete.
4. Resume writes on `write_lb_dns.dr`.
5. Verify no missing sequence IDs across switch boundary.

Scenario B: Unplanned writer interruption
1. Run steady load against active writer.
2. Simulate writer path failure (target/node or endpoint unavailable).
3. Measure write interruption window.
4. Redirect writes to alternate writer path.
5. Validate post-recovery reconciliation and lag recovery.

Exit criteria:
- read paths remain healthy,
- no lost committed records,
- switch window and recovery metrics captured.

### Phase 5: GA vs Direct NLB Comparison
Goal: quantify impact of GA routing.

Steps:
1. Repeat representative load profile via GA endpoints.
2. Repeat same profile via direct NLB endpoints.
3. Compare latency, error rates, and lag distributions.

Exit criteria:
- clear recommendation for client traffic routing policy.

## Suggested Acceptance Criteria
Use these as initial targets, then tune with business SLOs.
- Data loss: 0 missing committed writes
- Duplicates: 0 duplicate IDs
- Read availability: >= 99.9% during test window
- Write success rate: >= 99.5% (excluding injected failure windows)
- Replication lag p95: <= 2s
- Replication lag p99: <= 5s
- Full convergence max (non-failure phases): <= 15s

## Observability and Evidence
Capture artifacts for every run.
- Raw write/read logs with run ID and endpoint labels
- Per-write replication-lag samples
- Final reconciliation report (expected, found, missing, duplicates)
- Endpoint health snapshots before/after each phase
- Summary markdown report in `reports/` with charts/tables

## Implementation Work Plan (Next Step)
Create scripts under `terraform/openldap/tools/load/`:
- `run_load.sh` (orchestrator)
- `writer.sh` (single active writer generator)
- `reader.sh` (continuous read workers)
- `lag_probe.sh` (commit-to-visible + convergence timing)
- `reconcile.sh` (missing/duplicate detection)
- `switch_writer.sh` (planned writer cutover helper)

Run order:
1. Phase 0 
2. Phase 1
3. Phase 2
4. Phase 3
5. Phase 4
6. Phase 5
7. Final report generation

## Risks and Controls
- Risk: split-brain style dual writes.
- Control: hard gate so only one writer endpoint is active in each test run.

- Risk: false data-loss signal from delayed replication.
- Control: use bounded settle window before final reconciliation.

- Risk: endpoint DNS changes after Terraform apply.
- Control: always read DNS values from latest Terraform outputs before each run.
