# OpenLDAP Master-Replica TLS Deployment Guide

## Prerequisites

- RHEL 9 on both master and replica nodes
- Symas SOLDAP repo accessible via Red Hat Satellite (`soldap-release26`)
- Root or sudo access on both nodes
- Both nodes can reach each other on port 389 (internal network)
- Master IP: `172.23.11.236`, Replica IP: `172.23.11.237` (update as needed)

## Files Included

| File | Purpose |
|------|---------|
| `script/` | All master + replica installer scripts |
| `script/0-clean-openldap.sh` | Wipes old Symas install for clean start |
| `script/install-symas-openldap-all-in-one.sh` | Master orchestrator |
| `script/install-symas-openldap-replica-all-in-one.sh` | Replica orchestrator |
| `script/replica/` | r1..r9 replica scripts |
| `script/test/` | Test scripts |

## Credentials

| Item | Value |
|------|-------|
| Base DN | `dc=eab,dc=bank,dc=local` |
| Admin DN | `cn=admin,dc=eab,dc=bank,dc=local` |
| Admin Password | `TheN1le1` |
| Replicator DN | `cn=replicator,dc=eab,dc=bank,dc=local` |
| Replicator Password | `replpass` |

## Step-by-Step Deployment

### 1. Copy scripts to both nodes

```bash
# From jump station
unzip openldap-tls-deploy.zip -d /tmp/
scp -r /tmp/openldap-tls-deploy/script root@172.23.11.236:/tmp/script
scp -r /tmp/openldap-tls-deploy/script root@172.23.11.237:/tmp/script
```

### 2. Clean both nodes

```bash
# On master (172.23.11.236)
ssh root@172.23.11.236 'sudo bash /tmp/script/0-clean-openldap.sh'

# On replica (172.23.11.237)
ssh root@172.23.11.237 'sudo bash /tmp/script/0-clean-openldap.sh'
```

### 3. Install master with TLS

```bash
ssh root@172.23.11.236 'sudo TLS_MODE=yes bash /tmp/script/install-symas-openldap-all-in-one.sh'
```

Wait ~2-3 minutes. All tests should pass.

### 4. Extract master CA cert for replica

```bash
# Copy CA cert+key from master to jump station
ssh root@172.23.11.236 'sudo cat /opt/symas/etc/openldap/tls/ca.crt' > /tmp/master-ca.crt
ssh root@172.23.11.236 'sudo cat /opt/symas/etc/openldap/tls/ca.key' > /tmp/master-ca.key

# Push to replica
scp /tmp/master-ca.crt /tmp/master-ca.key root@172.23.11.237:/tmp/
```

### 5. Install replica with TLS (using master CA)

```bash
MASTER_IP=172.23.11.236

ssh root@172.23.11.237 \
  "sudo MASTER_IP=$MASTER_IP ADMIN_PW=TheN1le1 REPL_PW=replpass \
   TLS_MODE=yes COPY_FROM_MASTER=1 \
   STAGED_CA_CERT=/tmp/master-ca.crt \
   STAGED_CA_KEY=/tmp/master-ca.key \
   LDAPTLS_REQCERT=never \
   bash /tmp/script/install-symas-openldap-replica-all-in-one.sh"
```

Wait ~2-3 minutes. You should see `PASS=10 FAIL=0 WARN=0` at the end.

### 6. Test connections

```bash
# From jump station, extract CA cert for client use:
ssh root@172.23.11.236 'sudo cat /opt/symas/etc/openldap/tls/ca.crt' > /tmp/master-ca.crt
export LDAPTLS_CACERT=/tmp/master-ca.crt

# Master bind
ldapwhoami -x -ZZ -H ldap://172.23.11.236:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1"

# Replica bind
ldapwhoami -x -ZZ -H ldap://172.23.11.237:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1"

# List entries
ldapsearch -x -ZZ -H ldap://172.23.11.236:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  -b "dc=eab,dc=bank,dc=local" -s one "(objectClass=*)" dn
```

### 7. Test replication

```bash
export LDAPTLS_CACERT=/tmp/master-ca.crt
TEST_UID="repltest-$(date +%Y%m%d%H%M%S)"

# Add on master
ldapadd -x -ZZ -H ldap://172.23.11.236:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" <<EOF
dn: uid=${TEST_UID},ou=Users,dc=eab,dc=bank,dc=local
objectClass: inetOrgPerson
objectClass: organizationalPerson
objectClass: person
cn: ReplTest
sn: Test
uid: ${TEST_UID}
userPassword: TestPass123!
EOF

# Wait for replication
sleep 8

# Verify on replica
ldapsearch -x -ZZ -o ldif-wrap=no -H ldap://172.23.11.237:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  -b "uid=${TEST_UID},ou=Users,dc=eab,dc=bank,dc=local" -s base dn

# Cleanup on master
ldapdelete -x -ZZ -H ldap://172.23.11.236:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  "uid=${TEST_UID},ou=Users,dc=eab,dc=bank,dc=local"
```

## CA Certificate for Clients

The master CA cert (`/opt/symas/etc/openldap/tls/ca.crt`) signs both server certs. Clients must trust it:

```bash
# Linux/OpenLDAP CLI
export LDAPTLS_CACERT=/path/to/master-ca.crt

# macOS (keychain)
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain master-ca.crt

# Java/Apache Directory Studio
keytool -importcert -noprompt -trustcacerts -alias ldap-ca \
  -file master-ca.crt -keystore truststore.jks -storepass changeit
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `slappasswd` missing | Packages not installed — re-run 0-clean + master install |
| `ldap_sasl_interactive_bind_s: Confidentiality required` | TLS required — add `-ZZ` + CA cert |
| Replica shows 0 entries | Check syncrepl: `ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config "(olcSyncrepl=*)"` |
| `objectClass: value #0 invalid` on replica | ppolicy module not loaded — re-run replica installer |
| ldapsearch wraps lines | Add `-o ldif-wrap=no` |
| Firewall blocks port 389/636 | `firewall-cmd --add-port=389/tcp --add-port=636/tcp --permanent && firewall-cmd --reload` |
| `simple_bind=128` blocks plain LDAP | Use `-ZZ` (StartTLS) or `-H ldaps://` (LDAPS) for password binds |

## Deployment Summary

| Role | IP | Ports | TLS |
|------|----|-------|-----|
| Master | 172.23.11.236 | 389 (StartTLS), 636 (LDAPS) | Self-signed CA |
| Replica | 172.23.11.237 | 389 (StartTLS), 636 (LDAPS) | Signed by master CA |
