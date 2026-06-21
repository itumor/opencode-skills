# Key Environment Variables

## Master Install

### `script/install-symas-openldap-all-in-one.sh`

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `TLS_MODE` | No | `yes` | `yes` or `no` — enables TLS hardening |

Usage:
```bash
sudo bash script/install-symas-openldap-all-in-one.sh
sudo TLS_MODE=no bash script/install-symas-openldap-all-in-one.sh
```

---

## Replica Install

### `script/install-symas-openldap-replica-all-in-one.sh`

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MASTER_IP` | **Yes** | — | Master IP/hostname |
| `ADMIN_PW` | **Yes** | — | Admin password (must match master) |
| `REPL_PW` | No | `replpass` | Replicator bind password |
| `BASE_DN` | No | `dc=eab,dc=bank,dc=local` | LDAP base DN |
| `SERVER_ID` | No | `2` | olcServerID for this replica |
| `TLS_MODE` | No | `yes` | `yes` or `no` — when `no`, skips TLS |
| `LDAPTLS_REQCERT` | No | `never` | TLS verify mode for tests |
| `COPY_FROM_MASTER` | No | `0` | `0`=self-signed CA (default), `1`=use staged master CA |
| `STAGED_CA_CERT` | No | — | Path to pre-staged CA cert (if `COPY_FROM_MASTER=1`) |
| `STAGED_CA_KEY` | No | — | Path to pre-staged CA key (if `COPY_FROM_MASTER=1`) |

Usage:
```bash
sudo MASTER_IP=10.0.0.1 ADMIN_PW=secret bash script/install-symas-openldap-replica-all-in-one.sh

# With master's CA:
sudo MASTER_IP=10.0.0.1 ADMIN_PW=secret \
  COPY_FROM_MASTER=1 STAGED_CA_CERT=/tmp/ca.crt STAGED_CA_KEY=/tmp/ca.key \
  bash script/install-symas-openldap-replica-all-in-one.sh

# Without TLS:
sudo MASTER_IP=10.0.0.1 ADMIN_PW=secret TLS_MODE=no \
  bash script/install-symas-openldap-replica-all-in-one.sh
```

---

## Replica Sub-Scripts (r1–r9)

### `r1-install-symas-openldap-replica.sh`

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SKIP_REPO_SETUP` | No | `auto` | Set to `1` for Satellite-managed repos |
| `SYMAS_REPO_URL` | No | Symas release26.repo | Explicit repo URL for test/dev |

### `r2-configure-replica-instance.sh`

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MASTER_IP` | **Yes** | — | Master IP/hostname |
| `ADMIN_PW` | **Yes** | — | Admin password |
| `BASE_DN` | No | `dc=eab,dc=bank,dc=local` | LDAP base DN |
| `SERVER_ID` | No | `2` | olcServerID |
| `REPL_PW` | No | `replpass` | Replicator password |
| `REPL_DN` | No | `cn=replicator,${BASE_DN}` | Replicator DN |
| `LDAP_PORT` | No | `389` | LDAP port |
| `TLS_MODE` | No | `yes` | `yes` or `no` |

### `r5-configure-replica-tls.sh`

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `COPY_FROM_MASTER` | No | `0` | `0`=self-signed, `1`=use staged CA |
| `STAGED_CA_CERT` | No | — | Path to master CA cert |
| `STAGED_CA_KEY` | No | — | Path to master CA key |
| `TLS_DIR` | No | `/opt/symas/etc/openldap/tls` | TLS material directory |
| `CA_DAYS` | No | `3650` | CA cert validity (days) |
| `SERVER_DAYS` | No | `825` | Server cert validity (days) |
| `LDAPTLS_REQCERT` | No | `never` | TLS verification level |

### `r7-harden-replica.sh`

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OPENLDAP_HARDEN` | No | `no` | Set to `yes` to enable hardening |
| `BASE_DN` | No | `dc=eab,dc=bank,dc=local` | LDAP base DN |
| `TLS_PROTOCOL_MIN` | No | `3.3` | Minimum TLS protocol |
| `TLS_CIPHER_SUITE` | No | `HIGH:!aNULL:!eNULL:!MD5:!RC4:!3DES:!DES:!NULL` | TLS cipher suite |
| `SIMPLE_BIND_SSF` | No | `128` | Simple bind SSF (set `0` to disable) |

### `r8-tune-replica.sh`

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `LIMIT_NOFILE` | No | `524288` | File descriptor limit |
| `SLAPD_URLS` | No | — | Override SLAPD_URLS in defaults |
| `SLAPD_OPTIONS` | No | — | Override SLAPD_OPTIONS in defaults |

