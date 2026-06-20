# Bank OpenLDAP Performance Test Kit

## Overview

Performance and load-testing suite for EAB Bank OpenLDAP (Symas 2.6.13, RHEL 9, master/replica).

Runs **locally** — no SSH, no remote hosts needed. Run from master, replica, or jump host (172.23.10.32). Python 3.6+ required for load tester and LDIF generator.

## Environment

| Component | IP | Role |
|-----------|-----|------|
| Master | 172.23.11.236 | Writes, sync source |
| Replica | 172.23.11.237 | Reads, replication target |
| Jump | 172.23.10.32 | Admin access point |
| Admin | cn=admin,dc=eab,dc=bank,dc=local | Password: TheN1le1 |
| Base DN | dc=eab,dc=bank,dc=local | |

## Files

| Script | Purpose | Needs Root? |
|--------|---------|-------------|
| `bank-load-tester.py` | Python load generator (login, write, mixed, stress modes) | No |
| `bank-gen-ldif.py` | Generate LDIF with N users (SSHA passwords) | No |
| `bank-bulk-load.sh` | Generate + bulk-load users via slapadd | **Yes (sudo)** |
| `bank-perf-suite.sh` | Full test suite orchestrator (smoke → load → stress) | No |
| `bank-monitor-ldap.sh` | Real-time LDAP + OS monitoring (CSV output) | No |
| `bank-cleanup-users.sh` | Delete all perf-test users after testing | **Yes (sudo)** |
| `bank-tune-master.sh` | Production tuning for master (LMDB, indices, kernel, systemd) | **Yes (sudo)** |
| `bank-tune-replica.sh` | Production tuning for replica | **Yes (sudo)** |
| `test_bank_password_policy.sh` | Verify password policy rules (PPM, LDAP-level) | **Yes (sudo)** |

## Quick Start

### 1. Copy kit to target host

```bash
# From jump host, scp to master
scp -r bank-perf-kit/ root@172.23.11.236:/tmp/
ssh root@172.23.11.236
cd /tmp/bank-perf-kit
```

### 2. Verify prerequisites

```bash
# Check LDAP is running
/opt/symas/bin/ldapwhoami -x -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1"

# Check Python3
python3 --version

# Check available disk space (LDIF can be large)
df -h /var/symas/openldap-data/
```

### 3. Tune master (recommended before load test)

```bash
# Preview current settings
sudo bash bank-tune-master.sh --verify

# Apply production tuning (creates backup, applies, verifies)
sudo bash bank-tune-master.sh

# If something goes wrong:
sudo bash bank-tune-master.sh --rollback
```

### 4. Bulk load test users

```bash
# Load 100,000 users (recommended for prod testing):
sudo bash bank-bulk-load.sh 100000 'Test123!'

# For larger tests (500K or 1M):
sudo bash bank-bulk-load.sh 500000 'Test123!'
```

### 5. Run performance suite

```bash
# Full suite (smoke + login + write + mixed):
bash bank-perf-suite.sh

# Test against specific host:
bash bank-perf-suite.sh --master 172.23.11.236

# Quick smoke-only test (2 min):
bash bank-perf-suite.sh --quick

# With stress ramp (40 min) — set env var first:
RUN_FULL=1 bash bank-perf-suite.sh

# Skip smoke if already verified:
bash bank-perf-suite.sh --skip-smoke
```

### 6. Monitor during test (separate terminal)

```bash
# Start monitor on replica (5s interval, CSV output):
bash bank-monitor-ldap.sh 5 /tmp/perf-monitor.csv

# Monitor on master:
BANK_HOST=172.23.11.236 bash bank-monitor-ldap.sh 5 /tmp/perf-monitor-master.csv
```

### 7. Cleanup after test

```bash
# Preview what will be deleted:
sudo bash bank-cleanup-users.sh --dry-run

# Delete all perf-test users (requires confirmation):
sudo bash bank-cleanup-users.sh
```

## Test Modes

### `bank-load-tester.py` modes:

| Mode | Description | Target |
|------|-------------|--------|
| `login` | Bind as random user + search self | Replica (reads) |
| `write` | Add users via admin DN (churn users) | Master (writes) |
| `mixed` | 80% reads + 20% writes | Either |
| `stress` | Ramp from 50→2000 ops/sec in steps | Either |

### Examples:

```bash
# 100 ops/sec login load for 5 minutes on replica
python3 bank-load-tester.py --host 172.23.11.237 --port 636 \
  --mode login --target-ops 100 --duration 300 --concurrency 50

# 25 ops/sec writes on master for 2 minutes
python3 bank-load-tester.py --host 172.23.11.236 --port 636 \
  --mode write --target-ops 25 --duration 120 --concurrency 10

# JSON output for parsing
python3 bank-load-tester.py --host 172.23.11.237 --mode login \
  --target-ops 500 --duration 60 --json
```

## Safety Notes

1. **Tuning scripts backup before modifying** — each creates a timestamped backup in `/var/symas/openldap-data/backup/`. Rollback with `--rollback`.

2. **bulk-load.sh stops & restarts slapd** — plan a maintenance window. The `slapadd` step runs offline (service stopped). For 100K users: ~2-3 min offline. For 1M users: ~15-30 min.

3. **Cleanup deletes by uid pattern** — matches `uid=user*` and `uid=churn*` only. Real production users with different uid patterns are NOT affected. Still, run `--dry-run` first.

4. **The LDAP monitor reads cn=Monitor** — negligible overhead. Safe to run during production hours.

5. **Load tester runs locally** — CPU and memory usage come from the host running it. For high concurrency (>100 threads), consider running from jump host or a separate VM.

6. **Stress ramp (2000 ops/sec)** will saturate the server — only run during maintenance window.

7. **Replication sync** — bulk-loaded users replicate via syncrepl. Wait for sync to complete before testing replica. Monitor contextCSN:
   ```bash
   /opt/symas/bin/ldapsearch -x -H ldap://172.23.11.237 \
     -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
     -b "dc=eab,dc=bank,dc=local" -s base contextCSN -o ldif-wrap=no
   ```

## Tuning Applied (bank-tune-master.sh)

| Setting | Value |
|---------|-------|
| Threads | 32 |
| LMDB main size | 25GB |
| LMDB accesslog | 25GB |
| LMDB cache | 512MB |
| Flags | writemap, nometasync |
| Checkpoint | 1024KB / 30min |
| Log level | none |
| Indices | uid, mail, cn, entryUUID, entryCSN, member, objectClass |
| NOFILE | 1,048,576 |
| NPROC | 65,536 |
| file-max | 2,097,152 |

## Results Location

Test results are saved to `results/YYYYMMDD_HHMMSS/` relative to the script directory. Each test phase produces a JSON file with:
- `ops_per_sec`: Throughput
- `error_rate`: % of failed operations
- `latency_p50/p95/p99`: Latency percentiles in milliseconds

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `ldapsearch: command not found` | `export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH` |
| `ldapwhoami: Can't contact` | Service not running: `systemctl status symas-openldap-servers` |
| `Invalid credentials` | Check admin password, try with `-ZZ` for TLS |
| `slapadd: permission denied` | Must run as root (sudo) |
| `No such object (32)` during load test | Test users not loaded yet — run `bank-bulk-load.sh` first |
| Replica not syncing after bulk load | Restart replica slapd, check syncrepl config |

## Contact

For questions, contact the nextgenopen team.
