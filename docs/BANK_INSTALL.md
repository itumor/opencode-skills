# OpenLDAP Bank Installation — Single Document

## Environment

| Item | Value |
|------|-------|
| **Master** | `172.23.11.236` (ciamuapplds01) |
| **Replica** | `172.23.11.237` |
| **Jump Station** | `172.23.10.32` |
| **SSH user** | `root` |
| **Base DN** | `dc=eab,dc=bank,dc=local` |
| **Admin** | `cn=admin,dc=eab,dc=bank,dc=local` / `TheN1le1` |
| **Replicator** | `cn=replicator,dc=eab,dc=bank,dc=local` / `replpass` |
| **Contact** | Salama Hamdy |
| **TLS** | Enforced (`simple_bind=128`, self-signed certs) |
| **OS** | RHEL 9 |
| **Repo** | Satellite-managed — `/etc/yum.repos.d/symas.repo` |

### Connection Flow

```
Workstation ──SSH──> Jump (172.23.10.32) ──SSH──> Master  (172.23.11.236)
                                                   Replica (172.23.11.237)
```

---

## Admin-Provisioned Paths (user `ebrahim`)

| Path | Perms | Notes |
|------|-------|-------|
| `/opt/symas/bin/` | rx | No write |
| `/opt/symas/etc/openldap/slapd.d/` | rw | |
| `/opt/symas/etc/openldap/schema/` | rw | |
| `/opt/symas/etc/openldap/tls/` | rw | |
| `/var/symas/openldap-data/example/` | rw | |
| `/tmp/script/` | rwx | |
| `/tmp/script/replica/` | rwx | |
| `/opt/symas/sbin/slapd` | rx | |
| `/opt/symas/etc/openldap/slapd.conf` | rw | |
| `/opt/symas/etc/openldap/ldap.conf` | rw | |
| `/usr/lib/systemd/system/symas-openldap-servers.service` | r | |
| `/opt/symas/etc/openldap/sysmas_env.sh` | rw | NOT `/etc/profile.d/` — typo'd dir! |
| `/etc/yum.repos.d/symas.repo` | r | NOT `soldap-release26.repo` |
| `/var/symas/run/ldapi` | 777 socket | Pre-existed |

### Path Gotchas

- `symas_env.sh` lives at `/opt/symas/etc/openldap/sysmas_env.sh` — sourcing `/etc/profile.d/symas_env.sh` will fail. Always set `PATH` explicitly.
- Yum repo is at `symas.repo`, not `soldap-release26.repo` as scripts expect.
- Binaries dir is `rx` only — can't write new schema files there.

---

## Master Install

### Step 1 — Copy scripts

From workstation (via jump):
```bash
scp -r ./script root@172.23.11.236:/tmp/script
```

### Step 2 — OpenLDAP health check

```bash
ssh root@172.23.11.236 'systemctl is-active symas-openldap-servers'
# Expected: active
```

If already running and healthy, skip to Step 5 (verify). If fresh node or broken, continue.

### Step 3 — Clean (if re-installing)

```bash
ssh root@172.23.11.236 'sudo bash /tmp/script/0-clean-openldap.sh'
```

### Step 4 — Run master installer

```bash
ssh root@172.23.11.236 << 'ENDSSH'
cd /tmp/script

# Apply bank path fixes before install:
# 1. Skipping repo setup (Satellite-managed SYMAS_REPO_URL=)
# 2. Fix env file path (symas_env.sh not in /etc/profile.d/)

# If Satellite repo not present, set SYMAS_REPO_URL:
# export SYMAS_REPO_URL=https://repo.symas.com/configs/SOLDAP/rhel9/release26.repo

bash install-symas-openldap-all-in-one.sh
ENDSSH
```

This runs ~20 scripts in order: package install → bootstrap DB → start daemon → fix env → TLS → OUs → replicator user → syncprov overlay → password policy → custom schema → MW user → ACLs → accesslog audit → hardening → tuning.

### Step 5 — Verify master

```bash
# Source env first
export PATH="/opt/symas/bin:/opt/symas/sbin:$PATH"

# Admin bind
ldapwhoami -x -ZZ -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1
# Expected: dn:cn=admin,dc=eab,dc=bank,dc=local

# List entries
ldapsearch -LLL -x -ZZ -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1 \
  -b 'dc=eab,dc=bank,dc=local' -s one dn

# Confirm replicator exists
ldapsearch -LLL -x -ZZ -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1 \
  -b 'dc=eab,dc=bank,dc=local' '(cn=replicator)' dn
# Expected: dn: cn=replicator,dc=eab,dc=bank,dc=local
```

