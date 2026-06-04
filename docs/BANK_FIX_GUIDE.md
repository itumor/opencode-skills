# OpenLDAP Replication Fix — Bank Deployment

## Summary

Analysis of slapd logs from `ciamuapplds01` (master, May 24–Jun 03 2026) found
that **replication was not working**. The replica attempted to sync 14 times
and every attempt was rejected with `err=13 confidentiality required`.

This guide provides four scripts to fix and verify both servers.

---

## Issues Found in Logs

### Critical — Replication Broken (err=13 x14)

```
Jun 03 09:54:37 ciamuapplds01 slapd: conn=1049 op=0 BIND dn="cn=replicator,…"
Jun 03 09:54:37 ciamuapplds01 slapd: conn=1049 op=0 RESULT err=13 text=confidentiality required
```

Same error repeated 14 times. The master was hardened to require TLS
(`olcSecurity: simple_bind=128`) but the replica was still configured to send
the replicator password in plain text (`starttls=no` in olcSyncrepl).

### Medium — LDAPS 636 TLS Failure

```
May 24 14:59:07 ciamuapplds01 slapd: conn=1048 fd=15 closed (TLS negotiation failure)
```

Replica tried direct LDAPS on port 636 — TLS handshake failed.

### Low — cn=config Checksum Warning

```
May 24 14:00:50 ciamuapplds01 slapd: ldif_read_file: checksum error on
  "/opt/symas/etc/openldap/slapd.d/cn=config/olcDatabase={0…"
```

Appears on every slapd restart. A manually-edited config file has a stale CRC.

---

## What's Working (Good)

- TLS encryption: TLSv1.3, AES-256-GCM, ssf=256
- LDAPI EXTERNAL: all binds work
- Admin/service-account StartTLS binds: all work
- User CRUD operations: add/delete/search succeed
- Clean shutdowns and restarts

---

## Fix Instructions

All scripts run directly on the server as root. No external dependencies.

### On the MASTER server (172.23.11.236 / ciamuapplds01)

**Step 1 — Copy fix-master.sh to the server:**
```
scp fix-master.sh root@172.23.11.236:/tmp/
```

**Step 2 — Run the fix:**
```
ssh root@172.23.11.236
sudo bash /tmp/fix-master.sh
```

What it does:
- Backs up /opt/symas/etc/openldap/slapd.d
- Exports cn=config via slapcat, rebuilds checksums via slapadd
- Adds entryUUID and entryCSN database indices (required for syncrepl)
- Restarts slapd and self-verifies

**Step 3 — Verify:**
```
sudo ADMIN_PW='TheN1le1' bash /tmp/verify-master.sh
```

### On the REPLICA server (172.23.11.237)

**Step 1 — Copy fix-replica.sh to the server:**
```
scp fix-replica.sh root@172.23.11.237:/tmp/
```

**Step 2 — Run the fix:**
```
ssh root@172.23.11.237
sudo bash /tmp/fix-replica.sh
```

What it does:
- Updates olcSyncrepl to use starttls=yes tls_reqcert=never
- Loads ppolicy module (pwdPolicy objectClass)
- Generates self-signed TLS certificates if missing
- Restarts slapd and verifies config + logs

**Step 3 — Verify:**
```
sudo ADMIN_PW='TheN1le1' bash /tmp/verify-replica.sh
```

---

## Verification Script Checks

### verify-master.sh (16 checks)

| Check | What It Verifies |
|-------|-----------------|
| Service status | symas-openldap-servers is active |
| Port 389/636 | Both ports listening |
| LDAPI EXTERNAL | Root socket access works |
| Admin StartTLS | Admin password bind via TLS |
| Replicator StartTLS | Replicator password bind via TLS |
| Base DN readable | Directory root accessible |
| Child count | Correct number of OUs |
| Syncprov overlay | Configured on master |
| entryUUID index | Present |
| entryCSN index | Present |
| No err=13 | Zero confidentiality errors |
| No err=49 | Zero invalid credentials |
| No TLS failures | Zero TLS handshake errors |
| No checksum errors | Zero CRC mismatches |
| contextCSN | CSN tracking active |

### verify-replica.sh (17 checks)

| Check | What It Verifies |
|-------|-----------------|
| Service status | symas-openldap-servers is active |
| Port 389 | Listening |
| LDAPI EXTERNAL | Root socket access works |
| Admin StartTLS | Admin password bind via TLS |
| Replicator StartTLS | Replicator password bind via TLS |
| Base DN readable | Directory root accessible |
| Child count | Matches master child count |
| DN list | Shows all synced OUs |
| Syncrepl starttls | starttls=yes in config |
| olcUpdateRef | Write redirect to master configured |
| ppolicy module | Loaded |
| contextCSN | CSN tracking active + matches master |
| No err=13 | Zero confidentiality errors |
| No TLS failures | Zero TLS handshake errors |
| No checksum errors | Zero CRC mismatches |
| Write rejection | Read-only properly enforced |

---

## Expected Results

After running both fix scripts:

| Metric | Master | Replica |
|--------|--------|---------|
| Service | active | active |
| ERR=13 | 0 | 0 |
| ERR=49 | 0 | 0 |
| Checksum errors | 0 | 0 |
| TLS failures | 0 | 0 |
| Entries | matched | matched |
| contextCSN | present | matches master |
| E2E write | creates on master | replicated in <10s |

---

## Confirming Replication

Add a test entry on the master and check it appears on the replica:

**On master:**
```
sudo LDAPTLS_REQCERT=never ldapadd -x -ZZ -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" <<'EOF'
dn: cn=test-replication,ou=Groups,dc=eab,dc=bank,dc=local
objectClass: groupOfNames
cn: test-replication
member: cn=admin,dc=eab,dc=bank,dc=local
EOF
```

**Wait 10 seconds, then on replica:**
```
sudo LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  -b "cn=test-replication,ou=Groups,dc=eab,dc=bank,dc=local" -s base dn
```

The entry should appear on the replica.

---

## Files Provided

| File | Run On | Purpose |
|------|--------|---------|
| `fix-master.sh` | Master (172.23.11.236) | Fix checksums + syncrepl indices |
| `fix-replica.sh` | Replica (172.23.11.237) | Fix syncrepl TLS + ppolicy + TLS certs |
| `verify-master.sh` | Master (172.23.11.236) | 16-point health check |
| `verify-replica.sh` | Replica (172.23.11.237) | 17-point sync verification |
| `BANK_FIX_GUIDE.md` | — | This document |

All scripts: `sudo bash <script>.sh`

---

## Troubleshooting

**"FATAL: Run as root"** — use `sudo`

**"ldapmodify: command not found"** — source the Symas environment first:
```
source /etc/profile.d/symas_env.sh
```
Or use the full path: `/opt/symas/bin/ldapmodify`

**Admin password wrong** — pass it explicitly:
```
sudo ADMIN_PW='<your_password>' bash verify-master.sh
```

**Replica contextCSN doesn't match** — run fix-replica.sh again and wait 30
seconds for syncrepl to complete the initial sync.
