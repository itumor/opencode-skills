# Bank OpenLDAP Password Policy — Deployment Guide

## Overview

This package applies the comprehensive password policy to the Bank OpenLDAP deployment (Symas OpenLDAP 2.6.13 on RHEL 9).

### What the script does (12 steps)

| Step | Action | Detail |
|------|--------|--------|
| 1 | Loads ppolicy module | `ppolicy.la` in `cn=module{0},cn=config` |
| 2 | Ensures ppolicy overlay | On the active MDB database |
| 3 | Locates overlay DN | Dynamically finds `olcOverlay={N}ppolicy` |
| 4 | Creates Policies OU | `ou=Policies,dc=eab,dc=bank,dc=local` if missing |
| 5 | Creates/updates policy entry | `cn=default,ou=Policies` with all bank attributes |
| 6 | Sets as default | `olcPPolicyDefault` on the overlay + `olcPPolicyUseLockout: TRUE` |
| 7 | Loads PPM module | `ppm.so` if available (licensed Symas); gracefully skips if not |
| 8 | Wires PPM | Sets `olcPPolicyCheckModule: ppm` (if PPM available) |
| 9 | Writes PPM config | `/opt/symas/etc/openldap/ppm.conf` with all complexity rules |
| 10 | Registers config | `olcPpmConfigFile` in `cn=config` |
| 11 | Enables enforcement | Adds `pwdPolicyChecker` objectClass to policy |
| 12 | Restarts slapd | Applies all changes + runs verification |

### Policy Enforcement Summary

| Rule | Value | Mechanism |
|------|-------|-----------|
| Min password length | 8 | `pwdMinLength: 8` + PPM `minLength 8` |
| Max password length | 12 | PPM `maxLength 12` |
| At least 1 uppercase | Required | PPM `minUpper 1` |
| At least 1 lowercase | Required | PPM `minLower 1` |
| At least 1 digit | Required | PPM `minDigit 1` |
| Special characters | Only `_` (underscore) | PPM `specialChars _`, `minSpecial 0` |
| Arabic letters | **Blocked** | PPM `forbiddenChars` + unicode blocks (requires PPM) |
| Username in password | Rejected (forward + reverse) | PPM `rejectUsername true` |
| Password expiry | 4 months (120 days) | `pwdMaxAge: 10368000` |
| Expiry warning | 15 days before | `pwdExpireWarning: 1296000` |
| Account lockout | After 5 failed attempts | `pwdMaxFailure: 5`, `pwdLockout: TRUE` |
| Lockout duration | 30 minutes | `pwdLockoutDuration: 1800` |
| Password history | Last 5 cannot be reused | `pwdInHistory: 5` + PPM `historySize 5` |
| Banned characters | `' " ( ) { } [ ] / \ = @ # $ % ! . -` | PPM `forbiddenChars` |
| Grace authentications | 3 after expiry | `pwdGraceAuthNLimit: 3` |

## PPM (Password Policy Module) Note

The advanced complexity checks (maxLength, minUpper, minLower, specialChars, forbiddenChars, rejectUsername) require the **Symas PPM module**. This is a licensed component of Symas OpenLDAP.

**If PPM is NOT available** (community edition lab):
- LDAP-level attributes still apply: `pwdMaxAge`, `pwdMinLength`, `pwdMaxFailure`, `pwdInHistory`, `pwdLockout`, `pwdCheckQuality`
- PPM-specific checks are skipped gracefully (script logs warnings)
- The script exits with `PASS with warnings` (not failure)

**If PPM IS available** (licensed Symas):
- All 12 rules are enforced
- The script writes `/opt/symas/etc/openldap/ppm.conf` with full configuration

## How to Apply

### Option A: Standalone script (existing deployment)

```bash
# Copy to server and run as root
scp bank-apply-password-policy.sh root@172.23.11.236:/tmp/
ssh root@172.23.11.236 "sudo bash /tmp/bank-apply-password-policy.sh"
```

Only needs to run on the **MASTER**. Policy data replicates to the replica via syncrepl.

### Option B: Integrated with full master install

The script is integrated into `install-symas-openldap-all-in-one.sh`. It runs automatically after `16-add-strong-password-quality-checker-PPM.sh`.

```bash
# Full master install (script auto-runs bank-apply-password-policy.sh at the end)
sudo TLS_MODE=yes bash install-symas-openldap-all-in-one.sh
```

## Verification

After running, verify the policy is applied:

```bash
# On master
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapsearch -o ldif-wrap=no -x -ZZ \
  -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  -b "cn=default,ou=Policies,dc=eab,dc=bank,dc=local" -s base \
  pwdMaxAge pwdMinLength pwdMaxFailure pwdInHistory pwdCheckQuality \
  pwdExpireWarning pwdLockout pwdLockoutDuration

# Expected output:
# pwdMaxAge: 10368000
# pwdExpireWarning: 1296000
# pwdInHistory: 5
# pwdCheckQuality: 2
# pwdMinLength: 8
# pwdMaxFailure: 5
# pwdLockout: TRUE
# pwdLockoutDuration: 1800
```

On replica (should match via replication):
```bash
sudo /opt/symas/bin/ldapsearch -o ldif-wrap=no -x -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  -b "cn=default,ou=Policies,dc=eab,dc=bank,dc=local" -s base \
  pwdMaxAge pwdMinLength pwdMaxFailure pwdInHistory
```

## PPM Configuration Reference

When PPM is available, the config file at `/opt/symas/etc/openldap/ppm.conf` contains:

```ini
minLength 8
maxLength 12
minUpper  1
minLower  1
minDigit  1
minSpecial 0
specialChars _
historySize 5
maxRepeat 2
rejectUsername true
forbiddenChars '"(){}[]/\=@#$%!.-
forbiddenWords admin password bank welcome root eabadm
```

## Files in this Package

| File | Purpose |
|------|---------|
| `bank-apply-password-policy.sh` | Main script — applies all policy rules |
| `BANK_PASSWORD_POLICY.md` | This file |
| `install-symas-openldap-all-in-one.sh` | Master orchestrator (updated with policy step) |
| `install-symas-openldap-replica-all-in-one.sh` | Replica orchestrator (updated with PPM module) |