If replicator is missing, create it:
```bash
# SSHA hash of 'replpass' (pre-generated — no slappasswd needed)
ldapadd -x -ZZ -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1 <<'LDIF'
dn: cn=replicator,dc=eab,dc=bank,dc=local
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: replicator
userPassword: {SSHA}vDJL5DOYxkOOv62uR/0boOhJItyq51qwdcORIA==
description: Replication bind user
LDIF
```

### Step 6 — Run automated master fix (if replication broken)

```bash
ssh root@172.23.11.236 'bash /tmp/script/fix-master.sh'
```

This adds entryUUID/entryCSN indices, syncprov overlay, and fixes checksums.

---

## Replica Install

### Step 1 — Copy scripts

```bash
scp -r ./script root@172.23.11.237:/tmp/script
```

### Step 2 — Port check

```bash
ssh root@172.23.11.237 \
  'timeout 3 bash -c "echo >/dev/tcp/172.23.11.236/389" && echo "OK" || echo "FAIL"'
# Expected: OK
```

### Step 3 — Prep scripts on replica

```bash
ssh root@172.23.11.237 << 'ENDSSH'
mkdir -p /opt/scripts/replica/test
mv /tmp/script/replica/*.sh      /opt/scripts/replica/
mv /tmp/script/replica/test/*.sh /opt/scripts/replica/test/
mv /tmp/script/install-symas-openldap-replica-all-in-one.sh /opt/scripts/
mv /tmp/script/12-Create_custom_schema.sh   /opt/scripts/
mv /tmp/script/13-Create_custom_schema_attr.sh /opt/scripts/
chmod +x /opt/scripts/*.sh /opt/scripts/replica/*.sh /opt/scripts/replica/test/*.sh
ENDSSH
```

### Step 4 — Choose TLS mode and run installer

#### Option A: Self-signed TLS (simplest, default)

```bash
ssh root@172.23.11.237 << 'ENDSSH'
cd /opt/scripts

MASTER_IP=172.23.11.236 \
ADMIN_PW=TheN1le1 \
REPL_PW=replpass \
BASE_DN=dc=eab,dc=bank,dc=local \
LDAPTLS_REQCERT=never \
bash install-symas-openldap-replica-all-in-one.sh
ENDSSH
```

#### Option B: Use Master's CA (same TLS chain)

**Step B1 — Extract CA on master:**
```bash
ssh root@172.23.11.236 'tar czf /tmp/master-ca.tar.gz -C /opt/symas/etc/openldap/tls ca.crt ca.key && chmod 644 /tmp/master-ca.tar.gz'
```

**Step B2 — Copy CA to replica (run on master, push):**
```bash
ssh root@172.23.11.236 'scp /tmp/master-ca.tar.gz root@172.23.11.237:/tmp/'
```

**Step B3 — Run installer with staged CA:**
```bash
ssh root@172.23.11.237 << 'ENDSSH'
tar xzf /tmp/master-ca.tar.gz -C /tmp/
ls /tmp/ca.crt /tmp/ca.key  # verify

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
ENDSSH
```

### Step 5 — Verify replica

```bash
ssh root@172.23.11.237 << 'ENDSSH'
export PATH="/opt/symas/bin:/opt/symas/sbin:$PATH"

# Admin bind
LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1
# Expected: dn:cn=admin,dc=eab,dc=bank,dc=local

# List entries (must match master)
LDAPTLS_REQCERT=never ldapsearch -LLL -x -ZZ -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1 \
  -b 'dc=eab,dc=bank,dc=local' -s one dn

# Write must be rejected (read-only)
LDAPTLS_REQCERT=never ldapadd -x -ZZ -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1 <<LDIF
dn: cn=test-write,dc=eab,dc=bank,dc=local
objectClass: organizationalRole
cn: test-write
LDIF
# Expected: ldap_add: Referral (10) → ldap://172.23.11.236:389
ENDSSH
```

### Step 6 — Test replication end-to-end

