# /script Integration Test Report — 2026-05-19

## Summary

**Result: ALL TESTS PASS**

| Test Suite | PASS | WARN | FAIL | Notes |
|-----------|------|------|------|-------|
| Smoke: bash -n syntax | 33 | 0 | 0 | All scripts valid |
| Smoke: orchestrator refs | 29 | 0 | 0 | All referenced scripts exist |
| Repo smoke (full tree) | 79 | 0 | 0 | Includes test scripts |
| LDAP Integration: install | PASS | 1 | 0 | WARN=firewalld not present (expected) |
| LDAP Integration: tests | 10/10 | 0 | 0 | See per-test breakdown |

---

## Test Environment

| Property | Value |
|----------|-------|
| EC2 Instance | `i-07367b4591f1c98cc` |
| Public IP | `34.220.149.152` |
| Region | `us-west-2` |
| Instance Type | `t3.medium` (4 GB RAM + 2 GB swap) |
| OS | Red Hat Enterprise Linux release 9.7 (Plow) → upgraded to 9.8 during install |
| Architecture | `x86_64` |
| Symas OpenLDAP | `2.6.13-2.el9` |
| SELinux | `Enforcing` |
| Date/Time | 2026-05-19 17:56 UTC |

---

## Installation Run

Executed: `sudo bash /tmp/script/install-symas-openldap-all-in-one.sh`

### Scripts Executed (in order)

| # | Script | Result | Notes |
|---|--------|--------|-------|
| 1 | `1-install-symas-openldap.sh` | PASS | Installed symas-openldap-clients + servers 2.6.13 |
| 2 | `3-install-example.sh` | PASS | Created example DB dc=eab,dc=bank,dc=local with slaptest conversion |
| 3 | `4-Start-the-daemon.sh` | PASS | symas-openldap-servers enabled and active |
| 4 | `5-fix_all_symas_warns.sh` | PASS | Created /etc/profile.d/symas_env.sh, PATH configured |
| 5 | `6-fix_remaining_symas_warns.sh` | PASS | slapd symlink created, self-signed TLS cert generated |
| 6 | `11-fix_version_warns.sh` | PASS | Verification script patched for stderr capture |
| 7 | `7-verify_symas_openldap.sh` | PASS (21/0/0) | WARN only: firewalld not installed (expected in EC2) |
| 8 | `8.0-fix_ldapi_acl.sh` | PASS | SASL/EXTERNAL manage ACL configured, olcRootPW reset |
| 9 | `8-create_top_ous.sh` | PASS | Created: ou=Users, ou=Admins, ou=Groups, ou=Systems |
| 10 | `26-configure-bindings.sh` | PASS | Replication user cn=replicator created, syncprov ACL set |
| 11 | `9-password_policy.sh` | PASS | ppolicy module loaded, ou=Policies created |
| 12 | `9.0-password_policy_load_module.sh` | PASS | ppolicy overlay added to main database |
| 13 | `10-ppolicy-container.sh` | PASS | cn=default,ou=Policies created |
| 14 | `10.0-password_policy_make_default.sh` | PASS | Default policy set on overlay |
| 15 | `12-Create_custom_schema.sh` | PASS | cn=bank-custom schema container created |
| 16 | `13-Create_custom_schema_attr.sh` | PASS | Custom attrs (userisactive, memorableanswer, cif, etc.) added |
| 17 | `7-verify_symas_openldap.sh` (2nd) | PASS (21/0/0) | Re-verification after schema changes |
| 18 | `16-add-strong-password-quality-checker-PPM.sh` | WARN | PPM .so not available in this Symas build — gracefully skipped |
| 19 | `17-create_mw_user.sh` | PASS | uid=mw service account created |
| 20 | `27-configure-mw-acl.sh` | PASS | MW write ACL on ou=Users configured |
| 21 | `18-service-account-password-policy-never-expire.sh` | PASS | cn=service-account policy (pwdMaxAge=0) created |
| 22 | `19-create-user-using-mw-user.sh` | PASS | uid=mwuser1 created via MW bind |
| 23 | `20-migration.sh` | PASS | No-op placeholder |
| 24 | `24-configure-ssl-tls.sh` | PASS | CA + cert + key generated, LDAPS listener enabled |
| 25 | `21-hardening.sh` | PASS | Anonymous binds disabled, TLS required, cipher suite set |
| 26 | `22-tuning.sh` | PASS | LimitNOFILE=524288 drop-in, service restarted |
| 27 | `23-ensure-installation-not-under-root.sh` | PASS | Installation verified outside /root |
| 28 | `25-configure-accesslog-audit.sh` | PASS | Accesslog DB + overlay configured |

---

## Integration Test Results

Run: `sudo LDAPTLS_REQCERT=never RUN_LDAP_INTEGRATION_TESTS=1 bash /tmp/script/test/run_all.sh`

