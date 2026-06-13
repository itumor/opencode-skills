# PPM + ACL + orclisenabled Fix — Bank Deployment

## Summary

Two standalone scripts to fix specific issues found in the EAB bank OpenLDAP
master/replica deployment. Both are idempotent — safe to run multiple times.
Auto-detect master vs replica and apply only the relevant fixes.

| Script | Fixes | Run On |
|--------|-------|--------|
| `bank-fix-ppm-acl.sh` | PPM password quality + r6 LDAPI ACL | Both servers |
| `bank-add-orclisenabled.sh` | orclisenabled custom attribute schema | Both servers |

---

## Prerequisites

- Root access on both master and replica
- `ldapsearch` and `ldapmodify` available (Symas OpenLDAP 2.6.x)
- LDAPI EXTERNAL bind working (`sudo ldapwhoami -Y EXTERNAL -H ldapi:///`)
- Scripts must be copied to both servers (e.g., via jump host)

### Bank Environment

| Role | IP | Hostname |
|------|-----|----------|
| Master | 172.23.11.236 | ciamuapplds01 |
| Replica | 172.23.11.237 | ciamuapplds02 |
| Jump | 172.23.11.10 | — |

Admin DN: `cn=admin,dc=eab,dc=bank,dc=local`
Replicator DN: `cn=replicator,dc=eab,dc=bank,dc=local`

---

## Script 1: bank-fix-ppm-acl.sh

### What it fixes

1. **PPM password quality** (master only):
   - Verifies `ppm.so` exists at `/opt/symas/lib/openldap/ppm.so`
   - Creates `/opt/symas/etc/openldap/ppm.conf` with password rules:
     - Minimum 12 characters, 1 uppercase, 1 lowercase, 1 digit, 1 special
     - 5 password history, max 2 repeated chars
     - Rejects username as password, forbids "admin", "password", "bank", "welcome"
   - Sets `pwdCheckQuality=2` on `cn=default,ou=Policies,dc=eab,dc=bank,dc=local`
   - Note: Symas `ppm.so` lacks `.la` (libtool archive) — `olcPPolicyCheckModule=ppm`
     may not load, but password quality is enforced via `pwdCheckQuality=2` + `ppm.conf`

2. **r6 LDAPI ACL** (both servers):
   - Verifies SASL/EXTERNAL has `manage` access to `cn=config`
   - If missing, performs offline repair: stops slapd, patches config LDIF, restarts
   - Tests `ldapmodify` via ldapi after repair

### Run on master

```bash
# Copy script to master via jump host
scp bank-fix-ppm-acl.sh root@172.23.11.236:/tmp/

# SSH to master
ssh root@172.23.11.236

# Run (idempotent — safe to repeat)
sudo bash /tmp/bank-fix-ppm-acl.sh
```

### Run on replica

```bash
# Copy script to replica via jump host
scp bank-fix-ppm-acl.sh root@172.23.11.237:/tmp/

# SSH to replica
ssh root@172.23.11.237

# Run (idempotent — safe to repeat)
sudo bash /tmp/bank-fix-ppm-acl.sh
```

### Expected output

```
======= BANK FIX — PPM + r6 ACL =======
...
=== Fix 1: PPM module ===
[ OK ] ppm.so present at /opt/symas/lib/openldap/ppm.so
[ OK ] Written /opt/symas/etc/openldap/ppm.conf
[ OK ] Set pwdCheckQuality=2

=== Fix 2: r6 LDAPI ACL ===
[ OK ] LDAPI manage ACL present on olcDatabase={0}config,cn=config
[ OK ] ldapmodify via ldapi works — ACL is functional

========== BANK FIX — Complete ==========
PASS=5  FAIL=0  WARN=0
```

On replica: PASS count is lower (~3) because PPM config is skipped (replica is read-only).

### Dry run (check-only mode)

```bash
sudo PPM_DRY_RUN=1 bash /tmp/bank-fix-ppm-acl.sh
```

### Verify after running

```bash
# 1. Check ppm.conf exists (master)
sudo cat /opt/symas/etc/openldap/ppm.conf

# 2. Check pwdCheckQuality (master)
sudo ldapsearch -x -ZZ -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w <admin_password> \
  -b "cn=default,ou=Policies,dc=eab,dc=bank,dc=local" -s base pwdCheckQuality \
  -o ldif-wrap=no
# Expected: pwdCheckQuality: 2

# 3. Verify LDAPI ACL (both servers)
sudo ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b "cn=config" -LLL '(olcDatabase=config)' olcAccess -o ldif-wrap=no \
  | grep -i manage
# Expected: must contain "manage"

# 4. Test ldapmodify via ldapi (both)
sudo ldapmodify -Y EXTERNAL -H ldapi:/// <<'TEST'
dn: cn=config
changetype: modify
replace: olcLogLevel
olcLogLevel: 0
TEST
# Expected: modifying entry "cn=config"

# 5. Check slapd logs for errors (both)
sudo journalctl -u symas-openldap-servers --no-pager --since "5 minutes ago" \
  | grep -iE "err=|fail|TLS" || echo "No errors found"
```

### Troubleshooting

