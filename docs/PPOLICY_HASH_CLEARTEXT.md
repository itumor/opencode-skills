# olcPPolicyHashCleartext — Enable Password Hashing

## What it does

Sets `olcPPolicyHashCleartext: TRUE` on the ppolicy overlay, so slapd hashes
cleartext passwords before storing them in the database.

Without this, passwords sent in cleartext over a TLS channel are stored as-is
(raw cleartext). With it enabled, the server hashes them server-side using
the configured hash scheme (SSHA by default).

Reference: https://www.openldap.org/lists/openldap-technical/201708/msg00024.html

## Script

**`bank-add-ppolicy-hash-cleartext.sh`** — standalone idempotent script.

### Usage

```bash
# Apply (with backup + confirmation)
sudo bash bank-add-ppolicy-hash-cleartext.sh

# CI/automation mode
sudo bash bank-add-ppolicy-hash-cleartext.sh --force

# Preview only
sudo bash bank-add-ppolicy-hash-cleartext.sh --dry-run

# Rollback
sudo bash bank-add-ppolicy-hash-cleartext.sh --restore /var/symas/openldap-data/backup/ppolicy-overlay-*.ldif
```

### What it does

1. Locates the ppolicy overlay entry in cn=config
2. Backs up the overlay entry before modification
3. Checks current state (skips if already TRUE)
4. Adds/modifies `olcPPolicyHashCleartext: TRUE`
5. Verifies the change

### Requirements

- Must run as root
- slapd must be running
- LDAPI EXTERNAL access must work
- ppolicy overlay must exist on the database

### Integration

Integrated into both all-in-one installers:
- Master: `install-symas-openldap-all-in-one.sh` (after password policy script)
- Replica: `install-symas-openldap-replica-all-in-one.sh` (after ppolicy module + overlay)

## Verification

```bash
# Check cn=config
sudo ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b 'olcOverlay={1}ppolicy,olcDatabase={1}mdb,cn=config' \
  -s base -LLL olcPPolicyHashCleartext
# Expected: olcPPolicyHashCleartext: TRUE

# Functional test: add a user, verify stored password is hashed
LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  -b "uid=testuser,ou=Users,dc=eab,dc=bank,dc=local" userPassword
# Should show {SSHA}... not cleartext
```

## Test Results (AWS lab, 2026-06-16)

| Node | IP | Overlay DN | Result |
|------|----|-----------|--------|
| Master | 54.186.123.12 | olcOverlay={1}ppolicy,olcDatabase={1}mdb,cn=config | Pass: 2, Fail: 0 |
| Replica | 44.243.198.216 | olcOverlay={0}ppolicy,olcDatabase={1}mdb,cn=config | Pass: 2, Fail: 0 |

Idempotent re-run: both nodes correctly detect "already TRUE" and skip.

## Important Notes

- The ppolicy overlay entry is in cn=config (NOT replicated via syncrepl). Both
  master and replica need this set independently.
- On replica, the ppolicy overlay must be created first (via `ldapadd` as child entry),
  not via `ldapmodify add: olcOverlay` (object class violation on some Symas builds).
  The replica installer handles this.
- `olcPPolicyHashCleartext` only affects how slapd processes incoming bind/add
  operations with cleartext passwords. Existing hashed passwords are unaffected.
