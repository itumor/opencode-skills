#!/usr/bin/env bash
# r2-configure-replica-instance.sh
#
# Initialises the OpenLDAP instance on the replica node.
# - Copies the master Exampledb config (same suffix/org) to establish slapd.d
# - Sets olcServerID (must differ from master, default 2)
# - Does NOT create any data — data arrives via syncrepl from master
#
# Requires:
#   MASTER_IP   - IP or hostname of master (used for syncrepl provider)
#   BASE_DN     - LDAP base DN (default: dc=eab,dc=bank,dc=local)
#   SERVER_ID   - olcServerID for this replica (default: 2)
#   ADMIN_PW    - Admin password (must match master)
#   REPL_PW     - Replication bind password (must match master cn=replicator)
#
# Usage: sudo MASTER_IP=10.0.0.1 ADMIN_PW=secret REPL_PW=replpass bash r2-configure-replica-instance.sh
set -euo pipefail

log()   { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  [[ -f "$prof" ]] && source "$prof" 2>/dev/null || true
  [[ ":${PATH}:" == *":/opt/symas/bin:"* ]]  || export PATH="/opt/symas/bin:${PATH}"
  [[ ":${PATH}:" == *":/opt/symas/sbin:"* ]] || export PATH="/opt/symas/sbin:${PATH}"
  [[ -n "${LDAPCONF:-}" ]] || export LDAPCONF="/opt/symas/etc/openldap/ldap.conf"
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }

ensure_symas_env
require_cmd slappasswd
require_cmd slapadd
require_cmd slaptest

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER_IP="${MASTER_IP:?MASTER_IP is required (IP/hostname of master)}"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
SERVER_ID="${SERVER_ID:-2}"
ADMIN_PW="${ADMIN_PW:?ADMIN_PW is required}"
REPL_PW="${REPL_PW:-replpass}"
REPL_DN="${REPL_DN:-cn=replicator,${BASE_DN}}"
LDAP_PORT="${LDAP_PORT:-389}"

SLAPD_D="/opt/symas/etc/openldap/slapd.d"
DB_DIR="/var/symas/openldap-data/example"
SBIN="/opt/symas/sbin"
SCHEMA_DIR="/opt/symas/etc/openldap/schema"
DEFAULTS_FILE="/etc/default/symas-openldap"

log "Configuring replica (SERVER_ID=${SERVER_ID}, MASTER_IP=${MASTER_IP}, BASE_DN=${BASE_DN})"

# Hash passwords
ADMIN_HASH="$(slappasswd -s "$ADMIN_PW")"
REPL_HASH="$(slappasswd -s "$REPL_PW")"

# Stop service if running
systemctl stop symas-openldap-servers 2>/dev/null || systemctl stop slapd 2>/dev/null || true

# Clean existing slapd.d and data
log "Clearing existing slapd.d and data directories"
rm -rf "${SLAPD_D:?}/"*
mkdir -p "$DB_DIR"
chown -R root:root "$DB_DIR" 2>/dev/null || true

# Build fresh cn=config LDIF for replica
TMP_CONFIG="$(mktemp /tmp/replica-config.XXXXXX.ldif)"
log "Writing cn=config LDIF to ${TMP_CONFIG}"

{
cat <<EOF
dn: cn=config
objectClass: olcGlobal
cn: config
olcLogLevel: Stats
olcServerID: ${SERVER_ID}

EOF

# Load schemas
for schema in core cosine inetorgperson; do
  if [[ -f "${SCHEMA_DIR}/${schema}.ldif" ]]; then
    cat "${SCHEMA_DIR}/${schema}.ldif"
    echo ""
  fi
done

cat <<EOF
dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulepath: /opt/symas/lib/openldap
olcModuleload: back_mdb.la
olcModuleload: syncprov.la

dn: olcDatabase=frontend,cn=config
objectClass: olcDatabaseConfig
objectClass: olcFrontendConfig
olcDatabase: frontend
olcAccess: {0}to dn="" by * read
olcAccess: {1}to * by self write by sockurl.exact="ldapi:///" write by users read by anonymous auth

dn: olcDatabase=config,cn=config
objectClass: olcDatabaseConfig
olcDatabase: config
olcRootPW: ${ADMIN_HASH}
olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * none

dn: olcDatabase=mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: mdb
olcSuffix: ${BASE_DN}
olcRootDN: cn=admin,${BASE_DN}
olcRootPW: ${ADMIN_HASH}
olcDbDirectory: ${DB_DIR}
olcDbIndex: default eq
olcDbIndex: objectClass
olcDbIndex: cn
olcDbIndex: uid
olcDbIndex: entryUUID
olcDbIndex: entryCSN
olcDbMaxSize: 1073741824
olcSyncRepl: rid=101
  provider=ldap://${MASTER_IP}:${LDAP_PORT}
  bindmethod=simple
  binddn="${REPL_DN}"
  credentials=${REPL_PW}
  searchbase="${BASE_DN}"
  type=refreshAndPersist
  retry="5 5 300 5"
  timeout=1
  starttls=critical
  tls_reqcert=never
olcUpdateRef: ldap://${MASTER_IP}:${LDAP_PORT}

dn: olcDatabase=monitor,cn=config
objectClass: olcDatabaseConfig
olcDatabase: monitor
olcRootDN: cn=config
olcMonitoring: FALSE
EOF
} > "$TMP_CONFIG"

log "Loading cn=config into slapd.d via slapadd"
"${SBIN}/slapadd" -n 0 -F "$SLAPD_D" -l "$TMP_CONFIG"
rm -f "$TMP_CONFIG"

# Fix ownership
if id -u symas-openldap >/dev/null 2>&1; then
  chown -R symas-openldap:symas-openldap "$SLAPD_D" "$DB_DIR"
fi
find "$SLAPD_D" -type d -exec chmod 700 {} + 2>/dev/null || true
find "$SLAPD_D" -type f -exec chmod 600 {} + 2>/dev/null || true

# Configure SLAPD_URLS
if [[ -f "$DEFAULTS_FILE" ]]; then
  if grep -q '^SLAPD_URLS=' "$DEFAULTS_FILE"; then
    sed -i 's|^SLAPD_URLS=.*|SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"|' "$DEFAULTS_FILE"
  else
    echo 'SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"' >> "$DEFAULTS_FILE"
  fi
  log "Set SLAPD_URLS in ${DEFAULTS_FILE}"
fi

log "Replica cn=config initialised (SERVER_ID=${SERVER_ID})"
log "Syncrepl configured: provider=ldap://${MASTER_IP}:${LDAP_PORT}, binddn=${REPL_DN}"
