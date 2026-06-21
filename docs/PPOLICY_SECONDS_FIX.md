# OpenLDAP ppolicy Seconds Fix

## Problem

OpenLDAP `ppolicy` overlay stores time-based values in **seconds**, not days. If values are accidentally configured in days (e.g., `pwdMaxAge: 180` meaning 180 days), the actual expiry becomes 180 seconds (3 minutes) instead of 180 days. Users get locked out almost instantly.

## Script

**`script/28-fix-ppolicy-seconds.sh`** detects and fixes day-based values.

### Detection

| Value range | Interpretation |
|-------------|---------------|
| 0 | Unlimited (no expiry) — skip |
| 1–366 | Days — convert to seconds |
| ≥ 86400 | Already in seconds — skip |
| 367–86399 | Ambiguous — warn and skip |

### Conversion

```
pwdMaxAge:         180 days → 15552000 seconds
pwdExpireWarning:  4 days   → 345600 seconds
pwdMaxAge:         120 days → 10368000 seconds
pwdExpireWarning:  15 days  → 1296000 seconds
```

Formula: `days × 86400 = seconds`

## Usage

### Fresh install (automatic)

`script/28-fix-ppolicy-seconds.sh` runs automatically as part of `install-symas-openldap-all-in-one.sh`, right after `bank-apply-password-policy.sh`. It verifies that all ppolicy time values are in seconds.

### Standalone (fix existing deployment)

```bash
# Run on the master only — policy replicates to replicas via syncrepl
sudo bash script/28-fix-ppolicy-seconds.sh

# With custom base DN and password
sudo BASE_DN=dc=mybank,dc=local ADMIN_PW=secret bash script/28-fix-ppolicy-seconds.sh

# Force conversion of ambiguous values (367-86399)
sudo FORCE_CONVERT=1 bash script/28-fix-ppolicy-seconds.sh
```

### Verify without changing

```bash
# The script is idempotent — if values are already in seconds, it exits 0
sudo bash script/28-fix-ppolicy-seconds.sh
# Output: "Result: No fixes needed — all values are in seconds"
```

## What it does

1. Detects BASE_DN, admin credentials, and policy DN automatically
2. Reads current `pwdMaxAge` and `pwdExpireWarning`
3. Identifies day-based values (1–366)
4. Converts to seconds via ldapmodify
5. Verifies the fix
6. Restarts slapd to apply

## Requirements

- Root access
- Running OpenLDAP with ppolicy overlay loaded
- Policy entry exists at `cn=default,ou=Policies,<base_dn>`
- Symas binaries at `/opt/symas/bin/`

## Related Documentation

- [slapo-ppolicy(5) man page](https://man7.org/linux/man-pages/man5/slapo-ppolicy.5.html)
- `script/bank-apply-password-policy.sh` — applies the full bank password policy
- `docs/PPOLICY_HASH_CLEARTEXT.md` — cleartext hash fix for ppolicy