| Symptom | Check |
|---------|-------|
| "LDAPI EXTERNAL failed" | Run as root. Check socket: `ls -la /var/symas/run/ldapi` |
| "ppm.so not found" | `rpm -ql symas-openldap-servers \| grep ppm` |
| ACL repair fails | Manually check: `sudo cat /opt/symas/etc/openldap/slapd.d/cn=config/olcDatabase={0}config.ldif` |
| Slapd won't start after ACL repair | Restore from backup, run script again, check `journalctl -xe` |

---

## Script 2: bank-add-orclisenabled.sh

### Why this matters

Some bank entries include the attribute `orclisenabled: TRUE` (OID 1.3.6.1.4.1.55555.1.16).
If the `orclisenabled` attribute type is not defined in the `bank-custom` schema,
the replica will fail syncrepl with:

> `objectClass: value #0 invalid per syntax`

This script adds the attribute and includes it in the `bankUserExtension`
object class MAY list so replication succeeds.

**Run on BOTH master and replica** — cn=config schema changes do not replicate via syncrepl.

### What it does

1. Locates the `bank-custom` schema in `cn=config`
2. Adds `olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.16 NAME 'orclisenabled' DESC 'Oracle enabled flag' EQUALITY booleanMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.7 SINGLE-VALUE )`
3. Updates `bankUserExtension` MAY list to include `orclisenabled`
4. Idempotent — checks if attribute already exists before acting

### Run on master

```bash
# Copy script to master
scp bank-add-orclisenabled.sh root@172.23.11.236:/tmp/

# SSH and run
ssh root@172.23.11.236
sudo bash /tmp/bank-add-orclisenabled.sh
```

### Run on replica

```bash
# Copy script to replica
scp bank-add-orclisenabled.sh root@172.23.11.237:/tmp/

# SSH and run
ssh root@172.23.11.237
sudo bash /tmp/bank-add-orclisenabled.sh
```

### Expected output

```
====== ADD orclisenabled ATTRIBUTE ======
  OID:    1.3.6.1.4.1.55555.1.16
  Schema: bank-custom
=========================================

=== Step 1: Locate schema ===
[ OK ] Schema DN: cn={X}bank-custom,cn=schema,cn=config

=== Step 2: Check current state ===
[INFO]  Attribute 'orclisenabled' not found — will add

=== Step 3: Add attribute type ===
[ OK ] Added attribute type: orclisenabled (1.3.6.1.4.1.55555.1.16)

=== Step 4: Update bankUserExtension MAY list ===
[ OK ] Updated bankUserExtension MAY list — added orclisenabled

=== Step 5: Verify ===
[ OK ] Attribute 'orclisenabled' present in schema
[ OK ] 'orclisenabled' referenced in object class

====== ADD orclisenabled — Complete =====
```

### Dry run (check-only mode)

```bash
sudo DRY_RUN=1 bash /tmp/bank-add-orclisenabled.sh
```

### Verify after running

```bash
# 1. Check attribute exists in schema (master)
sudo ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b "cn=schema,cn=config" -s sub "(cn=*bank-custom*)" \
  olcAttributeTypes -o ldif-wrap=no | grep orclisenabled

# 2. Wait 30 seconds and check replica received schema
# (on replica)
sudo ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b "cn=schema,cn=config" -s sub "(cn=*bank-custom*)" \
  olcAttributeTypes -o ldif-wrap=no | grep orclisenabled

# 3. Test using the attribute (master)
sudo ldapmodify -x -ZZ -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w <admin_password> <<'TEST'
dn: uid=testuser,ou=People,dc=eab,dc=bank,dc=local
changetype: modify
add: orclisenabled
orclisenabled: TRUE
TEST

# 4. Check replica logs — should NOT show "objectClass: value #0 invalid"
sudo journalctl -u symas-openldap-servers --no-pager --since "5 minutes ago" \
  | grep -i "orclisenabled\|invalid per syntax" || echo "No errors"
```

### Troubleshooting

| Symptom | Check |
|---------|-------|
| "Schema bank-custom not found" | Run `12-Create_custom_schema.sh` first. Check: `sudo ldapsearch -Y EXTERNAL -H ldapi:/// -b "cn=schema,cn=config" -s sub "(objectClass=olcSchemaConfig)" cn` |
| "Failed to add attribute type" | Check slapd logs: `sudo journalctl -u symas-openldap-servers --no-pager -n 20` |
| Replica still shows "invalid per syntax" | Check if schema replicated: verify step 2 above. Restart replica: `sudo systemctl restart symas-openldap-servers` |

---

## Execution Order

1. **Master first**: Run `bank-fix-ppm-acl.sh` then `bank-add-orclisenabled.sh`
2. **Wait 30 seconds** for syncrepl to propagate schema changes
3. **Replica**: Run `bank-fix-ppm-acl.sh`

---

## Rollback

Both scripts are idempotent and non-destructive. To rollback:

- **PPM**: Delete `/opt/symas/etc/openldap/ppm.conf`. Revert `pwdCheckQuality` to previous value.
- **ACL**: The script only adds the `manage` ACL if missing. No rollback needed.
- **orclisenabled**: Schema changes via `olcAttributeTypes`/`olcObjectClasses` are append-only. To remove, use `ldapmodify` with `delete:` modifier on the schema entry.

No service restart is required after rollback.
