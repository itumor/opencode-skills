# OpenLDAP Master / Replica — Bank Deployment

## Node IPs

| Role | Internal IP | Public IP | Hostname |
|------|-------------|-----------|----------|
| **Master** | `172.23.11.236` | `52.43.173.218` | `ciamuapplds01` |
| **Replica** | `172.23.11.237` | `35.91.98.69` | — |
| **Jump Station** | `172.23.10.32` | — | — |

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
| Admin password | `TheN1le1` |
| Replication password | `replpass` |

---

## Pre-Flight Checklist (before replica setup)

### 1. Master service running

```bash
ssh root@172.23.11.236 'systemctl is-active symas-openldap-servers'
# Expected: active
```

### 2. `cn=replicator` user exists on master

```bash
# Check
ssh root@172.23.11.236 \
  "LDAPTLS_REQCERT=never /opt/symas/bin/ldapsearch -LLL -x -ZZ -H ldap://localhost:389 \
   -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1 \
   -b 'dc=eab,dc=bank,dc=local' '(cn=replicator)' dn"
# Expected: dn: cn=replicator,dc=eab,dc=bank,dc=local

# If NOT found — create it (run on master):
# NOTE: slappasswd may be missing. Use pre-generated SSHA hash instead.
ssh root@172.23.11.236 "
  LDAPTLS_REQCERT=never /opt/symas/bin/ldapadd -x -ZZ -H ldap://localhost:389 \
   -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1 <<'LDIF'
dn: cn=replicator,dc=eab,dc=bank,dc=local
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: replicator
userPassword: {SSHA}vDJL5DOYxkOOv62uR/0boOhJItyq51qwdcORIA==
description: Replication bind user
LDIF
"
```

### 3. Port 389 reachable from replica to master

```bash
ssh root@172.23.11.237 \
  'timeout 3 bash -c "echo >/dev/tcp/172.23.11.236/389" && echo "OK" || echo "FAIL: port 389 blocked"'
# Expected: OK
```

### 4. Scripts copied to both nodes

```bash
scp -r ./script root@172.23.11.236:/tmp/script
scp -r ./script root@172.23.11.237:/tmp/script
```

---

## Replica Setup

No SSH/SCP from replica to master. Two TLS options below — choose one.

### Common — Copy scripts + prep (do once)

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
```

### Option A — Self-signed TLS (simplest)

Replica generates its own CA + server certificate. No master dependency.

```bash
cd /opt/scripts

MASTER_IP=172.23.11.236 \
ADMIN_PW=TheN1le1 \
REPL_PW=replpass \
BASE_DN=dc=eab,dc=bank,dc=local \
LDAPTLS_REQCERT=never \
bash install-symas-openldap-replica-all-in-one.sh
```

| Pro | Con |
|-----|-----|
| Zero master dependency | Two separate PKI chains |
| One command, no extra steps | `LDAPTLS_REQCERT=never` needed for self-signed |

---

### Option B — Use Master's CA (same TLS chain)

Replica uses the same CA as master. Clients that trust master automatically trust replica.

**Step 1 — Extract CA files on MASTER**

```bash
# SSH to master (172.23.11.236) and run:
sudo tar czf /tmp/master-ca.tar.gz -C /opt/symas/etc/openldap/tls ca.crt ca.key
sudo chmod 644 /tmp/master-ca.tar.gz
```

**Step 2 — Copy CA from master to replica**

Transfer `/tmp/master-ca.tar.gz` from master (172.23.11.236) to replica (172.23.11.237) using any method:

```bash
# Method A: scp FROM master (push, not pull — run on MASTER)
scp /tmp/master-ca.tar.gz root@172.23.11.237:/tmp/

# Method B: Copy via jump station
scp root@172.23.11.236:/tmp/master-ca.tar.gz .
scp master-ca.tar.gz root@172.23.11.237:/tmp/
```

**Step 3 — Extract on replica and run installer**

```bash
# ON REPLICA (already SSH'd in):
tar xzf /tmp/master-ca.tar.gz -C /tmp/
ls -la /tmp/ca.crt /tmp/ca.key    # verify files exist

