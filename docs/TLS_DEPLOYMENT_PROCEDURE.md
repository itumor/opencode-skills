# OpenLDAP Master+Replica — Full TLS Deployment Procedure

Two EC2 instances, clean slate to production with TLS, StartTLS enforcement, and syncrepl replication.

## Prerequisites

- RHEL 9 EC2 instances with Satellite-managed repos
- SSH key access to both nodes
- Both nodes can reach each other on port 389

## Environment

```bash
export SSH_KEY="terraform/openldap-master-replica/.local-ssh/openldap_master_replica"
export MASTER_IP=54.185.183.18
export REPLICA_IP=54.191.26.211
export ADMIN_PW=TheN1le1
export REPL_PW=replpass
export BASE_DN="dc=eab,dc=bank,dc=local"
```

---

## Step 1: Copy Scripts to Both Nodes

```bash
scp -o StrictHostKeyChecking=no -i "$SSH_KEY" -r script "ec2-user@${MASTER_IP}:/tmp/script"
scp -o StrictHostKeyChecking=no -i "$SSH_KEY" -r script "ec2-user@${REPLICA_IP}:/tmp/script"
```

---

## Step 2: Clean Both Nodes (Slate Reset)

```bash
# Master
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "ec2-user@${MASTER_IP}" \
  "sudo bash /tmp/script/0-clean-openldap.sh"

# Replica
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "ec2-user@${REPLICA_IP}" \
  "sudo bash /tmp/script/0-clean-openldap.sh"
```

Removes: Symas packages, `/opt/symas/`, `/var/symas/`, repo configs, service units, firewalld rules.

---

## Step 3: Install Master with TLS

```bash
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "ec2-user@${MASTER_IP}" \
  "sudo TLS_MODE=yes bash /tmp/script/install-symas-openldap-all-in-one.sh"
```

Runs 30+ scripts: packages → slapd → OUs → bindings → ppolicy → schema → TLS certs → hardening → tuning → tests.

**What it configures:**
- Symas OpenLDAP 2.6.13 packages
- `cn=config` database with serverID 1
- Self-signed CA + server cert in `/opt/symas/etc/openldap/tls/`
- `olcTLSCertificateFile/KeyFile/CACertificateFile` in cn=config
- LDAP (389), LDAPS (636), ldapi listeners
- syncprov overlay + entryUUID/entryCSN indices
- `cn=replicator` user with replication read ACL
- ppolicy + custom bank schema
- Hardening: anonymous bind disabled, `simple_bind=128` (TLS required)
- Accesslog audit overlay

---

## Step 4: Verify Master

```bash
# Admin bind via StartTLS
LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H "ldap://${MASTER_IP}:389" \
  -D "cn=admin,${BASE_DN}" -w "${ADMIN_PW}"

# Replicator bind via StartTLS
LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H "ldap://${MASTER_IP}:389" \
  -D "cn=replicator,${BASE_DN}" -w "${REPL_PW}"

# List entries
LDAPTLS_REQCERT=never ldapsearch -o ldif-wrap=no -x -ZZ -H "ldap://${MASTER_IP}:389" \
  -D "cn=admin,${BASE_DN}" -w "${ADMIN_PW}" \
  -b "${BASE_DN}" -s one "(objectClass=*)" dn
```

Expected: 6 child entries (Users, Admins, Groups, Systems, Policies, replicator).

---

## Step 5: Extract Master CA for Replica

```bash
# Fetch CA cert and key (requires sudo on remote)
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "ec2-user@${MASTER_IP}" \
  'sudo cat /opt/symas/etc/openldap/tls/ca.crt' > /tmp/master-ca.crt
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "ec2-user@${MASTER_IP}" \
  'sudo cat /opt/symas/etc/openldap/tls/ca.key' > /tmp/master-ca.key

# Copy to replica
scp -o StrictHostKeyChecking=no -i "$SSH_KEY" /tmp/master-ca.crt "ec2-user@${REPLICA_IP}:/tmp/master-ca.crt"
scp -o StrictHostKeyChecking=no -i "$SSH_KEY" /tmp/master-ca.key  "ec2-user@${REPLICA_IP}:/tmp/master-ca.key"
```

This ensures the replica's server cert is signed by the same CA as the master, so syncrepl TLS works seamlessly.

---

## Step 6: Install Replica with TLS (Using Master's CA)

