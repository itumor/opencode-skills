# LDAP Implementation Notes (Design-Aligned)

This repo now implements the requested design alignment in automation scripts.

## 1) Custom schema naming and OID governance

- `12-Create_custom_schema.sh` now creates schema containers using `SCHEMA_NAME` (default: `bank-custom`) and skips if already present.
- `13-Create_custom_schema_attr.sh` now:
  - Targets schema by `SCHEMA_NAME`
  - Uses `OID_ROOT` (default: `1.3.6.1.4.1.55555`) for all custom attributes/objectClasses
  - Supports custom attribute/objectClass names via env vars
  - Is idempotent (skips entries already present)

Example:

```bash
SCHEMA_NAME=nxte-custom \
OID_ROOT=1.3.6.1.4.1.99999 \
OBJECTCLASS_NAME=nxteUserExtension \
bash script/13-Create_custom_schema_attr.sh
```

## 2) TLS transport decision (no SSL)

- `24-configure-ssl-tls.sh` now explicitly enforces a TLS-only model and documents listener mode.
- New variable: `LDAP_LISTENER_MODE`
  - `starttls_and_ldaps` (default): `ldap:/// ldaps:/// ldapi:///`
  - `ldaps_only`: `ldaps:/// ldapi:///`

Example:

```bash
LDAP_LISTENER_MODE=ldaps_only bash script/24-configure-ssl-tls.sh
```

## 3) Accesslog auditing for admin/system/user operations

- New script: `25-configure-accesslog-audit.sh`
  - Loads `accesslog` module if missing
  - Creates dedicated accesslog MDB database (suffix `cn=accesslog`)
  - Attaches accesslog overlay to the primary user DB
  - Enables audit operations: `writes reads session`

Key variables:

- `ACCESSLOG_SUFFIX` (default `cn=accesslog`)
- `ACCESSLOG_DB_DIR` (default `/opt/symas/var/openldap-accesslog`)
- `ACCESSLOG_PURGE` (default `30+00:00 01+00:00`)
- `ACCESSLOG_OPS` (default `writes reads session`)
- `TARGET_DB_DN` or `TARGET_SUFFIX` (optional explicit targeting)

## 4) Bind identities ("who binds as whom")

- New script: `26-configure-bindings.sh`
  - Creates (or updates) the replication bind user `cn=replicator,<BASE_DN>`
  - Ensures the replication read ACL is first in `olcAccess` for the target DB
  - Verifies the replication bind can authenticate and read the base DN

Key variables:

- `BASE_DN` (default `dc=eab,dc=bank,dc=local`)
- `REPL_DN` (default `cn=replicator,<BASE_DN>`)
- `REPL_PW` (default `replpass`)
- `UPDATE_REPL_PW` (default `0`)

## 5) Installers and tests updated

- `install-symas-openldap-all-in-one.sh` now runs:
  - `13-Create_custom_schema_attr.sh` (fixed filename)
  - `25-configure-accesslog-audit.sh`
  - `26-configure-bindings.sh`
  - test `test_accesslog_audit.sh`
  - test `test_bindings.sh`
