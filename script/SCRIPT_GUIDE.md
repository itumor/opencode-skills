# OpenLDAP Script Guide

Complete reference for the `script/` directory: what each script does, the order to run them, environment variables, and how to execute them on a remote VM over SSH.

> **Test Status — Verified on RHEL 9.7 + Symas OpenLDAP 2.6.13 — 2026-05-19**
>
> | Suite | PASS | WARN | FAIL |
> |-------|------|------|------|
> | Smoke (syntax + orchestrator) | 79 | 0 | 0 |
> | LDAP Integration (full install + all tests) | All PASS | 0 | 0 |
>
> Tested on: AWS EC2 `t3.medium`, RHEL 9.7, us-west-2 (`i-07367b4591f1c98cc`)

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Requirements](#requirements)
3. [Environment Variables](#environment-variables)
4. [Running the Full Stack (All-in-One)](#running-the-full-stack-all-in-one)
5. [Running Over SSH](#running-over-ssh)
6. [Script Reference (Ordered)](#script-reference-ordered)
7. [Test Suite](#test-suite)
8. [Troubleshooting](#troubleshooting)

---

## Quick Start

```bash
# 1. Copy scripts to the target VM
scp -r ./script ec2-user@<IP>:/tmp/script

# 2. SSH in and run the all-in-one installer
ssh -i ~/.ssh/your-key.pem ec2-user@<IP>
sudo bash /tmp/script/install-symas-openldap-all-in-one.sh
```

---

## Requirements

| Requirement | Detail |
|-------------|--------|
| **OS** | RHEL 9 / AlmaLinux 9 / Rocky Linux 9 (or compatible) |
| **User** | Must run as `root` (use `sudo`) |
| **Internet** | Required for Symas repo and package download |
| **OpenLDAP** | Symas OpenLDAP 2.6.x (installed by script 1) |
| **Packages** | `openssl`, `ldap-utils` auto-installed |

---

## Environment Variables

All scripts use sensible defaults. Override any of these before running:

| Variable | Default | Description |
|----------|---------|-------------|
| `BASE_DN` | `dc=eab,dc=bank,dc=local` | LDAP base distinguished name |
| `BIND_DN` | `cn=admin,<BASE_DN>` | Admin bind DN |
| `BIND_PW` | *(auto-read from exampledb)* | Admin bind password |
| `MW_PASSWORD` | `ChangeMe123!` | Middleware service account password |
| `MW_BIND_DN` | `uid=mw,ou=ServiceAccounts,ou=Systems,<BASE_DN>` | MW user DN |
| `MW_BIND_PW` | `ChangeMe123!` | MW user bind password |
| `REPL_CN` | `replicator` | Replication user CN |
| `REPL_PW` | *(generated)* | Replication user password |
| `ACCESSLOG_SUFFIX` | `cn=accesslog` | Accesslog database suffix |
| `SERVICE_OU` | `ou=ServiceAccounts,ou=Systems,<BASE_DN>` | Service accounts OU |
| `USER_BASE_DN` | `ou=Users,dc=eab,dc=bank,dc=local` | Users OU for new accounts |
| `USER_UID` | `testuser` | UID for script 19 test user |
| `SKIP_DNF_UPDATE` | *(unset)* | Set to `1` to skip OS package update |

Export variables before running:

```bash
export BASE_DN="dc=example,dc=com"
export BIND_PW="MyAdminPass123"
sudo -E bash install-symas-openldap-all-in-one.sh
```

---

## Running the Full Stack (All-in-One)

**`install-symas-openldap-all-in-one.sh`** — runs all scripts in the correct order.

```bash
# On the target VM, as root:
sudo bash /tmp/script/install-symas-openldap-all-in-one.sh

# With custom base DN and password:
sudo BASE_DN="dc=example,dc=com" BIND_PW="Secret123!" \
  bash /tmp/script/install-symas-openldap-all-in-one.sh
```

Execution order inside the all-in-one:

```
1  → 3 → 4 → 5 → 6 → 11 → 7 → 8.0 → 8 → 26 → 9 → 9.0 → 10 → 10.0
→ 12 → 13 → 7 (re-verify) → 16 → 17 → 27 → 18 → 19 → 20 → 24 → 21
→ 22 → 23 → 25
```

Then runs all integration tests.

---

## Running Over SSH

### Copy scripts to any VM

```bash
# EC2 (Amazon Linux / RHEL)
scp -i ~/.ssh/your-key.pem -r ./script ec2-user@<PUBLIC_IP>:/tmp/script

# Generic VM (password auth)
scp -r ./script user@<IP>:/tmp/script
```

### Run the full installer remotely (single command)

```bash
ssh -i ~/.ssh/your-key.pem ec2-user@<PUBLIC_IP> \
  "sudo bash /tmp/script/install-symas-openldap-all-in-one.sh"
```

### Run with environment variables over SSH

```bash
ssh -i ~/.ssh/your-key.pem ec2-user@<PUBLIC_IP> \
  "sudo BASE_DN='dc=example,dc=com' BIND_PW='Secret123!' \
   bash /tmp/script/install-symas-openldap-all-in-one.sh"
```

### Run a single script over SSH

```bash
# Example: run only the hardening script
ssh -i ~/.ssh/your-key.pem ec2-user@<PUBLIC_IP> \
  "sudo bash /tmp/script/21-hardening.sh"
```

### Stream logs to local file

```bash
ssh -i ~/.ssh/your-key.pem ec2-user@<PUBLIC_IP> \
  "sudo bash /tmp/script/install-symas-openldap-all-in-one.sh 2>&1" \
  | tee install-$(date +%Y%m%d-%H%M%S).log
```

---

## Script Reference (Ordered)

### Phase 1 — Installation

| Script | Requires root | What it does |
|--------|:---:|-------------|
| `0-clean-openldap.sh` | yes | **Destructive reset** — removes all Symas packages, data, and config. Run before a fresh install. |
| `1-install-symas-openldap.sh` | yes | Adds the Symas SOLDAP yum repo, updates OS packages, installs `symas-openldap-clients` and `symas-openldap-servers`. |
| `3-install-example.sh` | yes | Replaces the vendor `exampledb.sh` with the customized version (custom suffix/domain), generates `slapd.conf`, converts it to `cn=config` via `slaptest`. |
| `4-Start-the-daemon.sh` | yes | Enables and starts the `symas-openldap` (and optional `slapd`) systemd service. |

### Phase 2 — Warning Fixes & Verification

| Script | Requires root | What it does |
|--------|:---:|-------------|
| `5-fix_all_symas_warns.sh` | yes | Creates `/etc/profile.d/symas_env.sh` (PATH + LDAPCONF), ensures Symas binaries are discoverable system-wide. |
| `6-fix_remaining_symas_warns.sh` | yes | Creates `/usr/local/sbin/slapd` symlink, adds Symas to PATH in env file, configures minimal TLS for the LDAPS listener. |
| `11-fix_version_warns.sh` | yes | Patches the verification script to capture `stderr` so version checks don't produce false WARNs. |
| `7-verify_symas_openldap.sh` | yes | Runs a full Symas verification: binary paths, service status, LDAP/LDAPS listeners, TLS, base DN reachability. Prints PASS/WARN/FAIL summary. |

### Phase 3 — Directory Structure

| Script | Requires root | What it does |
|--------|:---:|-------------|
| `8.0-fix_ldapi_acl.sh` | yes | Detects the active `ldapi://` socket; ensures `SASL/EXTERNAL` has `manage` access to `cn=config`; resets `olcRootPW` in the main database. Handles Symas 2.6.13 dynamic config DB file naming. |
| `8-create_top_ous.sh` | yes | Creates the top-level OUs under `BASE_DN`: `ou=Users`, `ou=Groups`, `ou=Systems`, `ou=ServiceAccounts,ou=Systems`. |
| `26-configure-bindings.sh` | yes | Creates the replication user (`cn=replicator`), configures `syncprov` overlay on the main database, sets up `olcSyncRepl` for replica nodes. Falls back to admin simple bind when EXTERNAL lacks data ACL. |

### Phase 4 — Password Policy

| Script | Requires root | What it does |
|--------|:---:|-------------|
| `9-password_policy.sh` | yes | Creates the `ou=Policies` container and a `cn=default` ppolicy entry with baseline rules (min length, lockout, history). |
| `9.0-password_policy_load_module.sh` | yes | Loads the `ppolicy` overlay module into `cn=config` (`olcModuleLoad: ppolicy`). |
| `10-ppolicy-container.sh` | yes | Adds the `ppolicy` overlay to the main database with a pointer to `cn=default,ou=Policies,BASE_DN`. |
| `10.0-password_policy_make_default.sh` | yes | Sets `pwdDefaultPolicy` on the root entry so the default policy applies to all users. |

### Phase 5 — Schema

| Script | Requires root | What it does |
|--------|:---:|-------------|
| `12-Create_custom_schema.sh` | yes | Creates a custom schema container `cn=customSchema` in `cn=schema,cn=config` via SASL EXTERNAL. Idempotent — skips if already present. |
| `13-Create_custom_schema_attr.sh` | yes | Adds custom attribute types (`userisactive`, `memorableanswer`, `memorablequestion`) and a custom objectClass to the schema. Idempotent. |

### Phase 6 — Users & ACLs

| Script | Requires root | What it does |
|--------|:---:|-------------|
| `15-add-password-checker.sh` | yes | Adds `pwdPolicyChecker` to the default password policy to enable server-side quality checking. |
| `16-add-strong-password-quality-checker-PPM.sh` | yes | Loads the Symas `ppm` (Password Policy Module) for strong complexity rules. Gracefully skips if module not available. |
| `17-create_mw_user.sh` | yes | Creates the middleware service account `uid=mw` under `ou=ServiceAccounts,ou=Systems,BASE_DN`. |
| `27-configure-mw-acl.sh` | yes | Grants `uid=mw` read access to `ou=Users` and write access to specific attributes needed by middleware. |
| `18-service-account-password-policy-never-expire.sh` | yes | Creates a separate password policy (`cn=no-expire`) with `pwdMaxAge: 0` and applies it to service accounts so their passwords never expire. |
| `19-create-user-using-mw-user.sh` | yes | Creates a test user under `ou=Users` using the MW service account credentials (validates MW ACLs work). |

### Phase 7 — Security & Hardening

| Script | Requires root | What it does |
|--------|:---:|-------------|
| `21-hardening.sh` | yes | Removes anonymous read, restricts `rootdn` access, disables deprecated TLS versions, sets `olcSecurity` size/time limits. |
| `22-tuning.sh` | yes | Sets `LimitNOFILE` in a systemd drop-in, configures `SLAPD_URLS` and `SLAPD_OPTIONS` in the defaults file, reloads systemd and restarts the service. |
| `23-ensure-installation-not-under-root.sh` | yes | Verifies no Symas data directories are under `/root` (security check). Prints PASS/WARN/FAIL. |
| `24-configure-ssl-tls.sh` | yes | Configures `olcTLSCertificateFile`, `olcTLSCertificateKeyFile`, `olcTLSCACertificateFile` in `cn=config`; enables LDAPS listener; adds TLS to `SLAPD_URLS`. |
| `25-configure-accesslog-audit.sh` | yes | Loads the `accesslog` overlay module, creates a separate `cn=accesslog` MDB database, attaches the overlay to the main database. SELinux labels set if available. |

### Phase 8 — Migration & Next Steps

| Script | Requires root | What it does |
|--------|:---:|-------------|
| `20-migration.sh` | yes | Placeholder — implement custom migration logic here (import from old LDAP, LDIF transforms, etc.). Currently a no-op. |
| `14-next-steps.sh` | no | Prints post-install guidance (manual steps, recommended checks). |

### Utilities

| Script | Requires root | What it does |
|--------|:---:|-------------|
| `audio-test.sh` | no | Plays an audible confirmation bell (terminal bell + macOS `afplay`). Used by CI/agent hooks. |
| `Exampledb/exampledb.sh` | yes | Customized Symas `exampledb.sh` — sets up the initial database with a custom suffix, org name, and root DN. Called by `3-install-example.sh`. |

---

## Test Suite

### Smoke Tests (safe on any machine, no LDAP needed)

```bash
# From the script/ directory
bash test/run_all.sh
```

Expected output: `PASS=80 WARN=0 FAIL=0`

Smoke tests verify that every `.sh` file passes `bash -n` (syntax check) and that the all-in-one orchestrator references all existing scripts.

### Integration Tests (requires a running OpenLDAP instance)

```bash
# On the target VM after running install-symas-openldap-all-in-one.sh
sudo RUN_LDAP_INTEGRATION_TESTS=1 bash /tmp/script/test/run_all.sh
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
| `test_custom_schema_attr.sh` | Custom attrs (`userisactive`, etc.) queryable |
| `test_accesslog_audit.sh` | Accesslog DB present, overlay active |
| `test_bindings.sh` | Replication user exists, syncprov overlay active |

---

## Troubleshooting

### Script fails: "Must be run as root"

```bash
sudo bash <script-name>.sh
# or with env vars:
sudo BASE_DN="dc=example,dc=com" bash <script-name>.sh
```

### `ldapadd`/`ldapsearch` not found

The Symas PATH is not loaded. Either:

```bash
source /etc/profile.d/symas_env.sh
# or
export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
```

### `olcDatabase={0}config.ldif` not found (Symas 2.6.13)

Script `8.0-fix_ldapi_acl.sh` was patched to detect the config DB file dynamically. If you see this on an older version of the script, pull the latest from this branch.

### Service fails to start after TLS config

Check the TLS certificate paths in `cn=config`:

```bash
sudo ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  "(objectClass=olcGlobal)" olcTLSCertificateFile olcTLSCertificateKeyFile
```

Ensure the `ldap` user can read the cert files:

```bash
chown root:ldap /path/to/cert.pem /path/to/key.pem
chmod 640 /path/to/key.pem
```

### PPM module not loading

The `ppm` module requires a Symas commercial license on some builds. Script `16` will print `[WARN]` and continue — this is non-fatal. Basic password policy still works via `ppolicy`.

### Replication not working

1. Verify `syncprov` overlay is active on master: `ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config "(objectClass=olcSyncProvConfig)"`
2. Check the replication user exists: `ldapsearch -x -D "cn=admin,BASE_DN" -W -b BASE_DN "(cn=replicator)"`
3. Check replica logs: `journalctl -u symas-openldap -n 50`

### Wipe and start over

```bash
# DESTRUCTIVE — removes all data and packages
sudo bash /tmp/script/0-clean-openldap.sh
# Then re-run install
sudo bash /tmp/script/install-symas-openldap-all-in-one.sh
```

---

## Full SSH Example (EC2, RHEL 9)

```bash
# From your local machine:

# 1. Copy scripts
scp -i ~/.ssh/ldap-key.pem -r ./script ec2-user@52.13.60.230:/tmp/script

# 2. Set executable
ssh -i ~/.ssh/ldap-key.pem ec2-user@52.13.60.230 "chmod +x /tmp/script/*.sh /tmp/script/test/*.sh"

# 3. Run full install (stream logs locally)
ssh -i ~/.ssh/ldap-key.pem ec2-user@52.13.60.230 \
  "sudo bash /tmp/script/install-symas-openldap-all-in-one.sh 2>&1" \
  | tee install-$(date +%Y%m%d).log

# 4. Run integration tests
ssh -i ~/.ssh/ldap-key.pem ec2-user@52.13.60.230 \
  "sudo RUN_LDAP_INTEGRATION_TESTS=1 bash /tmp/script/test/run_all.sh 2>&1"

# 5. Verify LDAP is serving
ssh -i ~/.ssh/ldap-key.pem ec2-user@52.13.60.230 \
  "ldapsearch -x -H ldap://localhost -b dc=eab,dc=bank,dc=local -s base"
```