```bash
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "ec2-user@${REPLICA_IP}" \
  "sudo MASTER_IP=${MASTER_IP} ADMIN_PW=${ADMIN_PW} TLS_MODE=yes \
   COPY_FROM_MASTER=1 STAGED_CA_CERT=/tmp/master-ca.crt STAGED_CA_KEY=/tmp/master-ca.key \
   bash /tmp/script/install-symas-openldap-replica-all-in-one.sh"
```

Runs r1→r9 scripts: packages → cn=config init (serverID 2, syncrepl, updateRef) → daemon start → schema load (cosine, inetorgperson, bank-custom, ppolicy) → TLS (server cert signed by master CA) → LDAPI ACL → hardening → tuning → verification.

**Key config:**
- `olcSyncrepl`: `rid=101`, `provider=ldap://${MASTER_IP}:389`, `starttls=yes`, `tls_reqcert=never`
- `olcUpdateRef`: `ldap://${MASTER_IP}:389`
- Writes rejected/referred back to master

---

## Step 7: Verify Replica

```bash
# Admin bind via StartTLS
LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H "ldap://${REPLICA_IP}:389" \
  -D "cn=admin,${BASE_DN}" -w "${ADMIN_PW}"

# Check data replicated (should show same 6 entries as master)
LDAPTLS_REQCERT=never ldapsearch -o ldif-wrap=no -x -ZZ -H "ldap://${REPLICA_IP}:389" \
  -D "cn=admin,${BASE_DN}" -w "${ADMIN_PW}" \
  -b "${BASE_DN}" -s one "(objectClass=*)" dn

# Run full replica health check
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "ec2-user@${REPLICA_IP}" \
  "sudo MASTER_IP=${MASTER_IP} ADMIN_PW=${ADMIN_PW} bash /tmp/script/replica/r9-verify-replica.sh"
```

Expected: `PASS=11  FAIL=0  WARN=0`

---

## Step 8: Test Replication

```bash
# Add test entry on master
LDAPTLS_REQCERT=never ldapadd -x -ZZ -H "ldap://${MASTER_IP}:389" \
  -D "cn=admin,${BASE_DN}" -w "${ADMIN_PW}" <<'LDIF'
dn: cn=repltest,dc=eab,dc=bank,dc=local
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: repltest
description: Replication test entry
userPassword: {SSHA}test123
LDIF

sleep 5

# Verify on replica
LDAPTLS_REQCERT=never ldapsearch -o ldif-wrap=no -x -ZZ -H "ldap://${REPLICA_IP}:389" \
  -D "cn=admin,${BASE_DN}" -w "${ADMIN_PW}" \
  -b "cn=repltest,${BASE_DN}" -s base dn

# Compare contextCSN
echo "Master CSN:"
LDAPTLS_REQCERT=never ldapsearch -o ldif-wrap=no -x -ZZ -H "ldap://${MASTER_IP}:389" \
  -D "cn=admin,${BASE_DN}" -w "${ADMIN_PW}" \
  -b "${BASE_DN}" -s base contextCSN 2>&1 | grep contextCSN

echo "Replica CSN:"
LDAPTLS_REQCERT=never ldapsearch -o ldif-wrap=no -x -ZZ -H "ldap://${REPLICA_IP}:389" \
  -D "cn=admin,${BASE_DN}" -w "${ADMIN_PW}" \
  -b "${BASE_DN}" -s base contextCSN 2>&1 | grep contextCSN

# Cleanup
LDAPTLS_REQCERT=never ldapdelete -x -ZZ -H "ldap://${MASTER_IP}:389" \
  -D "cn=admin,${BASE_DN}" -w "${ADMIN_PW}" \
  "cn=repltest,${BASE_DN}"
```

contextCSN must match exactly on both nodes.

---

## Quick Test Commands

```bash
# Master bind
LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H ldap://54.185.183.18:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1"

# Replica bind
LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H ldap://54.191.26.211:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1"

# Master via LDAPS
LDAPTLS_REQCERT=never ldapwhoami -x -H ldaps://54.185.183.18:636 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1"

# Replica via LDAPS
LDAPTLS_REQCERT=never ldapwhoami -x -H ldaps://54.191.26.211:636 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1"
```

## Re-Run Verification (any time)

