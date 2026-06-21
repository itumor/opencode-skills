# Bank OpenLDAP Pod Install — Quick Guide

## Prerequisites

Bank has its own Symas packaging. Packages must be pre-installed before running scripts.

### Required Packages

```bash
rpm -q symas-openldap-clients symas-openldap-servers
```

Dependencies auto-installed: `symas-openldap-libs`, `symas-libargon2-libs`, `symas-openldap-servers-selinux`, `libtool-ltdl`

If missing:
```bash
dnf -y install symas-openldap-clients symas-openldap-servers
```

## Env Vars Reference

| Var | Default | What it does |
|-----|---------|--------------|
| `TLS_MODE` | `yes` | Enable TLS certs + ldaps:// |
| `SKIP_PACKAGE_INSTALL` | `0` | `1` = skip dnf install (bank pre-installed) |
| `OPENLDAP_HARDEN` | `no` | `yes` = block anon binds + require TLS for simple binds |
| `LDAPTLS_REQCERT` | `demand` | Client cert verify. `never` for self-signed |
| `COPY_FROM_MASTER` | `0` | `0` = detect existing certs; `1` = copy CA from staged path |
| `STAGED_CA_CERT` | — | Path to pre-staged CA cert (only if `COPY_FROM_MASTER=1`) |
| `STAGED_CA_KEY` | — | Path to pre-staged CA key (only if `COPY_FROM_MASTER=1`) |

## Install Steps

### 1. Pre-stage Bank TLS Certs (both nodes)

```bash
mkdir -p /opt/symas/etc/openldap/tls
cp /path/to/bank-ldap.crt /opt/symas/etc/openldap/tls/ldap.crt
cp /path/to/bank-ldap.key /opt/symas/etc/openldap/tls/ldap.key
cp /path/to/bank-ca.crt   /opt/symas/etc/openldap/tls/ca.crt
chmod 600 /opt/symas/etc/openldap/tls/ldap.key
```

Scripts detect existing certs and skip generation.

### 2. Master (172.23.11.236)

```bash
cd /opt/scripts
TLS_MODE=yes SKIP_PACKAGE_INSTALL=1 \
  bash install-symas-openldap-all-in-one.sh
```

### 3. Replica (172.23.11.237)

```bash
cd /opt/scripts
MASTER_IP=172.23.11.236 \
ADMIN_PW=TheN1le1 \
REPL_PW=replpass \
BASE_DN=dc=eab,dc=bank,dc=local \
TLS_MODE=yes \
SKIP_PACKAGE_INSTALL=1 \
bash install-symas-openldap-replica-all-in-one.sh
```

## Verification

```bash
# Master
ldapsearch -x -ZZ -H ldap://172.23.11.236 \
  -D cn=admin,dc=eab,dc=bank,dc=local -w TheN1le1 \
  -b dc=eab,dc=bank,dc=local -s base contextCSN

# Replica
ldapsearch -x -ZZ -H ldap://172.23.11.237 \
  -D cn=admin,dc=eab,dc=bank,dc=local -w TheN1le1 \
  -b dc=eab,dc=bank,dc=local -s base contextCSN

# Both must return the same contextCSN.
```

## E2E Verified (2026-06-21)

AWS lab (us-west-2), Symas 2.6.13, RHEL 9:

| Node | Verify | Fix | Notes |
|------|--------|-----|-------|
| Master | PASS 18/18 | PASS 21/21 | TLS, idletimeout, orclisenabled caseIgnoreMatch |
| Replica | PASS 19/19 | PASS 17/17 | Sync OK, contextCSN match, read-only enforced |

`SKIP_PACKAGE_INSTALL=1` tested working on both nodes.