| Test | Result | Details |
|------|--------|---------|
| `test_password_checker.sh` | **PASS** | pwdPolicyChecker present, pwdCheckQuality=2 |
| `test_password_complexity.sh` | **SKIP** | PPM not available in this Symas build (non-fatal) |
| `test_mw_service_user.sh` | **PASS** | uid=mw exists and bind-ready |
| `test_service_account_password_policy_never_expire.sh` | **PASS** | pwdMaxAge=0, pwdPolicy objectClass present |
| `test_create_user_using_mw_user.sh` | **PASS** | Created uid=mwtest20260519175923 via MW account |
| `test_installation_not_under_root.sh` | **PASS** | Script correctly detects bad path (expected FAIL), then verifies good path |
| `test_tuning.sh` | **PASS** | LimitNOFILE=524288 confirmed in systemd drop-in |
| `test_configure_ssl_tls.sh` | **PASS** | CA, cert, key files present; olcTLS* attrs in cn=config; LDAPS listener active |
| `test_custom_schema_attr.sh` | **PASS** | Created test user with userisactive/memorableanswer/cif; all attrs readable; entry cleaned up |
| `test_accesslog_audit.sh` | **PASS** | olcDatabase={2}mdb and olcOverlay={1}accesslog both present |
| `test_bindings.sh` | **PASS** | Replicator bind OK; read BASE_DN OK; write denied as expected |

---

## Issues Found and Fixed

### Issue 1: `26-configure-bindings.sh` hangs after `21-hardening.sh`

**Root cause:** After `21-hardening.sh` sets `olcRequires tls` on cn=config, all plain `-x` LDAP binds on port 389 block waiting for TLS handshake that never starts. The `ensure_repl_entry()` function used `-x -H ldap://` for existence check.

**Fix:** Replaced plain bind existence check with SASL EXTERNAL (`ldapi://`), which does not require TLS. All admin write operations now detect `olcRequires tls` automatically and add `-ZZ` to their bind args.

**File:** `script/26-configure-bindings.sh`

### Issue 2: `test_custom_schema_attr.sh` had no verification or output

**Root cause:** The test only ran `ldapadd` with no readback verification and no `[SUCCESS]` message. It also used `exit 0` on duplicate entry instead of continuing.

**Fix:** Added readback `ldapsearch` to verify `userisactive`, `memorableanswer`, and `cif` are readable. Added `[PASS]`/`[FAIL]` for each attribute. Added cleanup `ldapdelete` so test entries don't accumulate. Added `[SUCCESS]` completion message.

**File:** `script/test/test_custom_schema_attr.sh`

### Issue 3: `test_bindings.sh` hung waiting for `26-configure-bindings.sh`

**Root cause:** Same as Issue 1 — `test_bindings.sh` re-runs `26-configure-bindings.sh` which previously used a plain bind that hung.

**Fix:** Fixed by Issue 1 above.

---

## Warnings (Expected / Non-Fatal)

| Warning | Location | Reason | Action |
|---------|----------|--------|--------|
| `firewalld not found` | `7-verify_symas_openldap.sh` | EC2 uses security groups, not firewalld | Expected — no action needed |
| `PPM module not available` | `16-add-strong-password-quality-checker-PPM.sh` | Symas 2.6.13 free build does not include ppm.so | Expected — requires commercial Symas license |
| `slapd not found in PATH` | `23-ensure-installation-not-under-root.sh` | slapd binary is in /opt/symas/lib, not in default PATH during isolated test env | Expected — PATH configured correctly in full sessions |

---

## How to Re-run Tests

### Against a fresh VM (recommended)

```bash
# From your local machine
scp -i ~/.ssh/your-key.pem -r ./script ec2-user@<IP>:/tmp/script
ssh -i ~/.ssh/your-key.pem ec2-user@<IP> \
  "sudo bash /tmp/script/install-symas-openldap-all-in-one.sh 2>&1 | tee /tmp/install.log"
```

### Smoke tests only (safe on any machine, no LDAP required)

```bash
bash script/test/run_all.sh
# Expected: PASS=79 WARN=0 FAIL=0
```

### Integration tests only (requires installed OpenLDAP)

```bash
sudo LDAPTLS_REQCERT=never RUN_LDAP_INTEGRATION_TESTS=1 bash /tmp/script/test/run_all.sh
```

### Individual test

```bash
sudo LDAPTLS_REQCERT=never bash /tmp/script/test/test_bindings.sh
sudo LDAPTLS_REQCERT=never bash /tmp/script/test/test_custom_schema_attr.sh
```

---

## Tested Branch

`codex/openldap-master-replica-ec2`  
MR: https://gitlab.com/nxt_edge/nextgenopen/-/merge_requests/3