### `r9-verify-replica.sh`

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MASTER_IP` | No | — | Master IP for sync verification |
| `BASE_DN` | No | `dc=eab,dc=bank,dc=local` | LDAP base DN |
| `ADMIN_DN` | No | `cn=admin,${BASE_DN}` | Admin DN |
| `ADMIN_PW` | No | — | Admin password |
| `TLS_MODE` | No | `yes` | `yes` or `no` |

---

## TLS Configuration

### `script/24-configure-ssl-tls.sh`

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `TLS_DIR` | No | `/opt/symas/etc/openldap/tls` | TLS material directory |
| `TLS_CERT_MODE` | No | `external_or_self_signed` | Cert provisioning mode |
| `CA_CERT` | No | `${TLS_DIR}/ca.crt` | CA cert path |
| `CA_KEY` | No | `${TLS_DIR}/ca.key` | CA key path |
| `SERVER_CERT` | No | `${TLS_DIR}/ldap.crt` | Server cert path |
| `SERVER_KEY` | No | `${TLS_DIR}/ldap.key` | Server key path |
| `CA_DAYS` | No | `3650` | CA cert validity (days) |
| `SERVER_DAYS` | No | `825` | Server cert validity (days) |
| `TLS_PROTOCOL_MIN` | No | `3.3` | Minimum TLS protocol |
| `TLS_CIPHER_SUITE` | No | — | TLS cipher suite |
| `TLS_VERIFY_CLIENT` | No | — | Client verification level |
| `TLS_REQCERT` | No | — | TLS verify mode |
| `LDAP_LISTENER_MODE` | No | `starttls_and_ldaps` | Listener mode |
| `TLS_CA_CERT_PEM` | No | — | PEM-encoded CA cert (external mode) |
| `TLS_CERT_PEM` | No | — | PEM-encoded server cert (external mode) |
| `TLS_KEY_PEM` | No | — | PEM-encoded server key (external mode) |
| `TLS_DNS_NAMES` | No | — | Extra SAN DNS names (space separated) |
| `TLS_IPS` | No | — | Extra SAN IPs (space separated) |
| `FORCE_REGEN_CA` | No | `0` | Set to `1` to force CA regeneration |
| `FORCE_REGEN_SERVER` | No | `0` | Set to `1` to force server cert regeneration |
| `LDAP_CONF` | No | `/opt/symas/etc/openldap/ldap.conf` | ldap.conf path |
| `SLAPD_DEFAULTS` | No | `/etc/default/symas-openldap` | Service defaults file |
| `CONFIG_LDIF` | No | `.../slapd.d/cn=config.ldif` | cn=config LDIF path |

---

## Fix & Verify Scripts

### `bank-fix-all.sh` — One-script master+replica fix

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BASE_DN` | No | `dc=eab,dc=bank,dc=local` | LDAP base DN |
| `ADMIN_PW` | No | `TheN1le1` | Admin password |
| `REPL_PW` | No | `replpass` | Replicator password |
| `SLAPD_SVC` | No | `symas-openldap-servers` | Service name |

### `fix-master.sh`

Auto-detects — no required env vars.

### `fix-replica.sh`

Auto-detects — no required env vars.

### `verify-master.sh`

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ADMIN_PW` | No | `admin` | Admin password |
| `REPL_PW` | No | `replpass` | Replicator password |
| `BASE_DN` | No | `dc=eab,dc=bank,dc=local` | LDAP base DN |

### `verify-replica.sh`

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ADMIN_PW` | No | `TheN1le1` | Admin password |
| `REPL_PW` | No | `replpass` | Replicator password |
| `BASE_DN` | No | `dc=eab,dc=bank,dc=local` | LDAP base DN |