```bash
# Write on MASTER, read on REPLICA
TEST_UID="repltest-$(date +%Y%m%d%H%M%S)"

ssh root@172.23.11.236 "
export PATH='/opt/symas/bin:/opt/symas/sbin:\$PATH'
LDAPTLS_REQCERT=never ldapadd -x -ZZ -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1 <<LDIF
dn: uid=$TEST_UID,ou=Users,dc=eab,dc=bank,dc=local
objectClass: inetOrgPerson
cn: Replication Test
sn: Test
uid: $TEST_UID
LDIF
"

sleep 5

ssh root@172.23.11.237 "
export PATH='/opt/symas/bin:/opt/symas/sbin:\$PATH'
LDAPTLS_REQCERT=never ldapsearch -LLL -x -ZZ -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1 \
  -b 'dc=eab,dc=bank,dc=local' \"(uid=$TEST_UID)\" dn
"
# Expected: dn: uid=<TEST_UID>,ou=Users,dc=eab,dc=bank,dc=local

# Cleanup
ssh root@172.23.11.236 "
export PATH='/opt/symas/bin:/opt/symas/sbin:\$PATH'
LDAPTLS_REQCERT=never ldapdelete -x -ZZ -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1 \
  'uid=$TEST_UID,ou=Users,dc=eab,dc=bank,dc=local'
"
```

---

## Fix Existing Broken Setup

If master or replica are installed but replication is broken, run the all-in-one fix:

```bash
# Works on both master and replica — auto-detects role
ssh root@172.23.11.236 'bash /tmp/script/bank-fix-all.sh'
ssh root@172.23.11.237 'bash /tmp/script/bank-fix-all.sh'
```

The fix script does:
- **On master:** checksums fix, entryUUID/entryCSN indices, syncprov overlay, replicator password reset
- **On replica:** fix syncrepl config (TLS, mode, credentials), ppolicy module, TLS certs in cn=config, seed empty DB from master
- **Both:** find service (systemctl + pgrep fallback), fix ldapi ACL, restart, verify

---

## Quick Reference

| Command | Expected |
|---------|----------|
| `ldapwhoami` on master | `dn:cn=admin,dc=eab,dc=bank,dc=local` |
| `ldapwhoami` on replica | `dn:cn=admin,dc=eab,dc=bank,dc=local` |
| `ldapsearch` on replica | Same entries as master |
| `ldapadd` on replica | `Referral (10)` → `ldap://172.23.11.236:389` |
| Write on master → read on replica | Entry appears in <10s |

---

## Troubleshooting

### Binary not found
```bash
export PATH="/opt/symas/bin:/opt/symas/sbin:$PATH"
```
Don't rely on `/etc/profile.d/symas_env.sh` — it may not exist (bank has typo'd path).

### Service check
```bash
systemctl status symas-openldap-servers
# Fallback:
pgrep -x slapd
```

### Replication logs
```bash
journalctl -u symas-openldap-servers -n 50 --no-pager | grep -i "sync\|repl\|error"
```

### Replication config
```bash
ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  '(objectClass=olcMdbConfig)' olcSyncrepl olcUpdateRef
```

### Replicator connectivity from replica to master
```bash
LDAPTLS_REQCERT=never ldapwhoami -x -ZZ \
  -H ldap://172.23.11.236:389 \
  -D 'cn=replicator,dc=eab,dc=bank,dc=local' -w replpass
```

### Empty replica DB (refreshDelete loop)
If replicator can bind but syncrepl never pulls data, the replica DB may be empty. Seed it:
```bash
# On master
ldapsearch -x -ZZ -H ldap://localhost:389 -o ldif-wrap=no \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w TheN1le1 \
  -b 'dc=eab,dc=bank,dc=local' '(objectClass=*)' '*' '+' \
  > /tmp/master-dump.ldif

# Copy to replica, then on replica:
systemctl stop symas-openldap-servers
rm -f /var/symas/openldap-data/example/data.mdb
/opt/symas/sbin/slapadd -F /opt/symas/etc/openldap/slapd.d -l /tmp/master-dump.ldif
chown -R symas-openldap:symas-openldap /var/symas/openldap-data/example
systemctl start symas-openldap-servers
```

### Generate SSHA hash without slappasswd
```bash
python3 -c "
import hashlib, base64, os
salt = os.urandom(8)
h = hashlib.sha1(b'YOUR_PASSWORD')
h.update(salt)
print('{SSHA}' + base64.b64encode(h.digest() + salt).decode())
"
```

### Wipe and reinstall
```bash
# Destructive — removes all packages and data
bash /tmp/script/0-clean-openldap.sh

# Then rerun installer from Master Install Step 4 or Replica Install Step 4
```
