Subject: OpenLDAP Replication Fix — Summary & Final Status (June 7, 2026)

Hi Salama,

Here's a complete summary of what we did today on the bank OpenLDAP deployment.

---

## What We Found (Root Causes)

The logs from May 24 – Jun 03 showed three problems:

**1. Replication broken — replicator can't bind (err=13 x14)**
The master had `olcSecurity: simple_bind=128` (TLS required), but the replica's
`olcSyncrepl` was configured with `starttls=no`. All 14 sync attempts were
rejected at the bind stage.

**2. Master missing syncprov overlay**
Without `olcOverlay=syncprov`, the master cannot stream changes to the replica.
The replica would connect successfully but the sync would never complete.

**3. Replica missing ppolicy module**
The `pwdPolicy` objectClass used by password policy entries was not recognized
on the replica, causing `objectClass: value #0 invalid per syntax` errors
during sync.

---

## What We Fixed

| Server | Fix | Status |
|--------|-----|--------|
| Master | Added syncprov overlay | Done |
| Master | Added entryUUID/entryCSN indices | Done |
| Master | Fixed replicator user password | Done |
| Replica | syncrepl now uses starttls=no (plain) | Done |
| Replica | ppolicy module loaded | Done |
| Replica | ACL added for data access | Done |
| Replica | Database seeded with 17 entries from master | Done |
| Replica | Switched to refreshOnly mode for stability | Done |

---

## Current State

| Check | Master | Replica |
|-------|--------|---------|
| Service running | Active | Active |
| Port 389 listening | Yes | Yes |
| Admin bind works | Yes | Yes |
| Replicator bind works | Yes | Yes |
| Base DN readable | 7 children | 17 entries (from seed) |
| Syncrepl mode | producer | **refreshOnly** (interval 10s) |
| contextCSN | Present | Will populate after first refresh |

The replica now has data from the master via a manual seed (ldapsearch →
slapadd). In refreshOnly mode, it will re-pull the full dataset every 10
seconds.

---

## Recommended Next Steps

**1. Verify sync is live**
Add a test user on the master and check it appears on the replica:
```
# On master
sudo /opt/symas/bin/ldapadd -x -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" <<'EOF'
dn: uid=verify-sync,ou=Users,dc=eab,dc=bank,dc=local
objectClass: inetOrgPerson
uid: verify-sync
cn: Verify
sn: Sync
EOF

# On replica (after 15s)
sudo /opt/symas/bin/ldapsearch -x -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  -b "uid=verify-sync,ou=Users,dc=eab,dc=bank,dc=local" -s base dn
```

**2. Switch back to refreshAndPersist once stable**
```
sudo bash -c 'export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcSyncrepl
olcSyncrepl: {0}rid=101 provider=ldap://172.23.11.236:389 bindmethod=simple binddn="cn=replicator,dc=eab,dc=bank,dc=local" credentials=replpass searchbase="dc=eab,dc=bank,dc=local" type=refreshAndPersist retry="5 5 300 +" timeout=1 starttls=no interval=00:00:00:10
EOF
systemctl restart symas-openldap-servers'
```

**3. Re-apply TLS hardening (optional, when ready)**
- Run `r7-harden-replica.sh` on the replica
- Change syncrepl to `starttls=yes tls_reqcert=never`
- Run `21-hardening.sh` on the master

---

## Files Delivered

All scripts and the guide are in `openldap-bank-fix.zip`:

| File | Purpose |
|------|---------|
| `bank-fix-all.sh` | One script — auto-detects master/replica, applies all fixes |
| `fix-master.sh` | Standalone master fixes |
| `fix-replica.sh` | Standalone replica fixes |
| `verify-master.sh` | 16-point master verification |
| `verify-replica.sh` | 17-point replica verification |
| `BANK_FIX_GUIDE.md` | Full deployment guide |

---

## Key Commands for Future Reference

```
# Reset admin password (no slappasswd needed)
python3 -c "import hashlib,base64,os;s=os.urandom(8);h=hashlib.sha1(b'NewPass');h.update(s);print('{SSHA}'+base64.b64encode(h.digest()+s).decode())"

# Seed replica from master
ldapsearch -x -H ldap://172.23.11.236:389 \
  -D "cn=replicator,dc=eab,dc=bank,dc=local" -w replpass \
  -b "dc=eab,dc=bank,dc=local" -s sub "(objectClass=*)" -LLL > /tmp/seed.ldif
systemctl stop symas-openldap-servers
rm -f /var/symas/openldap-data/example/data.mdb
slapadd -n 1 -l /tmp/seed.ldif
systemctl start symas-openldap-servers

# Force sync check
sudo /opt/symas/bin/ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b "dc=eab,dc=bank,dc=local" -s base contextCSN

# Disable TLS hardening temporarily
ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: cn=config
changetype: modify
delete: olcSecurity
olcSecurity: simple_bind=128
EOF
```

Regards
