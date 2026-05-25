# OpenLDAP Master / Replica — Bank Runbook

Step-by-step guide to install Symas OpenLDAP 2.6 master and replica nodes on RHEL 9.

> **Security note:** The replica does NOT use SSH/SCP to the master. All TLS material is either self-signed on the replica or staged manually by the operator.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Master Setup](#master-setup)
3. [Replica Setup](#replica-setup)
4. [TLS Modes Explained](#tls-modes-explained)
5. [Verification](#verification)
6. [Day-2 Operations](#day-2-operations)
7. [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Requirement | Detail |
|---|---|
| **OS** | RHEL 9 / AlmaLinux 9 / Rocky Linux 9 (or compatible) |
| **Packages** | `curl`, `sudo`, `systemd` |
| **Symas SOLDAP repo** | Enabled via Red Hat Satellite, OR scripts auto-add from `repo.symas.com` |
| **User** | Must run as `root` (all scripts use `sudo`) |
| **Master node** | Installed and running before replica setup |
| **Network** | Replica must reach master on TCP port 389 (LDAP) |

---

## Master Setup

### 1. Copy scripts to master node

```bash
# From your workstation
scp -r ./script ec2-user@<MASTER_IP>:/tmp/script
```

### 2. Run master all-in-one installer

```bash
# SSH to master, become root
ssh ec2-user@<MASTER_IP>
sudo -i

cd /tmp/script

# Run with defaults
bash install-symas-openldap-all-in-one.sh

# OR with custom base DN and password
sudo BASE_DN="dc=example,dc=com" BIND_PW="Secret123!" \
  bash install-symas-openldap-all-in-one.sh
```

#### What the master installer does (in order)

```
1-install-symas-openldap      → Install Symas OpenLDAP packages
3-install-example             → Bootstrap database + cn=config with exampledb.sh
4-Start-the-daemon            → Enable/start systemd service
5-fix_all_symas_warns         → Create /etc/profile.d/symas_env.sh
6-fix_remaining_symas_warns   → slapd symlink + minimal TLS
7-verify_symas_openldap       → Verify service is healthy
8.0-fix_ldapi_acl             → Fix SASL/EXTERNAL manage ACL on cn=config
8-create_top_ous              → Create top-level OUs (Users, Groups, Systems)
26-configure-bindings         → Create cn=replicator user + syncprov overlay + replication ACL
9-password_policy             → Create ou=Policies + cn=default password policy
10-ppolicy-container          → Create ppolicy container + default policy DN
10.0-password_policy_make_default → Make default policy effective
12-Create_custom_schema       → Create cn=bank-custom schema container
13-Create_custom_schema_attr  → Add bank extension attributes + objectClass
16-add-strong-password-quality-checker-PPM → Strong password complexity
17-create_mw_user             → Create middleware service account
27-configure-mw-acl           → Grant MW user write ACL on ou=Users
18-service-account-password-policy-never-expire → Never-expire policy for service accounts
19-create-user-using-mw-user  → Test: create user via MW account
24-configure-ssl-tls          → Generate self-signed TLS cert, enable LDAPS
21-hardening                  → Disable anonymous bind, require TLS for simple binds
22-tuning                     → LimitNOFILE=524288, SLAPD_URLS/OPTIONS
23-ensure-installation-not-under-root → Compliance check
25-configure-accesslog-audit  → Accesslog overlay for audit trail
```

### 3. Verify master

```bash
# Admin bind
sudo /opt/symas/bin/ldapwhoami -x -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW>

# List entries
sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> \
  -b 'dc=eab,dc=bank,dc=local' -s one dn
```

### 4. Confirm replicator user exists on master

```bash
# This is required before setting up any replica
sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> \
  -b 'dc=eab,dc=bank,dc=local' '(cn=replicator)' dn
```
Expected: `dn: cn=replicator,dc=eab,dc=bank,dc=local`

---

## Replica Setup

The replica setup is fully independent — **no SSH/SCP from replica to master.**

### 1. Copy scripts to replica node

```bash
# From your workstation — copy ALL scripts (replica scripts depend on master scripts for schemas)
scp -r ./script ec2-user@<REPLICA_IP>:/tmp/script
```

### 2. Prepare replica environment

```bash
ssh ec2-user@<REPLICA_IP>
sudo -i

mkdir -p /opt/scripts/replica/test
mv /tmp/script/replica/*.sh /opt/scripts/replica/
mv /tmp/script/replica/test/*.sh /opt/scripts/replica/test/
mv /tmp/script/install-symas-openldap-replica-all-in-one.sh /opt/scripts/
mv /tmp/script/12-Create_custom_schema.sh /opt/scripts/
mv /tmp/script/13-Create_custom_schema_attr.sh /opt/scripts/
chmod +x /opt/scripts/*.sh /opt/scripts/replica/*.sh /opt/scripts/replica/test/*.sh
```

### 3. Run replica installer (self-signed TLS — default, recommended)

```bash
cd /opt/scripts

export MASTER_IP=<MASTER_PRIVATE_IP>         # e.g. 10.30.1.10
export ADMIN_PW=<MASTER_ADMIN_PASSWORD>       # must match master's cn=admin password
export REPL_PW=<REPLICATION_PASSWORD>         # must match master's cn=replicator password
export BASE_DN=dc=eab,dc=bank,dc=local        # must match master
export LDAPTLS_REQCERT=never

bash install-symas-openldap-replica-all-in-one.sh
```

#### What the replica installer does (in order)

```
r1-install-symas-openldap-replica  → Install Symas OpenLDAP packages
r2-configure-replica-instance      → Initialise cn=config with SERVER_ID, olcSyncRepl, olcUpdateRef
r3-start-replica-daemon            → Enable/start systemd service
r4-fix-replica-env                 → Create /etc/profile.d/symas_env.sh
       load schemas                → Load cosine, inetorgperson, custom bank schema
r5-configure-replica-tls           → Generate self-signed CA + server cert (no master dependency)
r6-fix-replica-ldapi-acl           → Fix SASL/EXTERNAL manage ACL on cn=config
r7-harden-replica                  → Disable anonymous bind, require TLS for simple binds
r8-tune-replica                    → LimitNOFILE=524288, restart
r9-verify-replica                  → Verify: service, ports, syncrepl, read-only, sync from master
tests                              → Connection, read-only enforcement, sync test
```

### 4. Replica environment variables reference

| Variable | Required | Default | Description |
|---|---|---|---|
| `MASTER_IP` | **yes** | — | Master's IP/hostname (must be reachable on LDAP port 389) |
| `ADMIN_PW` | **yes** | — | Admin password (must match master's `cn=admin`) |
| `REPL_PW` | no | `replpass` | Replication bind password (must match master's `cn=replicator`) |
| `BASE_DN` | no | `dc=eab,dc=bank,dc=local` | LDAP base DN (must match master) |
| `SERVER_ID` | no | `2` | Unique `olcServerID` — change for each additional replica (3, 4, …) |
| `COPY_FROM_MASTER` | no | `0` | `0` = self-signed TLS (default), `1` = use pre-staged CA files |
| `STAGED_CA_CERT` | if `COPY_FROM_MASTER=1` | — | Path to manually-copied CA certificate |
| `STAGED_CA_KEY` | if `COPY_FROM_MASTER=1` | — | Path to manually-copied CA private key |
| `LDAPTLS_REQCERT` | no | `never` | TLS cert verify mode for test scripts |

---

## TLS Modes Explained

### Mode A: Self-signed (default, `COPY_FROM_MASTER=0`)

Replica generates its own independent CA and server certificate. No dependency on master.

```bash
# DEFAULT — no extra env vars needed
sudo MASTER_IP=10.30.1.10 ADMIN_PW=secret \
  bash install-symas-openldap-replica-all-in-one.sh
```

| Pro | Con |
|---|---|
| Zero master dependency | Clients must trust both master and replica CAs |
| Quick lab/POC | `LDAPTLS_REQCERT=never` needed for self-signed |
| No operator intervention | Two separate PKI chains |

### Mode B: Master's CA (manual staging, `COPY_FROM_MASTER=1`)

Replica uses the same CA as master. Client that trusts the master automatically trusts the replica. **No SSH/SCP from replica — operator must manually transfer CA files.**

#### Step 1 — Extract CA files on MASTER

```bash
# ON MASTER
sudo tar czf /tmp/master-ca.tar.gz \
  -C /opt/symas/etc/openldap/tls ca.crt ca.key
sudo chmod 644 /tmp/master-ca.tar.gz
```

#### Step 2 — Transfer to REPLICA (operator's choice)

```bash
# Option A: scp FROM master (push, not pull)
#   Run on MASTER:
scp -i ~/.ssh/key.pem /tmp/master-ca.tar.gz ec2-user@<REPLICA_IP>:/tmp/

# Option B: AWS S3
#   Run on MASTER:
aws s3 cp /tmp/master-ca.tar.gz s3://your-bucket/ldap/
#   Run on REPLICA:
aws s3 cp s3://your-bucket/ldap/master-ca.tar.gz /tmp/

# Option C: Manual copy (USB, secure file transfer, etc.)
```

#### Step 3 — Extract on REPLICA

```bash
# ON REPLICA
tar xzf /tmp/master-ca.tar.gz -C /tmp/
ls -la /tmp/ca.crt /tmp/ca.key    # verify files exist
```

#### Step 4 — Run replica installer with staged CA

```bash
# ON REPLICA
cd /opt/scripts

sudo MASTER_IP=10.30.1.10 \
     ADMIN_PW=secret \
     COPY_FROM_MASTER=1 \
     STAGED_CA_CERT=/tmp/ca.crt \
     STAGED_CA_KEY=/tmp/ca.key \
     bash install-symas-openldap-replica-all-in-one.sh
```

---

## Verification

### Verify master

```bash
# Admin bind
sudo /opt/symas/bin/ldapwhoami -x -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW>

# List one level
sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> \
  -b 'dc=eab,dc=bank,dc=local' -s one dn

# Confirm replicator user exists
sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> \
  -b 'dc=eab,dc=bank,dc=local' '(cn=replicator)' dn
```

### Verify replica

```bash
# Admin bind (via StartTLS)
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapwhoami -x -ZZ \
  -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW>

# List one level (should match master)
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapsearch -LLL -x -ZZ \
  -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> \
  -b 'dc=eab,dc=bank,dc=local' -s one dn

# Confirm write is rejected (read-only enforcement)
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapadd -x -ZZ \
  -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> 2>&1 << LDIF
dn: cn=test-write,dc=eab,dc=bank,dc=local
objectClass: top
objectClass: organizationalRole
cn: test-write
LDIF
# Expected: ldap_add: Referral (10) → master
```

### Verify replication — end to end

```bash
# Create a test entry on MASTER
TEST_UID="repl-test-$(date +%Y%m%d%H%M%S)"

# On MASTER
sudo /opt/symas/bin/ldapadd -x -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> << LDIF
dn: uid=$TEST_UID,ou=Users,dc=eab,dc=bank,dc=local
objectClass: inetOrgPerson
cn: Replication Test
sn: Test
uid: $TEST_UID
LDIF

# Wait 5 seconds, then search on REPLICA
sleep 5

# On REPLICA
sudo LDAPTLS_REQCERT=never /opt/symas/bin/ldapsearch -LLL -x -ZZ \
  -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> \
  -b 'dc=eab,dc=bank,dc=local' "(uid=$TEST_UID)" dn
# Expected: dn: uid=<TEST_UID>,ou=Users,dc=eab,dc=bank,dc=local

# Cleanup on MASTER
sudo /opt/symas/bin/ldapdelete -x -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> \
  "uid=$TEST_UID,ou=Users,dc=eab,dc=bank,dc=local"
```

---

## Day-2 Operations

### Re-run replica verification at any time

```bash
sudo MASTER_IP=<MASTER_IP> ADMIN_PW=<ADMIN_PW> REPL_PW=<REPL_PW> LDAPTLS_REQCERT=never \
  bash /opt/scripts/replica/r9-verify-replica.sh
```

### Run replica test suite

```bash
cd /opt/scripts/replica/test

# Connection tests
sudo ADMIN_PW=<ADMIN_PW> REPL_PW=<REPL_PW> LDAPTLS_REQCERT=never \
  bash test_replica_connections.sh

# Read-only enforcement
sudo ADMIN_PW=<ADMIN_PW> LDAPTLS_REQCERT=never \
  bash test_replica_readonly.sh

# Sync test (write to master → verify on replica)
sudo MASTER_IP=<MASTER_IP> ADMIN_PW=<ADMIN_PW> LDAPTLS_REQCERT=never \
  bash test_replica_sync.sh
```

### Check replication status

```bash
# Show syncrepl config on replica
sudo /opt/symas/bin/ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  -LLL '(objectClass=olcMdbConfig)' olcSyncRepl olcUpdateRef

# Check replication logs
sudo journalctl -u symas-openldap-servers -n 50 --no-pager | grep -i "sync\|repl\|error"
```

### Wipe and re-install replica

```bash
# Clean OpenLDAP
sudo bash /opt/script/0-clean-openldap.sh

# Re-run installer
sudo MASTER_IP=<MASTER_IP> ADMIN_PW=<ADMIN_PW> REPL_PW=<REPL_PW> \
  bash /opt/scripts/install-symas-openldap-replica-all-in-one.sh
```

### Wipe and re-install master

```bash
# Destructive — removes all data and packages
sudo bash /opt/script/0-clean-openldap.sh

# Re-run master installer
sudo bash /opt/script/install-symas-openldap-all-in-one.sh
```

---

## Troubleshooting

### `ldapadd` / `ldapsearch` not found

```bash
source /etc/profile.d/symas_env.sh
# or
export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
```

### Replica not syncing from master

```bash
# 1. Check syncrepl config on replica
sudo /opt/symas/bin/ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  -LLL '(objectClass=olcMdbConfig)' olcSyncRepl

# 2. Verify replicator DN matches on both nodes
# On MASTER:
sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 \
  -D 'cn=admin,dc=eab,dc=bank,dc=local' -w <ADMIN_PW> \
  -b 'dc=eab,dc=bank,dc=local' '(cn=replicator)' dn

# 3. Test connectivity from replica to master
sudo /opt/symas/bin/ldapwhoami -x -H ldap://<MASTER_IP>:389 \
  -D 'cn=replicator,dc=eab,dc=bank,dc=local' -w <REPL_PW>

# 4. Check firewall/security group allows TCP 389 from replica to master
```

### Service fails to start after TLS configuration

```bash
# Verify cert paths in cn=config
sudo /opt/symas/bin/ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  -s base olcTLSCertificateFile olcTLSCertificateKeyFile olcTLSCACertificateFile

# Fix permissions
sudo chown -R symas-openldap:symas-openldap /opt/symas/etc/openldap/tls
sudo chmod 700 /opt/symas/etc/openldap/tls
sudo chmod 600 /opt/symas/etc/openldap/tls/*.key
sudo chmod 644 /opt/symas/etc/openldap/tls/*.crt
```

### Replicator user not found on master

The master must have run `26-configure-bindings.sh` (done automatically by `install-symas-openldap-all-in-one.sh`). Re-run:

```bash
# On MASTER
sudo bash /opt/script/26-configure-bindings.sh
```

### Wipe replica only (keep data safe)

```bash
# Stop service
sudo systemctl stop symas-openldap-servers

# Remove packages
sudo dnf remove -y symas-openldap-servers symas-openldap-clients

# Clean directories
sudo rm -rf /opt/symas /var/symas /etc/default/symas-openldap /etc/profile.d/symas_env.sh

# Clean dnf cache
sudo dnf clean all

# Re-run installer
sudo MASTER_IP=<MASTER_IP> ADMIN_PW=<ADMIN_PW> REPL_PW=<REPL_PW> \
  bash /opt/scripts/install-symas-openldap-replica-all-in-one.sh
```

---

## Scripts Reference

All scripts live under `script/` in the repository.

### Master scripts

| Script | Purpose |
|---|---|
| `install-symas-openldap-all-in-one.sh` | Full master installer (all steps) |
| `0-clean-openldap.sh` | Destructive reset — removes all packages + data |
| `1-install-symas-openldap.sh` | Install Symas packages via Satellite/repo |
| `3-install-example.sh` | Bootstrap database + cn=config |
| `4-Start-the-daemon.sh` | Enable + start systemd service |
| `8-create_top_ous.sh` | Create Users, Groups, Systems OUs |
| `26-configure-bindings.sh` | Create replicator user + syncprov overlay |
| `24-configure-ssl-tls.sh` | TLS certificate configuration |
| `21-hardening.sh` | Security hardening |
| `22-tuning.sh` | Performance tuning |

### Replica scripts (under `script/replica/`)

| Script | Purpose |
|---|---|
| `install-symas-openldap-replica-all-in-one.sh` | Full replica installer (all steps, in `script/`) |
| `r1-install-symas-openldap-replica.sh` | Install Symas packages |
| `r2-configure-replica-instance.sh` | Initialise cn=config with syncrepl |
| `r3-start-replica-daemon.sh` | Start systemd service |
| `r5-configure-replica-tls.sh` | Self-signed TLS (default) or staged master CA |
| `r7-harden-replica.sh` | Security hardening |
| `r9-verify-replica.sh` | Full health + sync verification |
| `test/test_replica_connections.sh` | Connection tests |
| `test/test_replica_readonly.sh` | Read-only enforcement |
| `test/test_replica_sync.sh` | Replication sync test |