cd /opt/scripts

MASTER_IP=172.23.11.236 \
ADMIN_PW=TheN1le1 \
REPL_PW=replpass \
BASE_DN=dc=eab,dc=bank,dc=local \
COPY_FROM_MASTER=1 \
STAGED_CA_CERT=/tmp/ca.crt \
STAGED_CA_KEY=/tmp/ca.key \
LDAPTLS_REQCERT=never \
bash install-symas-openldap-replica-all-in-one.sh
```

| Pro | Con |
|-----|-----|
| Same PKI as master | Extra manual step to copy CA files |
| Clients trust both automatically | Must re-copy CA after renewal |

---

## Verify Replica

```bash
# Source environment first
source /etc/profile.d/symas_env.sh

# Admin bind
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapwhoami -x -ZZ \
  -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1
# Expected: dn:cn=admin,dc=eab,dc=bank,dc=local

# List entries (must match master)
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapsearch -LLL -x -ZZ \
  -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1 \
  -b 'dc=eab,dc=bank,dc=local' -s one dn

# Write rejected (read-only enforcement)
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapadd -x -ZZ \
  -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1 <<LDIF
dn: cn=test-write,dc=eab,dc=bank,dc=local
objectClass: top
objectClass: organizationalRole
cn: test-write
LDIF
# Expected: ldap_add: Referral (10) → ldap://172.23.11.236:389

# Full test suite
sudo MASTER_IP=172.23.11.236 ADMIN_PW=TheN1le1 REPL_PW=replpass LDAPTLS_REQCERT=never \
  bash /opt/scripts/replica/r9-verify-replica.sh

sudo ADMIN_PW=TheN1le1 REPL_PW=replpass LDAPTLS_REQCERT=never \
  bash /opt/scripts/replica/test/test_replica_connections.sh

sudo ADMIN_PW=TheN1le1 LDAPTLS_REQCERT=never \
  bash /opt/scripts/replica/test/test_replica_readonly.sh

sudo MASTER_IP=172.23.11.236 ADMIN_PW=TheN1le1 LDAPTLS_REQCERT=never \
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

# View logs
sudo journalctl -u slapd --no-pager | tail -100
sudo journalctl -u symas-openldap-servers --no-pager | tail -100
sudo journalctl -u slapd -f  # follow live

# Syslog fallback
sudo tail -100 /var/log/messages | grep -i slapd

# Find exact service name
systemctl list-units --type=service | grep -i ldap

# Check replication config
sudo /opt/symas/bin/ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  '(objectClass=olcMdbConfig)' olcSyncrepl olcUpdateRef

# Check sync logs
sudo journalctl -u symas-openldap-servers -n 50 --no-pager | grep -i sync

# Test connectivity from replica to master
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapwhoami -x -ZZ \
  -H ldap://172.23.11.236:389 \
  -D 'cn=replicator,dc=eab,dc=bank,dc=local' -w replpass
```

## Gotchas

- **`slappasswd` may be missing**: On bank server, `/opt/symas/bin/slappasswd` may not exist. Use a pre-generated SSHA hash inline instead. Generate locally: `python3 -c "import hashlib,base64,os; s=os.urandom(8); h=hashlib.sha1(b'replpass'); h.update(s); print('{SSHA}'+base64.b64encode(h.digest()+s).decode())"`.
- **TLS enforced**: All password binds need `LDAPTLS_REQCERT=never -ZZ` due to self-signed certs and `olcSecurity: simple_bind=128`.
- **`source /etc/profile.d/symas_env.sh`** before running `ldapsearch`/`ldapadd` locally, or use `/opt/symas/bin/ldapsearch` full path.
- **`olcSyncrepl`** (lowercase `r`) not `olcSyncRepl` — grep with `-i` to be safe.
