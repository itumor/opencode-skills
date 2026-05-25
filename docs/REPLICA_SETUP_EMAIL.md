Subject: OpenLDAP Replica Setup — No-SSH Scripts (branch: feature/replica-no-ssh)

---

## Branch

`feature/replica-no-ssh`

## What changed

Removed all SSH/SCP from the replica setup scripts. The replica no longer SSHs into the master for any reason. TLS is self-signed by default. Master's CA can be staged manually if needed with `STAGED_CA_CERT`/`STAGED_CA_KEY` env vars.

**Files modified:**
- `script/replica/r5-configure-replica-tls.sh` — SCP removed, self-signed by default
- `script/install-symas-openldap-replica-all-in-one.sh` — SSH env vars removed
- `script/replica/r2-configure-replica-instance.sh` — `starttls=no` (master has no TLS in default bootstrap)
- `script/replica/r6-fix-replica-ldapi-acl.sh` — fixed LDIF corruption bug
- `script/replica/test/test_replica_sync.sh` — fixed OU match (`ou=people`) and master connection

**Verified on AWS EC2** — replica synced from master in <10s without any SSH/SCP.

---

## Replica Setup Commands

```bash
# === 1. COPY SCRIPTS ===
# From your workstation:

scp -r ./script ec2-user@<REPLICA_IP>:/tmp/script

# === 2. SSH TO REPLICA + PREP ===
ssh ec2-user@<REPLICA_IP>
sudo -i

mkdir -p /opt/scripts/replica/test
mv /tmp/script/replica/*.sh /opt/scripts/replica/
mv /tmp/script/replica/test/*.sh /opt/scripts/replica/test/
mv /tmp/script/install-symas-openldap-replica-all-in-one.sh /opt/scripts/
mv /tmp/script/12-Create_custom_schema.sh /opt/scripts/
mv /tmp/script/13-Create_custom_schema_attr.sh /opt/scripts/
chmod +x /opt/scripts/*.sh /opt/scripts/replica/*.sh /opt/scripts/replica/test/*.sh

# === 3. RUN INSTALLER ===
cd /opt/scripts

export MASTER_IP=<MASTER_PRIVATE_IP>
export ADMIN_PW=<MASTER_ADMIN_PASSWORD>
export REPL_PW=<REPLICATION_PASSWORD>
export BASE_DN=dc=eab,dc=bank,dc=local
export LDAPTLS_REQCERT=never

bash install-symas-openldap-replica-all-in-one.sh
```

### Env vars reference

| Variable | Required | Default | Description |
|---|---|---|---|
| `MASTER_IP` | **yes** | — | Master IP/hostname (reachable on TCP 389) |
| `ADMIN_PW` | **yes** | — | Must match master `cn=admin` password |
| `REPL_PW` | no | `replpass` | Must match master `cn=replicator` password |
| `BASE_DN` | no | `dc=eab,dc=bank,dc=local` | Must match master |
| `SERVER_ID` | no | `2` | Change per replica (3, 4, …) |
| `COPY_FROM_MASTER` | no | `0` | `0` = self-signed (default), `1` = staged master CA |
| `STAGED_CA_CERT` | if COPY=1 | — | Path to manually-copied CA cert |
| `STAGED_CA_KEY` | if COPY=1 | — | Path to manually-copied CA key |

### If you need master's CA instead of self-signed

```bash
# ON MASTER — extract CA files
sudo tar czf /tmp/master-ca.tar.gz -C /opt/symas/etc/openldap/tls ca.crt ca.key
sudo chmod 644 /tmp/master-ca.tar.gz

# Transfer master-ca.tar.gz to replica (scp FROM master, S3, USB, etc.)

# ON REPLICA — extract and run
tar xzf /tmp/master-ca.tar.gz -C /tmp/
sudo MASTER_IP=10.30.1.10 ADMIN_PW=secret \
     COPY_FROM_MASTER=1 STAGED_CA_CERT=/tmp/ca.crt STAGED_CA_KEY=/tmp/ca.key \
     bash /opt/scripts/install-symas-openldap-replica-all-in-one.sh
```

---

## Test Commands (replica only)

```bash
# Admin bind via StartTLS
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapwhoami -x -ZZ \
  -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW>

# Expected: dn:cn=admin,dc=eab,dc=bank,dc=local

# List entries (should match master)
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapsearch -LLL -x -ZZ \
  -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> \
  -b 'dc=eab,dc=bank,dc=local' -s one dn

# Confirm write is REJECTED (read-only enforcement)
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapadd -x -ZZ \
  -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> 2>&1 <<LDIF
dn: cn=test-write,dc=eab,dc=bank,dc=local
objectClass: top
objectClass: organizationalRole
cn: test-write
LDIF
# Expected: ldap_add: Referral (10) referrals: ldap://<MASTER_IP>:389/...

# Replication sync test (write to MASTER → read from REPLICA)
# Run this on the MASTER first:
TEST_UID="repl-test-$(date +%Y%m%d%H%M%S)"
sudo /opt/symas/bin/ldapadd -x -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> <<LDIF
dn: uid=$TEST_UID,ou=Users,dc=eab,dc=bank,dc=local
objectClass: inetOrgPerson
cn: Replication Test
sn: Test
uid: $TEST_UID
LDIF

# Then on REPLICA (after 5s):
sleep 5
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapsearch -LLL -x -ZZ \
  -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> \
  -b 'dc=eab,dc=bank,dc=local' "(uid=$TEST_UID)" dn
# Expected: dn: uid=<TEST_UID>,ou=Users,dc=eab,dc=bank,dc=local

# Cleanup on MASTER
sudo /opt/symas/bin/ldapdelete -x -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> \
  "uid=$TEST_UID,ou=Users,dc=eab,dc=bank,dc=local"

# Re-run built-in test suite at any time
sudo MASTER_IP=<MASTER_IP> ADMIN_PW=<ADMIN_PW> REPL_PW=<REPL_PW> LDAPTLS_REQCERT=never \
  bash /opt/scripts/replica/r9-verify-replica.sh

sudo ADMIN_PW=<ADMIN_PW> REPL_PW=<REPL_PW> LDAPTLS_REQCERT=never \
  bash /opt/scripts/replica/test/test_replica_connections.sh

sudo ADMIN_PW=<ADMIN_PW> LDAPTLS_REQCERT=never \
  bash /opt/scripts/replica/test/test_replica_readonly.sh

sudo MASTER_IP=<MASTER_IP> ADMIN_PW=<ADMIN_PW> LDAPTLS_REQCERT=never \
  bash /opt/scripts/replica/test/test_replica_sync.sh
```

---

## Quick Test Reference

| Command | Expected |
|---|---|
| `ldapwhoami` on replica | `dn:cn=admin,dc=...` |
| `ldapsearch` on replica | Same entries as master |
| `ldapadd` on replica | `Referral (10)` → master |
| Write on master, read on replica | Entry appears within seconds |
| `r9-verify-replica.sh` | PASS for service, syncrepl, updateRef, read-only, sync |