```bash
# Master health check (16 points)
ssh -i "$SSH_KEY" "ec2-user@${MASTER_IP}" \
  "sudo bash /tmp/script/verify-master.sh"

# Replica health check (17 points)
ssh -i "$SSH_KEY" "ec2-user@${REPLICA_IP}" \
  "sudo MASTER_IP=${MASTER_IP} ADMIN_PW=${ADMIN_PW} bash /tmp/script/verify-replica.sh"

# Cross-role verification (auto-detects master/replica)
ssh -i "$SSH_KEY" "ec2-user@${MASTER_IP}" \
  "sudo MASTER_IP=${MASTER_IP} ADMIN_PW=${ADMIN_PW} bash /tmp/script/verify-post-fix.sh"
ssh -i "$SSH_KEY" "ec2-user@${REPLICA_IP}" \
  "sudo MASTER_IP=${MASTER_IP} ADMIN_PW=${ADMIN_PW} bash /tmp/script/verify-post-fix.sh"

# Fix scripts (if something is broken)
ssh -i "$SSH_KEY" "ec2-user@${MASTER_IP}" \
  "sudo bash /tmp/script/fix-master.sh"
ssh -i "$SSH_KEY" "ec2-user@${REPLICA_IP}" \
  "sudo MASTER_IP=${MASTER_IP} ADMIN_PW=${ADMIN_PW} REPL_PW=${REPL_PW} bash /tmp/script/fix-replica.sh"
```

## Connection Matrix (Post-Deployment)

Both nodes enforce `olcSecurity: simple_bind=128` (TLS required for password binds).

| Method | Port | Can Bind? | Notes |
|--------|------|-----------|-------|
| `ldap://` plain (no `-ZZ`) | 389 | FAIL | "Confidentiality required (13)" |
| `ldap://` + StartTLS (`-ZZ`) | 389 | OK | Needs `LDAPTLS_REQCERT=never` or CA import |
| `ldaps://` (LDAP over SSL) | 636 | OK | Needs `LDAPTLS_REQCERT=never` or CA import |
| `ldapi:///` (Unix socket) | — | OK | Root/sudo, `-Y EXTERNAL` (no password) |

## Troubleshooting

### Checksum errors on startup (non-fatal)
```
ldif_read_file: checksum error on ".../cn=config.ldif"
```
Cosmetic only. slapd recalculates internally. Service works fine. To fix: `fix-master.sh` (slapcat + slapadd rebuild).

### TLS cert/key mismatch
```
main: TLS init def ctx failed: -1 error:05800074:x509 certificate routines::key values mismatch
```
Regenerate server cert:
```bash
ssh -i "$SSH_KEY" "ec2-user@${MASTER_IP}" '
sudo bash -c "
cd /opt/symas/etc/openldap/tls
openssl genrsa -out ldap.key 4096
openssl req -new -key ldap.key -out /tmp/ldap.csr \
  -subj \"/CN=\$(hostname -f)\"
openssl x509 -req -in /tmp/ldap.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out ldap.crt -days 3650 -sha256
/opt/symas/sbin/slaptest -u
systemctl restart symas-openldap-servers
"'
```

### Syncrepl not streaming (stale contextCSN)
Restart replica slapd to re-establish syncrepl connection:
```bash
ssh -i "$SSH_KEY" "ec2-user@${REPLICA_IP}" \
  "sudo systemctl restart symas-openldap-servers && sleep 5"
```

### Empty replica DB (refreshDelete loop)
Seed replica from master before enabling syncrepl:
```bash
# On master: export data
ssh -i "$SSH_KEY" "ec2-user@${MASTER_IP}" \
  'sudo /opt/symas/sbin/slapcat -b "dc=eab,dc=bank,dc=local" -l /tmp/seed.ldif'

# Copy to replica
scp -i "$SSH_KEY" "ec2-user@${MASTER_IP}:/tmp/seed.ldif" /tmp/seed.ldif
scp -i "$SSH_KEY" /tmp/seed.ldif "ec2-user@${REPLICA_IP}:/tmp/seed.ldif"

# On replica: stop, wipe, import, start
ssh -i "$SSH_KEY" "ec2-user@${REPLICA_IP}" '
sudo systemctl stop symas-openldap-servers
sudo rm -f /var/symas/openldap-data/example/*.mdb
sudo /opt/symas/sbin/slapadd -b "dc=eab,dc=bank,dc=local" -l /tmp/seed.ldif
sudo chown -R ldap:ldap /var/symas/openldap-data/example
sudo systemctl start symas-openldap-servers
'
```

## Service Management

```bash
# Restart
sudo systemctl restart symas-openldap-servers

# Status
sudo systemctl status symas-openldap-servers

# Logs
sudo journalctl -u symas-openldap-servers --no-pager -n 50
sudo journalctl -u symas-openldap-servers -f   # follow

# Validate config (without starting)
sudo /opt/symas/sbin/slapd -Tt
```
