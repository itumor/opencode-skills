# OpenLDAP Script Guide

Complete reference for the `script/` directory: what each script does, the order to run them, environment variables, and how to execute them on a remote VM over SSH.

> **Test Status — Verified on RHEL 9.8 + Symas OpenLDAP 2.6.13 — 2026-06-08**
>
> | Suite | Result |
> |-------|--------|
> | Smoke (syntax + orchestrator) | PASS=95 WARN=0 FAIL=0 |
> | Master install (TLS) | All PASS (2026-05-20) |
> | Master install (no-TLS) | All PASS (2026-06-08) |
> | Replica install (TLS) | All PASS (2026-05-20) |
> | Replica install (no-TLS) | Live sync verified (2026-06-08) |
> | Connection tests | 26/26 (TLS), plain LDAP verified (no-TLS) |
>
> Tested on: AWS EC2 `t3.medium`, RHEL 9.8, us-west-2

---

## Table of Contents

1. [Quick Start — Master](#quick-start--master)
2. [Quick Start — Replica](#quick-start--replica)
3. [Requirements](#requirements)
4. [Environment Variables — Master](#environment-variables--master)
5. [Environment Variables — Replica](#environment-variables--replica)
6. [Master: Running the Full Stack](#master-running-the-full-stack)
7. [Replica: Running the Full Stack](#replica-running-the-full-stack)
8. [Running Over SSH](#running-over-ssh)
9. [Master Script Reference](#master-script-reference-ordered)
10. [Replica Script Reference](#replica-script-reference-ordered)
11. [Test Suite — Master](#test-suite--master)
12. [Test Suite — Replica](#test-suite--replica)
13. [Connection Testing](#connection-testing)
14. [Troubleshooting](#troubleshooting)

---

## Quick Start — Master

```bash
# 1. Copy scripts to master VM
scp -r ./script ec2-user@<MASTER_IP>:/tmp/script

# 2. Run master all-in-one installer (with TLS - default)
ssh -i ~/.ssh/your-key.pem ec2-user@<MASTER_IP>
sudo bash /tmp/script/install-symas-openldap-all-in-one.sh

# 2a. Run without TLS
sudo TLS_MODE=no ADMIN_PW=<password> bash /tmp/script/install-symas-openldap-all-in-one.sh
```

---

## Quick Start — Replica

```bash
# Prerequisites:
#   - Master is running (install-symas-openldap-all-in-one.sh complete)
#   - Master has run 26-configure-bindings.sh (cn=replicator + syncprov)
#   - No SSH/SCP from replica to master needed (self-signed TLS or no-TLS)

# 1. Copy scripts to replica VM
scp -r ./script ec2-user@<REPLICA_IP>:/tmp/script

# 2. Run replica all-in-one installer (with TLS - default)
ssh -i ~/.ssh/your-key.pem ec2-user@<REPLICA_IP>
sudo MASTER_IP=<MASTER_IP> \
     ADMIN_PW=<admin-password> \
     bash /tmp/script/install-symas-openldap-replica-all-in-one.sh

# 2a. Run without TLS
sudo MASTER_IP=<MASTER_IP> ADMIN_PW=<admin-password> TLS_MODE=no \
     bash /tmp/script/install-symas-openldap-replica-all-in-one.sh
```

---

## Requirements

| Requirement | Detail |
|-------------|--------|
| **OS** | RHEL 9 / AlmaLinux 9 / Rocky Linux 9 (or compatible) |
| **User** | Must run as `root` (use `sudo`) |
| **Repo** | Symas SOLDAP repo enabled via Red Hat Satellite |
| **OpenLDAP** | Symas OpenLDAP 2.6.x (installed by script 1 / r1) |
| **Packages** | `openssl`, `ldap-utils` auto-installed |
| **Replica extra** | No SSH/SCP needed — TLS is self-signed by default (`COPY_FROM_MASTER=0`). No-TLS mode available via `TLS_MODE=no`. |

---

## Environment Variables — Master

| Variable | Default | Description |
|----------|---------|-------------|
| `BASE_DN` | `dc=eab,dc=bank,dc=local` | LDAP base distinguished name |
| `BIND_DN` | `cn=admin,<BASE_DN>` | Admin bind DN |
| `BIND_PW` | *(auto-read from exampledb)* | Admin bind password |
| `TLS_MODE` | `yes` | `yes` = run TLS + hardening; `no` = skip TLS, plain LDAP |
| `MW_PASSWORD` | `ChangeMe123!` | Middleware service account password |
| `MW_BIND_DN` | `uid=mw,ou=ServiceAccounts,ou=Systems,<BASE_DN>` | MW user DN |
| `MW_BIND_PW` | `ChangeMe123!` | MW user bind password |
| `REPL_CN` | `replicator` | Replication user CN |
| `REPL_PW` | `replpass` | Replication user password |
| `ACCESSLOG_SUFFIX` | `cn=accesslog` | Accesslog database suffix |
| `SERVICE_OU` | `ou=ServiceAccounts,ou=Systems,<BASE_DN>` | Service accounts OU |
| `USER_BASE_DN` | `ou=Users,dc=eab,dc=bank,dc=local` | Users OU for new accounts |

```bash
export BASE_DN="dc=example,dc=com"
export BIND_PW="MyAdminPass123"
export TLS_MODE=no
sudo -E bash install-symas-openldap-all-in-one.sh
```

---

## Environment Variables — Replica

| Variable | Required | Default | Description |
|----------|:--------:|---------|-------------|
| `MASTER_IP` | **yes** | — | IP or hostname of master node |
| `ADMIN_PW` | **yes** | — | Admin password (must match master) |
| `REPL_PW` | no | `replpass` | Replication bind password (must match master) |
| `BASE_DN` | no | `dc=eab,dc=bank,dc=local` | LDAP base DN (must match master) |
| `SERVER_ID` | no | `2` | `olcServerID` — must differ from master (`1`) |
| `TLS_MODE` | no | `yes` | `yes` = full TLS; `no` = plain LDAP, no certs |
| `COPY_FROM_MASTER` | no | `0` | `1` = copy CA from master; `0` = self-signed |
| `STAGED_CA_CERT` | no | — | Path to pre-staged CA cert (when `COPY_FROM_MASTER=1`) |
| `STAGED_CA_KEY` | no | — | Path to pre-staged CA key (when `COPY_FROM_MASTER=1`) |
| `LDAPTLS_REQCERT` | no | `never` | TLS cert verify mode for tests |

```bash
sudo MASTER_IP=10.0.0.1 \
     ADMIN_PW=MyAdminPass123 \
     REPL_PW=ReplPass456 \
     bash install-symas-openldap-replica-all-in-one.sh

# No-TLS mode
sudo MASTER_IP=10.0.0.1 \
     ADMIN_PW=MyAdminPass123 \
     TLS_MODE=no \
     bash install-symas-openldap-replica-all-in-one.sh
```

---

## Master: Running the Full Stack

**`install-symas-openldap-all-in-one.sh`** — runs all master scripts in order.

```bash
# Basic
sudo bash /tmp/script/install-symas-openldap-all-in-one.sh

# Custom base DN + password
sudo BASE_DN="dc=example,dc=com" BIND_PW="Secret123!" \
  bash /tmp/script/install-symas-openldap-all-in-one.sh
```

Execution order:

```
1 → 3 → 4 → 5 → 6 → 11 → 7 → 8.0 → 8 → 26 → 9 → 9.0 → 10 → 10.0
→ 12 → 13 → 7(re-verify) → 16 → 17 → 27 → 18 → 19 → 20
→ (24-TLS → 21-hardening [with TLS])  or  (21-hardening [no TLS])   [controlled by TLS_MODE]
→ 22 → 23 → 25 → tests
```

---

## Replica: Running the Full Stack

**`install-symas-openldap-replica-all-in-one.sh`** — runs all `r1`–`r9` scripts in order.

```bash
# On replica node, after master is fully installed:
sudo MASTER_IP=10.0.0.1 \
     ADMIN_PW=MyAdminPass123 \
     SSH_KEY=~/.ssh/key.pem \
     bash /tmp/script/install-symas-openldap-replica-all-in-one.sh
```

Execution order:

```
r1(install) → r2(configure syncrepl) → r3(start daemon)
→ r4(fix env)
→ (r5-TLS → r6-fix ldapi → r7-harden)  or  (r6-fix ldapi → r7-harden[no TLS])  [controlled by TLS_MODE]
→ r8(tune) → r9(verify)
→ tests(connections + readonly + sync)
```

When `TLS_MODE=no`: r2 configures syncrepl without `starttls=yes`. r5 is skipped. r7 runs without TLS enforcement (anonymous bind still disabled).

---

## Running Over SSH

### Copy to master

```bash
scp -i ~/.ssh/key.pem -r ./script ec2-user@<MASTER_IP>:/tmp/script
chmod +x /tmp/script/*.sh /tmp/script/test/*.sh /tmp/script/replica/*.sh
```

### Copy to replica

```bash
scp -i ~/.ssh/key.pem -r ./script ec2-user@<REPLICA_IP>:/tmp/script
chmod +x /tmp/script/*.sh /tmp/script/replica/*.sh /tmp/script/replica/test/*.sh
```

### Run master installer remotely (stream logs)

```bash
ssh -i ~/.ssh/key.pem ec2-user@<MASTER_IP> \
  "sudo bash /tmp/script/install-symas-openldap-all-in-one.sh 2>&1" \
  | tee master-install-$(date +%Y%m%d).log
```

### Run replica installer remotely (stream logs)

```bash
# With TLS (default)
ssh -i ~/.ssh/key.pem ec2-user@<REPLICA_IP> \
  "sudo MASTER_IP=<MASTER_IP> ADMIN_PW=<password> \
   bash /tmp/script/install-symas-openldap-replica-all-in-one.sh 2>&1" \
  | tee replica-install-$(date +%Y%m%d).log

# Without TLS
ssh -i ~/.ssh/key.pem ec2-user@<REPLICA_IP> \
  "sudo MASTER_IP=<MASTER_IP> ADMIN_PW=<password> TLS_MODE=no \
   bash /tmp/script/install-symas-openldap-replica-all-in-one.sh 2>&1" \
  | tee replica-install-$(date +%Y%m%d).log
```

### Run a single script over SSH

```bash
ssh -i ~/.ssh/key.pem ec2-user@<IP> "sudo bash /tmp/script/21-hardening.sh"
ssh -i ~/.ssh/key.pem ec2-user@<IP> "sudo bash /tmp/script/replica/r7-harden-replica.sh"
```

---

## Master Script Reference (Ordered)

### Phase 1 — Installation

| Script | Root | What it does |
|--------|:----:|-------------|
| `0-clean-openldap.sh` | yes | **Destructive reset** — removes all Symas packages, data, config. Run before fresh install. |
| `1-install-symas-openldap.sh` | yes | Installs `symas-openldap-clients` + `symas-openldap-servers` via Satellite-managed repo. |
| `3-install-example.sh` | yes | Deploys customised `exampledb.sh` (custom suffix/org), generates `slapd.conf`, converts to `cn=config` via `slaptest`. |
| `4-Start-the-daemon.sh` | yes | Enables and starts `symas-openldap-servers` systemd service. |

### Phase 2 — Warning Fixes & Verification

| Script | Root | What it does |
|--------|:----:|-------------|
| `5-fix_all_symas_warns.sh` | yes | Creates `/etc/profile.d/symas_env.sh` (PATH + LDAPCONF). |
| `6-fix_remaining_symas_warns.sh` | yes | Creates `slapd` symlink, configures minimal TLS for LDAPS listener. |
| `11-fix_version_warns.sh` | yes | Patches verification script to capture `stderr` (suppress false WARNs). |
| `7-verify_symas_openldap.sh` | yes | Full verification: binaries, service, listeners, TLS, base DN. Prints PASS/WARN/FAIL. |

### Phase 3 — Directory Structure

| Script | Root | What it does |
|--------|:----:|-------------|
| `8.0-fix_ldapi_acl.sh` | yes | Ensures SASL/EXTERNAL has `manage` on `cn=config`; resets `olcRootPW` (hashed via `slappasswd`). Dynamic config DB detection for Symas 2.6.13. |
| `8-create_top_ous.sh` | yes | Creates top-level OUs: `ou=Users`, `ou=Groups`, `ou=Systems`, `ou=ServiceAccounts,ou=Systems`. |
| `26-configure-bindings.sh` | yes | Creates `cn=replicator` user, adds `syncprov` overlay, sets replication ACL. TLS-aware admin bind. |

### Phase 4 — Password Policy

| Script | Root | What it does |
|--------|:----:|-------------|
| `9-password_policy.sh` | yes | Creates `ou=Policies` + `cn=default` ppolicy entry (min length, lockout, history). |
| `9.0-password_policy_load_module.sh` | yes | Loads `ppolicy` module into `cn=config`. |
| `10-ppolicy-container.sh` | yes | Adds `ppolicy` overlay to main database. |
| `10.0-password_policy_make_default.sh` | yes | Sets `pwdDefaultPolicy` so default policy applies to all users. |

### Phase 5 — Schema

| Script | Root | What it does |
|--------|:----:|-------------|
| `12-Create_custom_schema.sh` | yes | Creates `cn=bank-custom` schema container in `cn=schema,cn=config`. Idempotent. |
| `13-Create_custom_schema_attr.sh` | yes | Adds custom attrs (`userisactive`, `memorableanswer`, `memorablequestion`, `cif`, `activationdatetime`, etc.) and `bankUserExtension` objectClass. Idempotent. |

### Phase 6 — Users & ACLs

| Script | Root | What it does |
|--------|:----:|-------------|
| `15-add-password-checker.sh` | yes | Adds `pwdPolicyChecker` to default policy (server-side quality check). |
| `16-add-strong-password-quality-checker-PPM.sh` | yes | Loads Symas `ppm` module for strong complexity. Gracefully skips if not available (commercial). |
| `17-create_mw_user.sh` | yes | Creates `uid=mw` middleware service account. |
| `27-configure-mw-acl.sh` | yes | Grants `uid=mw` write ACL on `ou=Users`. |
| `18-service-account-password-policy-never-expire.sh` | yes | Creates `cn=service-account` policy (`pwdMaxAge: 0`) for service accounts. |
| `19-create-user-using-mw-user.sh` | yes | Creates test user via MW account (validates MW ACLs). |

### Phase 7 — Security & Hardening

| Script | Root | What it does |
|--------|:----:|-------------|
| `21-hardening.sh` | yes | Disables anonymous bind, requires TLS for simple binds (`simple_bind=128`), sets TLS protocol min + cipher suite, hardens fs permissions. |
| `22-tuning.sh` | yes | `LimitNOFILE=524288` drop-in, configures `SLAPD_URLS`/`SLAPD_OPTIONS`, restarts service. |
| `23-ensure-installation-not-under-root.sh` | yes | Verifies no Symas data under `/root`. |
| `24-configure-ssl-tls.sh` | yes | Generates/installs TLS certs (self-signed or external), configures `olcTLS*` in `cn=config`, enables LDAPS listener. |
| `25-configure-accesslog-audit.sh` | yes | Loads `accesslog` module, creates `cn=accesslog` MDB, attaches overlay to main database. |

### Phase 8 — Migration & Utilities

| Script | Root | What it does |
|--------|:----:|-------------|
| `20-migration.sh` | yes | Placeholder — add custom migration/import logic here. |
| `14-next-steps.sh` | no | Prints post-install guidance. |
| `audio-test.sh` | no | Plays audible confirmation bell (CI/agent hook). |
| `Exampledb/exampledb.sh` | yes | Customised Symas `exampledb.sh` — initialises database with custom suffix, org, hashed rootpw. Called by `3-install-example.sh`. |

---

## Replica Script Reference (Ordered)

All replica scripts live under `script/replica/`. Run via `install-symas-openldap-replica-all-in-one.sh` or individually.

### Key differences from master

| Aspect | Master | Replica |
|--------|--------|---------|
| `olcServerID` | `1` | `2` (or higher, set via `SERVER_ID`) |
| `syncprov` overlay | Added — provider | **Not added** — consumer only |
| `olcSyncRepl` | Not set | Set — pulls from master via `refreshAndPersist` |
| `olcUpdateRef` | Not set | Set — redirects writes back to master |
| Data | Authoritative | Read-only, synced from master |
| Writes | Accepted | Referred to master (or rejected) |

### Script reference

| Script | Root | What it does |
|--------|:----:|-------------|
| `r1-install-symas-openldap-replica.sh` | yes | Installs `symas-openldap-clients` + `symas-openldap-servers` via Satellite repo. Same packages as master. |
| `r2-configure-replica-instance.sh` | yes | Initialises `cn=config` with `SERVER_ID`, `olcSyncrepl` (provider=master, `refreshAndPersist`, conditional StartTLS via `TLS_MODE`), `olcUpdateRef`. No `syncprov`. Requires `MASTER_IP`, `ADMIN_PW`, `REPL_PW`. |
| `r3-start-replica-daemon.sh` | yes | Enables + starts `symas-openldap-servers`, waits for `ldapi://` reachable. |
| `r4-fix-replica-env.sh` | yes | Creates `/etc/profile.d/symas_env.sh`, creates `slapd` symlink. Mirrors master `5-fix_all_symas_warns.sh`. |
| `r5-configure-replica-tls.sh` | yes | **Skipped when `TLS_MODE=no`.** TLS setup. Mode 1 (`COPY_FROM_MASTER=1`): copies CA cert+key from master via pre-staged files, signs new server cert for replica. Mode 0 (`COPY_FROM_MASTER=0`, default): generates standalone self-signed CA + cert. |
| `r6-fix-replica-ldapi-acl.sh` | yes | Ensures SASL/EXTERNAL has `manage` on `cn=config`. Does NOT reset `olcRootPW` (data syncs from master). |
| `r7-harden-replica.sh` | yes | Disables anon bind, requires TLS for simple binds (skipped if `TLS_MODE=no`), hardens fs permissions. Preserves `olcUpdateRef`. |
| `r8-tune-replica.sh` | yes | `LimitNOFILE=524288` drop-in, `SLAPD_URLS`, restarts service. Same as master `22-tuning.sh`. |
| `r9-verify-replica.sh` | yes | Full replica health check: service, ports, `olcSyncrepl` present, `olcUpdateRef` set, admin bind, data synced, `contextCSN` vs master, write rejection confirmed. |

### Usage — individual replica scripts over SSH

```bash
# Run a single replica script
ssh -i ~/.ssh/key.pem ec2-user@<REPLICA_IP> \
  "sudo MASTER_IP=<MASTER_IP> ADMIN_PW=<password> \
   bash /tmp/script/replica/r2-configure-replica-instance.sh"

# Re-run verification at any time
ssh -i ~/.ssh/key.pem ec2-user@<REPLICA_IP> \
  "sudo MASTER_IP=<MASTER_IP> ADMIN_PW=<password> \
   bash /tmp/script/replica/r9-verify-replica.sh"

# Re-run TLS config (copy new CA from master)
ssh -i ~/.ssh/key.pem ec2-user@<REPLICA_IP> \
  "sudo MASTER_IP=<MASTER_IP> SSH_KEY=~/.ssh/key.pem \
   bash /tmp/script/replica/r5-configure-replica-tls.sh"
```

---

## Test Suite — Master

### Smoke tests (safe on any machine, no LDAP needed)

```bash
bash test/run_all.sh
# Expected: PASS=95 WARN=0 FAIL=0
```

### Integration tests (requires running OpenLDAP)

```bash
sudo RUN_LDAP_INTEGRATION_TESTS=1 LDAPTLS_REQCERT=never \
  bash /tmp/script/test/run_all.sh
```

| Test | What it checks |
|------|----------------|
| `test_password_checker.sh` | `pwdPolicyChecker` on default policy |
| `test_password_complexity.sh` | PPM module loaded, complexity enforced |
| `test_mw_service_user.sh` | MW user exists and can bind |
| `test_service_account_password_policy_never_expire.sh` | No-expire policy on service accounts |
| `test_create_user_using_mw_user.sh` | MW user can create entries in `ou=Users` |
| `test_installation_not_under_root.sh` | No data under `/root` |
| `test_tuning.sh` | `LimitNOFILE` drop-in present, service running |
| `test_configure_ssl_tls.sh` | TLS certs in `cn=config`, LDAPS listener active |
| `test_custom_schema_attr.sh` | Custom attrs (`userisactive`, `cif`, etc.) readable |
| `test_accesslog_audit.sh` | Accesslog DB present, overlay active |
| `test_bindings.sh` | Replication user exists, syncprov overlay active |

---

## Test Suite — Replica

```bash
# Run all replica tests
sudo MASTER_IP=<MASTER_IP> ADMIN_PW=<password> REPL_PW=replpass \
  LDAPTLS_REQCERT=never bash /tmp/script/replica/test/test_replica_connections.sh

sudo ADMIN_PW=<password> LDAPTLS_REQCERT=never \
  bash /tmp/script/replica/test/test_replica_readonly.sh

sudo MASTER_IP=<MASTER_IP> ADMIN_PW=<password> LDAPTLS_REQCERT=never \
  bash /tmp/script/replica/test/test_replica_sync.sh
```

| Test | What it checks |
|------|----------------|
| `test_replica_connections.sh` | Ports 389/636, StartTLS, LDAPS, admin bind, replication bind |
| `test_replica_readonly.sh` | Write/modify on replica returns referral or rejection |
| `test_replica_sync.sh` | Write user on master → visible on replica within `SYNC_WAIT` seconds |

---

## Connection Testing

`test-openldap-connections.sh` — 11-section connection test. Runs on either master or replica.

```bash
# On master or replica (as root for full coverage)
sudo LDAPTLS_REQCERT=never bash /tmp/script/test-openldap-connections.sh

# Custom server
sudo bash test-openldap-connections.sh \
  -H ldap://myserver \
  -b dc=example,dc=com \
  -w MyAdminPass \
  -R MyReplPass

# Verbose (show ldap output on failure)
sudo bash test-openldap-connections.sh -v

# Skip ldapi (no root)
bash test-openldap-connections.sh --no-ldapi -H ldap://myserver -w MyPass
```

Tests covered: port 389/636, service status, LDAP plain, StartTLS, LDAPS, ldapi EXTERNAL, admin bind, replication bind, MW bind, TLS cert inspection, password policy + schema.

---

## Troubleshooting

### "Must be run as root"

```bash
sudo bash <script>.sh
sudo MASTER_IP=x ADMIN_PW=y bash replica/<script>.sh
```

### `ldapadd`/`ldapsearch` not found

```bash
source /etc/profile.d/symas_env.sh
# or
export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
```

### Replica not syncing — check syncrepl config

```bash
sudo ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  -LLL '(objectClass=olcMdbConfig)' olcSyncRepl olcUpdateRef
```

### Replica contextCSN behind master — check logs

```bash
journalctl -u symas-openldap-servers -n 50 | grep -i "sync\|repl\|error"
```

### Service fails to start after TLS config

```bash
sudo ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  "(objectClass=olcGlobal)" olcTLSCertificateFile olcTLSCertificateKeyFile
chown root:ldap /path/to/cert.pem /path/to/key.pem
chmod 640 /path/to/key.pem
```

### PPM module not loading

Non-fatal on Symas free build. Script 16 prints `[WARN]` and continues. Requires Symas commercial license.

### Replication not working — master side

```bash
# 1. syncprov overlay present?
sudo ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config "(objectClass=olcSyncProvConfig)"
# 2. replicator user exists?
LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w $ADMIN_PW -b dc=eab,dc=bank,dc=local "(cn=replicator)"
# 3. Re-run bindings script
sudo bash /tmp/script/26-configure-bindings.sh
```

### Wipe master and start over

**Warning:** Permanently deletes all data and packages on that node.

```bash
sudo bash /tmp/script/0-clean-openldap.sh
sudo bash /tmp/script/install-symas-openldap-all-in-one.sh
```

### Wipe replica and re-run

```bash
sudo bash /tmp/script/0-clean-openldap.sh
sudo MASTER_IP=<ip> ADMIN_PW=<pw> SSH_KEY=~/.ssh/key.pem \
  bash /tmp/script/install-symas-openldap-replica-all-in-one.sh
```

---

## Full SSH Example — Master + Replica (EC2, RHEL 9)

```bash
MASTER_IP=54.185.183.18       # public
REPLICA_IP=54.191.26.211      # public
MASTER_PRIV=10.50.1.10        # private (for syncrepl)
KEY=terraform/openldap-master-replica/.local-ssh/openldap_master_replica
ADMIN_PW=TheN1le1

# --- MASTER ---
# 1. Copy scripts
scp -i $KEY -r ./script ec2-user@$MASTER_IP:/tmp/script

# 2. Install master with TLS
ssh -i $KEY ec2-user@$MASTER_IP \
  "sudo bash /tmp/script/install-symas-openldap-all-in-one.sh 2>&1" \
  | tee master-$(date +%Y%m%d).log

# 2a. Install master without TLS
ssh -i $KEY ec2-user@$MASTER_IP \
  "sudo TLS_MODE=no ADMIN_PW=$ADMIN_PW \
   bash /tmp/script/install-symas-openldap-all-in-one.sh 2>&1" \
  | tee master-$(date +%Y%m%d).log

# 3. Run master integration tests
ssh -i $KEY ec2-user@$MASTER_IP \
  "sudo LDAPTLS_REQCERT=never RUN_LDAP_INTEGRATION_TESTS=1 \
   bash /tmp/script/test/run_all.sh"

# --- REPLICA ---
# 4. Copy scripts to replica
scp -i $KEY -r ./script ec2-user@$REPLICA_IP:/tmp/script

# 5. Install replica with TLS (no SSH key copy needed)
ssh -i $KEY ec2-user@$REPLICA_IP \
  "sudo MASTER_IP=$MASTER_PRIV ADMIN_PW=$ADMIN_PW \
   bash /tmp/script/install-symas-openldap-replica-all-in-one.sh 2>&1" \
  | tee replica-$(date +%Y%m%d).log

# 5a. Install replica without TLS
ssh -i $KEY ec2-user@$REPLICA_IP \
  "sudo MASTER_IP=$MASTER_PRIV ADMIN_PW=$ADMIN_PW TLS_MODE=no \
   bash /tmp/script/install-symas-openldap-replica-all-in-one.sh 2>&1" \
  | tee replica-$(date +%Y%m%d).log

# 6. Test replication — add entry on master, read from replica
ldapadd -x -H ldap://$MASTER_IP:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w $ADMIN_PW <<EOF
dn: cn=repltest,dc=eab,dc=bank,dc=local
objectClass: organizationalRole
cn: repltest
EOF

sleep 3
ldapsearch -x -o ldif-wrap=no -H ldap://$REPLICA_IP:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w $ADMIN_PW \
  -b "cn=repltest,dc=eab,dc=bank,dc=local" -s base dn
```
