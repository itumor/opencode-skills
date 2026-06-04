# OpenLDAP Replication Fix — Bank Deployment

## Summary

Analysis of the slapd logs from `ciamuapplds01.eab.bank.local` (master) covering
May 24 – Jun 03 2026 revealed that **replication was not working**. The replica
attempted to sync from the master 14 times and every attempt was rejected.

This guide provides the fix scripts and explains the issues found.

---

## Issues Found in the Logs

### 1. CRITICAL — Replication Broken (err=13)

**Log evidence:**

```
Jun 03 09:54:37 ciamuapplds01 slapd[510272]: conn=1049 ACCEPT from IP=172.23.11.237
Jun 03 09:54:37 ciamuapplds01 slapd[510272]: conn=1049 op=0 BIND dn="cn=replicator,…" method=128
Jun 03 09:54:37 ciamuapplds01 slapd[510272]: conn=1049 op=0 RESULT err=13 text=confidentiality required
```

This error repeated **14 times** (conn=1049 through conn=1065, and again after
the 10:02 restart). Every syncrepl bind from the replica (172.23.11.237) was
rejected by the master.

**Root cause:** The master was hardened with `olcSecurity: simple_bind=128`
(which requires TLS for all password-based binds). But the replica's syncrepl
configuration was set to `starttls=no` — it was sending the replicator password
in plain text, which the master rejected.

**Fix:** Update the replica's `olcSyncrepl` to use `starttls=yes` with
`tls_reqcert=never` (trust self-signed certs). The `fix-replica.sh` script
does this automatically.

### 2. CRITICAL — TLS Negotiation Failure on Port 636

**Log evidence:**

```
May 24 14:59:07 ciamuapplds01 slapd[510272]: conn=1048 fd=15 closed (TLS negotiation failure)
```

The replica also tried to sync via LDAPS (port 636) and the TLS handshake failed —
likely because the replica does not have the master's CA certificate.

**Fix:** The `starttls=yes` fix on port 389 avoids this entirely. Port 636 is
not required for replication.

### 3. MEDIUM — cn=config Checksum Warning

**Log evidence:**

```
May 24 14:00:50 ciamuapplds01 slapd[510272]: ldif_read_file: checksum error on
"/opt/symas/etc/openldap/slapd.d/cn=config/olcDatabase={0>"
```

This warning appears on every slapd restart. It does not block operation but
indicates a manually-edited LDIF file whose CRC checksum was not updated.
The `fix-master.sh` script rebuilds all cn=config checksums.

### 4. LOW — err=49 (Invalid Credentials)

**Log evidence:**

```
Jun 03 09:54:50 ciamuapplds01 slapd[510272]: conn=1056 op=1 RESULT err=49
```

Someone on the replica machine attempted an admin bind with the wrong password.
This is a client-side issue (check the password used in any script or tool on
the replica that connects as `cn=admin`).

### 5. LOW — err=32 (No Such Object)

**Log evidence:**

```
May 24 14:00:51 ciamuapplds01 slapd[510272]: conn=1038 op=2 RESULT err=32
```

A test attempted to ADD an entry under `ou=people` which does not exist in the
DIT. The correct OU for users is `ou=Users`.

---

## What's Working

Despite the replication issues, the logs confirm these are healthy:

- **TLS encryption:** TLSv1.3, AES-256-GCM, 256-bit security
- **LDAPI (Unix socket):** Root access via EXTERNAL SASL always works
- **Admin StartTLS bind:** Works from localhost
- **mw service account StartTLS:** Works
- **User CRUD operations:** Add, delete, search all succeed
- **Clean shutdowns/restarts:** No crashes

---

## Fix Instructions

### On the MASTER server (172.23.11.236 / ciamuapplds01)

1. Copy `fix-master.sh` to the master server:
   ```
   scp fix-master.sh root@172.23.11.236:/tmp/
   ```

2. SSH to the master and run:
   ```
   ssh root@172.23.11.236
   sudo bash /tmp/fix-master.sh
   ```

3. What `fix-master.sh` does:
   - **Backs up** `/opt/symas/etc/openldap/slapd.d` (timestamped)
   - **Rebuilds** cn=config CRC checksums (fixes the checksum warning)
   - **Adds** `entryUUID` and `entryCSN` database indices (required for sync)
   - **Restarts** slapd
   - **Verifies** LDAPI access and checks logs for errors

4. After the script completes, verify:
   ```
   sudo bash /tmp/verify-master.sh
   ```

### On the REPLICA server (172.23.11.237)

1. Copy `fix-replica.sh` to the replica server:
   ```
   scp fix-replica.sh root@172.23.11.237:/tmp/
   ```

2. SSH to the replica and run:
   ```
   ssh root@172.23.11.237
   sudo bash /tmp/fix-replica.sh
   ```

3. What `fix-replica.sh` does:
   - **Updates** olcSyncrepl to use `starttls=yes tls_reqcert=never`
   - **Loads** the `ppolicy` module (needed so the replica understands
     `pwdPolicy` objects synced from the master)
   - **Restarts** slapd to activate syncrepl with TLS
   - **Verifies** the syncrepl config is correct
   - **Checks logs** for any remaining `err=13` or TLS errors

4. After the script completes, verify:
   ```
   sudo bash /tmp/verify-replica.sh
   ```

### Verification Scripts

After running the fix scripts, use the verification scripts to confirm
everything is clean:

- **`verify-master.sh`** — Run on master. Checks 16 items:
  service status, ports, LDAPI, admin+replicator binds, base DN, syncprov
  overlay, entryUUID/entryCSN indices, and log analysis (err=13, err=49,
  TLS failures, checksum errors).

- **`verify-replica.sh`** — Run on replica. Checks 17 items:
  service status, ports, LDAPI, admin+replicator binds, base DN child count,
  syncrepl starttls=yes, olcUpdateRef, ppolicy module, contextCSN tracking,
  write rejection, and log analysis.

---

## Expected Result After Fix

After running both fix scripts:

- Master **PASS: all checks** with zero log errors
- Replica **PASS: all checks**, syncrepl shows `starttls=yes`
- Within 10 seconds of the replica restart, data from the master syncs to the replica
- All `err=13` (confidentiality required) errors stop
- All TLS negotiation failures stop

To confirm replication is live, add a test entry on the master:

```
sudo LDAPTLS_REQCERT=never ldapadd -x -ZZ -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "<admin_password>" <<'EOF'
dn: cn=repl-test,ou=Groups,dc=eab,dc=bank,dc=local
objectClass: groupOfNames
cn: repl-test
member: cn=admin,dc=eab,dc=bank,dc=local
EOF
```

Then check the replica (wait 10 seconds):

```
sudo LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "<admin_password>" \
  -b "cn=repl-test,ou=Groups,dc=eab,dc=bank,dc=local" -s base dn
```

If the entry appears on the replica, replication is working.

---

## Files Provided

| File | Purpose | Run On |
|------|---------|--------|
| `fix-master.sh` | Fix checksums + syncrepl indices | Master |
| `fix-replica.sh` | Fix syncrepl TLS + load ppolicy module | Replica |
| `verify-master.sh` | Comprehensive master health check | Master |
| `verify-replica.sh` | Comprehensive replica sync check | Replica |
| `BANK_FIX_GUIDE.md` | This document | — |

All scripts require root (`sudo bash <script>.sh`) and have no other dependencies.

---

## Contact

For questions or issues with these scripts, contact the deployment team.
