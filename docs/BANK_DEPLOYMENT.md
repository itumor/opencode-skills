# OpenLDAP Master / Replica — Bank Deployment

## Node IPs

| Role | IP |
|------|-----|
| **Master** | `172.23.11.236` |
| **Replica** | `172.23.11.237` |
| **Jump Station** | `172.23.10.32` |

> Contact: Salama Hamdy

---

## Connection Flow

```
Workstation  ──SSH──>  Jump Station (172.23.10.32)  ──SSH──>  Master  (172.23.11.236)
                                                              Replica (172.23.11.237)
```

All nodes reached through the jump station. No direct SSH to master or replica.

---

## Credentials

| Item | Value |
|------|-------|
| SSH user | `root` |
| LDAP Base DN | `dc=eab,dc=bank,dc=local` |
| LDAP Admin DN | `cn=admin,dc=eab,dc=bank,dc=local` |
| Admin password | *(provided separately)* |
| Replication password | *(provided separately)* |

---

## Pre-Flight Checklist (before replica setup)

- [ ] Master OpenLDAP installed and running
- [ ] `cn=replicator` user exists on master  
- [ ] Port 389 reachable from replica to master
- [ ] Scripts copied to both nodes

---

## Replica Setup

```bash
# === 1. COPY SCRIPTS TO REPLICA ===
# From your workstation, via jump station:

scp -r ./script root@172.23.11.237:/tmp/script

# === 2. SSH TO REPLICA ===
ssh root@172.23.11.237
sudo -i

# === 3. PREP SCRIPTS ===
mkdir -p /opt/scripts/replica/test
mv /tmp/script/replica/*.sh /opt/scripts/replica/
mv /tmp/script/replica/test/*.sh /opt/scripts/replica/test/
mv /tmp/script/install-symas-openldap-replica-all-in-one.sh /opt/scripts/
mv /tmp/script/12-Create_custom_schema.sh /opt/scripts/
mv /tmp/script/13-Create_custom_schema_attr.sh /opt/scripts/
chmod +x /opt/scripts/*.sh /opt/scripts/replica/*.sh /opt/scripts/replica/test/*.sh

# === 4. RUN INSTALLER ===
cd /opt/scripts

MASTER_IP=172.23.11.236 \
ADMIN_PW=admin \
REPL_PW=replpass \
BASE_DN=dc=eab,dc=bank,dc=local \
LDAPTLS_REQCERT=never \
bash install-symas-openldap-replica-all-in-one.sh
```

**No SSH/SCP from replica to master.** TLS is self-signed by default.

---

## Verify Replica

```bash
# Admin bind
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapwhoami -x -ZZ \
  -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w admin
# Expected: dn:cn=admin,dc=eab,dc=bank,dc=local

# List entries (must match master)
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapsearch -LLL -x -ZZ \
  -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w admin \
  -b 'dc=eab,dc=bank,dc=local' -s one dn

# Write rejected (read-only enforcement)
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapadd -x -ZZ \
  -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w admin <<LDIF
dn: cn=test-write,dc=eab,dc=bank,dc=local
objectClass: top
objectClass: organizationalRole
cn: test-write
LDIF
# Expected: ldap_add: Referral (10) → ldap://172.23.11.236:389

# Full test suite
sudo MASTER_IP=172.23.11.236 ADMIN_PW=admin REPL_PW=replpass LDAPTLS_REQCERT=never \
  bash /opt/scripts/replica/r9-verify-replica.sh

sudo ADMIN_PW=admin REPL_PW=replpass LDAPTLS_REQCERT=never \
  bash /opt/scripts/replica/test/test_replica_connections.sh

sudo ADMIN_PW=admin LDAPTLS_REQCERT=never \
  bash /opt/scripts/replica/test/test_replica_readonly.sh

sudo MASTER_IP=172.23.11.236 ADMIN_PW=admin LDAPTLS_REQCERT=never \
  bash /opt/scripts/replica/test/test_replica_sync.sh
```

---

## Quick Reference

| Test | Expected |
|------|----------|
| `ldapwhoami` on replica | `dn:cn=admin,dc=eab,dc=bank,dc=local` |
| `ldapsearch` on replica | Same entries as master |
| `ldapadd` on replica | `Referral (10)` → `ldap://172.23.11.236:389` |
| Write on master, read on replica | Entry appears in <10s |

---

## Troubleshooting

```bash
# Check service
sudo systemctl status symas-openldap-servers

# Check replication config
sudo /opt/symas/bin/ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  '(objectClass=olcMdbConfig)' olcSyncRepl olcUpdateRef

# Check sync logs
sudo journalctl -u symas-openldap-servers -n 50 --no-pager | grep -i sync

# Test connectivity from replica to master
sudo /opt/symas/bin/ldapwhoami -x -H ldap://172.23.11.236:389 \
  -D 'cn=replicator,dc=eab,dc=bank,dc=local' -w replpass
```
