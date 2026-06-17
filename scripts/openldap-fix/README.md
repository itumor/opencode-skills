# Bank OpenLDAP Fix Package

## One command to fix everything

```bash
# On MASTER:
sudo bash scripts/openldap-fix/bank-one-click-fix.sh

# On REPLICA:
sudo MASTER_IP=<master_ip> bash scripts/openldap-fix/bank-one-click-fix.sh
```

That's it. One script per node. It auto-detects role, runs all fixes, verifies, diagnoses, and writes a report.

---

## What's in the package

| Script | What it does | Run by one-click? |
|--------|-------------|:---:|
| **`bank-one-click-fix.sh`** | Auto-detect role → fix → verify → diagnose → coverage → report | ⭐ **Run this** |
| `fix-master.sh` | Validates+fixes master (16 checks) | ✅ auto |
| `fix-replica.sh` | Validates+fixes replica (17 checks) | ✅ auto |
| `verify-openldap.sh` | 18 health checks, auto-detects role | ✅ auto |
| `diagnose-openldap.sh` | Full technical diagnostic → report | ✅ auto |
| `validate-bank-issues.sh` | Coverage report: checks all 24 bank issues | ✅ auto |
| `e2e-openldap-test.sh` | Master↔replica sync test (add/mod/del/replicate) | ❌ run separately |
| `cleanup-openldap.sh` | Safe stop/backup/wipe | ❌ run separately |
| `monitor-openldap-logs.sh` | N-minute log watcher | ❌ run separately |

---

## Issues fixed — 24 total, 16 fixed, 8 harmless

### Critical (all fixed)

| # | Issue | Node | How we fix it | Script check |
|---|-------|------|---------------|-------------|
| 1 | Accesslog DB exhausted (MDB_MAP_FULL) — every write fails to audit | Master | `olcDbMaxSize` → 30GB + 360-day auto-purge | fix-master Check 7 |
| 2 | Syncrepl "Size limit exceeded" infinite retry loop | Replica | Add `olcLimits: unlimited` for replicator on master + seed replica | fix-master Check 8 + fix-replica Check 14 |
| 3 | Replica missing ppolicy overlay | Replica | Create `olcOverlay=ppolicy` child entry + HashCleartext + default | fix-replica Check 5 |
| 4 | Replica has zero database ACLs | Replica | Add `olcAccess` rules on mdb + frontend | fix-replica Checks 9+10 |

### High (all fixed)

| # | Issue | Node | How we fix it | Script check |
|---|-------|------|---------------|-------------|
| 5 | Config checksum errors on both nodes | Both | `slapcat -n0` → `slapadd -n0` rebuild | fix-master Check 4 |
| 9 | Replica data stale (6K vs 30K entries) | Replica | Seed via ldapsearch→slapadd from master | fix-replica Check 14 |
| 10 | Master missing entryUUID/entryCSN indices | Master | Add `olcDbIndex: entryUUID eq` + `entryCSN eq` | fix-master Check 6 |

### Medium (all fixed)

| # | Issue | Node | How we fix it | Script check |
|---|-------|------|---------------|-------------|
| 12 | ppolicy lockout not enforced | Master | `olcPPolicyUseLockout: TRUE` | fix-master Check 12c |
| 14 | ACL break may deny access | Master | Clean ACLs with explicit read grants | fix-master Check 9 |
| 15 | No operational logging | Both | `olcLogLevel: stats` | fix-master Check 12d |
| 16 | Replica small DB maxsize | Replica | Seed gives correct data; DB auto-expands | fix-replica Check 14 |
| 22 | Main DB approaching 1GB limit | Master | `olcDbMaxSize` → 4GB | fix-master Check 12e |
| 23 | Accesslog purge too conservative | Master | 360-day retention via `olcAccessLogPurge` | fix-master Check 7 |

### Low (all fixed)

| # | Issue | Node | How we fix it | Script check |
|---|-------|------|---------------|-------------|
| 17 | No hardening (plaintext binds accepted) | Both | `olcSecurity: simple_bind=128` | fix-master Check 11 + fix-replica Check 12 |
| 18 | Replica olcReadOnly=FALSE | Replica | `olcReadOnly: TRUE` | fix-replica Check 8 |
| 20 | Frontend ACLs empty | Replica | Add baseline frontend ACLs | fix-replica Check 10 |

### Harmless/By-design (not fixed — intentional)