### `verify-post-fix.sh`

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MASTER_IP` | No | — | Master IP for sync check |
| `BASE_DN` | No | `dc=eab,dc=bank,dc=local` | LDAP base DN |
| `ADMIN_DN` | No | `cn=admin,${BASE_DN}` | Admin DN |
| `ADMIN_PW` | No | — | Admin password |
| `REPL_DN` | No | `cn=replicator,${BASE_DN}` | Replicator DN |
| `REPL_PW` | No | `replpass` | Replicator password |

---

## User Creation

### `script/19-create-user-using-mw-user.sh`

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DRY_RUN` | No | `0` | Preview without writing |
| `LDAP_URI` | No | `ldap://localhost` | LDAP server URI |
| `USE_STARTTLS` | No | `0` | Use StartTLS (0/1) |
| `LDAPTLS_REQCERT` | No | `never` | TLS verify mode |
| `MW_BIND_DN` | No | `uid=mw,ou=ServiceAccounts,...` | Bind DN |
| `MW_BIND_PW` | No | `ChangeMe123!` | Bind password |
| `USER_BASE_DN` | No | `ou=Users,dc=eab,dc=bank,dc=local` | User container DN |
| `USER_UID` | No | `mwuser1` | User uid |
| `USER_CN` | No | `$USER_UID` | User cn |
| `USER_SN` | No | `User` | User surname |
| `USER_GIVENNAME` | No | `MW` | User given name |
| `USER_MAIL` | No | — | User email |
| `USER_PASSWORD` | No | `ChangeMe123!` | User password (cleartext) |
| `USER_PASSWORD_HASH` | No | — | User password (hash, overrides USER_PASSWORD) |
| `ALLOW_EXISTING` | No | `0` | Don't error if user exists |
| `INCLUDE_BANK_EXTENSION` | No | `0` | Add bank objectClass/attributes |
| `USER_IS_ACTIVE` | No | `TRUE` | Account status |
| `USER_CIF` | No | — | Bank CIF number |
| `USER_ACTIVATION_DATETIME` | No | — | Activation datetime |
| `USER_MEMORABLE_QUESTION` | No | — | Security question |
| `USER_MEMORABLE_ANSWER` | No | — | Security answer |

---

## Password Policy

### `script/bank-apply-password-policy.sh`

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BASE_DN` | No | `dc=eab,dc=bank,dc=local` | LDAP base DN |
| `ADMIN_PW` | No | `TheN1le1` | Admin password |
| `PWD_MIN_LENGTH` | No | `8` | Minimum password length |
| `PWD_MAX_LENGTH` | No | `128` | Max password length (ppolicy) |
| `PWD_MIN_UPPER` | No | `1` | Minimum uppercase chars |
| `PWD_MIN_LOWER` | No | `1` | Minimum lowercase chars |
| `PWD_MIN_DIGIT` | No | `1` | Minimum digit chars |
| `PWD_ALLOWED_SPECIAL` | No | `!@#$%^&*()_+-=[]{};:,.<>?/~` | Special chars |
| `PWD_MAX_AGE` | No | `10368000` | Max password age (seconds, ~4 months) |
| `PWD_EXPIRE_WARNING` | No | `1296000` | Expire warning (seconds, ~15 days) |
| `PWD_IN_HISTORY` | No | `5` | Number of passwords remembered |
| `PWD_MAX_FAILURE` | No | `5` | Max failed binds before lockout |
| `PWD_LOCKOUT_DURATION` | No | `1800` | Lockout duration (seconds) |
| `PWD_MIN_AGE` | No | `0` | Minimum password age (seconds) |
| `PPM_CONF` | No | `/opt/symas/etc/openldap/ppm.conf` | PPM config file path |

---

## Deploy Script (Local)

### `deploy-tls-lab.sh`

Hardcoded for AWS lab — no env vars, edit IPs in the file.

---

## Quick Reference — Common Combos

```bash
# Master install (defaults)
sudo bash script/install-symas-openldap-all-in-one.sh

# Replica install (minimal)
sudo MASTER_IP=10.0.0.1 ADMIN_PW=TheN1le1 \
  bash script/install-symas-openldap-replica-all-in-one.sh

# Replica install (custom DN + self-signed TLS)
sudo MASTER_IP=10.0.0.1 ADMIN_PW=secret \
  BASE_DN=dc=example,dc=com REPL_PW=replsecret SERVER_ID=2 \
  bash script/install-symas-openldap-replica-all-in-one.sh

# Replica install (no TLS)
sudo MASTER_IP=10.0.0.1 ADMIN_PW=secret TLS_MODE=no \
  bash script/install-symas-openldap-replica-all-in-one.sh

# Replica install (using master's CA cert)
sudo MASTER_IP=10.0.0.1 ADMIN_PW=secret \
  COPY_FROM_MASTER=1 STAGED_CA_CERT=/tmp/ca.crt STAGED_CA_KEY=/tmp/ca.key \
  bash script/install-symas-openldap-replica-all-in-one.sh

# Fix bank deployment (auto-detects master/replica)
sudo BASE_DN=dc=eab,dc=bank,dc=local ADMIN_PW=TheN1le1 \
  bash script/bank-fix-all.sh

# Verify master
sudo ADMIN_PW=TheN1le1 bash script/verify-master.sh

# Verify replica
sudo ADMIN_PW=TheN1le1 bash script/verify-replica.sh

# TLS configure standalone
sudo TLS_DIR=/opt/symas/etc/openldap/tls CA_DAYS=365 \
  bash script/24-configure-ssl-tls.sh
```