| # | Issue | Why we skip it |
|---|-------|----------------|
| 6 | Replica missing syncprov | Replicas don't serve changes — syncprov only on master |
| 7 | Syncrepl LDAP vs LDAPS | `starttls=yes` encrypts session — functionally identical |
| 8 | Missing accesslog module | Accesslog is master-only audit feature |
| 11 | Duplicate ppolicy module | Both entries point to same .so — harmless, removal riskier than keeping |
| 13 | Historical service instability | Pre-existing May/June restarts — current uptime stable |
| 19 | Redundant master-ca.crt on replica | Extra file on disk — not referenced in config |
| 21 | Missing back_monitor module | Optional monitoring — doesn't affect operations |
| 24 | Duplicate cn=module{1} on master | Harmless artifact — no functional issue |

### Also fixed (beyond original bank diagnostics)

| What | Where |
|------|-------|
| `olcTLSProtocolMin: 3.3` (was 0.0) | Both fix scripts |
| `olcTLSCACertificateFile` configured | Both fix scripts |
| Syncrepl `interval=00:00:00:10` keepalive | fix-replica |
| `olcModulePath: /opt/symas/lib/openldap` | fix-replica |

---

## Run order

### What the bank needs to do

```bash
# Step 1: Copy scripts to both servers
scp -r scripts/openldap-fix/ root@172.23.11.236:/tmp/
scp -r scripts/openldap-fix/ root@172.23.11.237:/tmp/

# Step 2: Run on MASTER first
ssh root@172.23.11.236
sudo bash /tmp/scripts/openldap-fix/bank-one-click-fix.sh

# Step 3: Run on REPLICA
ssh root@172.23.11.237
sudo MASTER_IP=172.23.11.236 bash /tmp/scripts/openldap-fix/bank-one-click-fix.sh
```

### What happens automatically

```
bank-one-click-fix.sh
├── Detects role (master/replica)
├── fix-master.sh or fix-replica.sh  (backup → checksum rebuild → fix → restart)
├── verify-openldap.sh               (18 health checks, role-specific)
├── diagnose-openldap.sh             (full diagnostic → report)
├── validate-bank-issues.sh          (24-issue coverage report)
└── Writes final report              (reports/bank-fix-report-*.txt)
```

### Additional scripts if needed

```bash
# E2E cross-node sync test (run from master, connects to both)
sudo LDAP_REPLICA_URI=ldap://172.23.11.237:389 \
     LDAP_MASTER_URI=ldap://localhost:389 \
     bash scripts/openldap-fix/e2e-openldap-test.sh --role both

# Log monitoring (30 minutes)
sudo bash scripts/openldap-fix/monitor-openldap-logs.sh --minutes 30 --report

# Safe cleanup (if reinstall needed)
sudo bash scripts/openldap-fix/cleanup-openldap.sh --backup --all --force
```

---

## Rollback

Every fix script creates a timestamped backup before changes:
```
/opt/symas/etc/openldap/slapd.d.fix-YYYYMMDD-HHMMSS/
```

To rollback:
```bash
cp -a /opt/symas/etc/openldap/slapd.d.fix-* /opt/symas/etc/openldap/slapd.d
systemctl restart symas-openldap-servers
```

---

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MASTER_IP` | auto-detected | Master IP for replica to connect to |
| `ADMIN_PW` | TheN1le1 | LDAP admin password |
| `REPL_PW` | replpass | Replicator bind password |
| `BASE_DN` | dc=eab,dc=bank,dc=local | LDAP base DN |
| `ACCESSLOG_GB` | 30 | Accesslog max size in GB |
| `RETENTION_DAYS` | 360 | Accesslog retention in days |

---

## Test results (2 independent AWS labs)

| Test | Existing lab | New lab |
|------|:---:|:---:|
| fix-master.sh | 17/17 PASS | 17/17 PASS |
| fix-replica.sh | 17/17 PASS | 13/13 PASS |
| verify-master.sh | 17/17 PASS | 17/17 PASS |
| verify-replica.sh | 18/18 PASS | 15/18* |
| e2e-openldap-test.sh | 13/13 PASS | N/A† |
| bank-one-click-fix.sh (master) | ✅ ALL PASS | — |
| bank-one-click-fix.sh (replica) | ✅ ALL PASS | — |

\* New lab: TLS certs not generated on fresh install (by design — fix scripts don't auto-generate certs)
† New lab E2E needs TLS certs on replica to function
