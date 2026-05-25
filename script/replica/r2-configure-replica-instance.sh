#!/usr/bin/env bash
# r2-configure-replica-instance.sh
#
# Initialises the OpenLDAP instance on the replica node.
# Uses slapd.conf (with schema includes) converted to cn=config via slaptest.
# This ensures core/cosine/inetorgperson schemas load in the correct order.
#
# Does NOT create any data — data arrives via syncrepl from master.
#
# Requires:
#   MASTER_IP   - IP or hostname of master
#   BASE_DN     - LDAP base DN (default: dc=eab,dc=bank,dc=local)
#   SERVER_ID   - olcServerID for this replica (default: 2)
#   ADMIN_PW    - Admin password (must match master)
#   REPL_PW     - Replication bind password (must match master cn=replicator)
#   LDAP_PORT   - Master LDAP port (default: 389)
#
# Usage:
#   sudo MASTER_IP=10.0.0.1 ADMIN_PW=secret REPL_PW=replpass bash r2-configure-replica-instance.sh
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
require_cmd slaptest

MASTER_IP="${MASTER_IP:?MASTER_IP is required (IP/hostname of master)}"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
SERVER_ID="${SERVER_ID:-2}"
ADMIN_PW="${ADMIN_PW:?ADMIN_PW is required}"
REPL_PW="${REPL_PW:-replpass}"
REPL_DN="${REPL_DN:-cn=replicator,${BASE_DN}}"
LDAP_PORT="${LDAP_PORT:-389}"

SLAPD_D="/opt/symas/etc/openldap/slapd.d"
SLAPD_CONF="/opt/symas/etc/openldap/slapd.conf"
DB_DIR="/var/symas/openldap-data/example"
SCHEMA_DIR="/opt/symas/etc/openldap/schema"
DEFAULTS_FILE="/etc/default/symas-openldap"

log "Configuring replica (SERVER_ID=${SERVER_ID}, MASTER_IP=${MASTER_IP}, BASE_DN=${BASE_DN})"

# Hash password
ADMIN_HASH="$(slappasswd -s "$ADMIN_PW")"

# Stop service if running
systemctl stop symas-openldap-servers 2>/dev/null || systemctl stop slapd 2>/dev/null || true
sleep 2

# Ensure directories exist and are clean
log "Preparing directories"
mkdir -p "$SLAPD_D" "$DB_DIR"
find "$SLAPD_D" -mindepth 1 -delete 2>/dev/null || rm -rf "${SLAPD_D:?}/"* 2>/dev/null || true
rm -rf "${DB_DIR:?}/"* 2>/dev/null || true

# Detect available schema files (.schema or .ldif)
schema_include() {
  local name="$1"
  if [[ -f "${SCHEMA_DIR}/${name}.schema" ]]; then
    echo "include ${SCHEMA_DIR}/${name}.schema"
  elif [[ -f "${SCHEMA_DIR}/${name}.ldif" ]]; then
    # Will be handled by ldapadd after service starts
    echo "# ${name}.ldif will be loaded after service start"
  fi
}

# Write slapd.conf with schema includes
log "Writing slapd.conf with schema includes"
cat > "$SLAPD_CONF" << SLAPDEOF
$(schema_include core)
$(schema_include cosine)
$(schema_include inetorgperson)

serverID ${SERVER_ID}

moduleload back_mdb.la
moduleload syncprov.la

database config
rootpw ${ADMIN_HASH}

access to *
  by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage
  by * none

database mdb
suffix "${BASE_DN}"
rootdn "cn=admin,${BASE_DN}"
rootpw ${ADMIN_HASH}
directory ${DB_DIR}
index default eq
index objectClass,cn,uid,entryUUID,entryCSN

syncrepl rid=101
  provider=ldap://${MASTER_IP}:${LDAP_PORT}
  bindmethod=simple
  binddn="${REPL_DN}"
  credentials=${REPL_PW}
  searchbase="${BASE_DN}"
  type=refreshAndPersist
  retry="5 5 300 5"
  timeout=1
  starttls=no

updateref ldap://${MASTER_IP}:${LDAP_PORT}

database monitor
SLAPDEOF

# Convert slapd.conf to cn=config via slaptest
log "Converting slapd.conf to cn=config via slaptest"
slaptest -f "$SLAPD_CONF" -F "$SLAPD_D" && log "slaptest OK"

# If .schema files not available, we loaded LDIF schemas later — note for r3
if ! [[ -f "${SCHEMA_DIR}/core.schema" ]]; then
  log "Note: .schema files not present — schemas will be loaded via ldapadd after service start"
  # Mark for schema post-load
  touch /tmp/replica-needs-schema-load
fi

# Fix SELinux context
if command -v restorecon >/dev/null 2>&1; then
  restorecon -Rv "$SLAPD_D" 2>/dev/null || true
  log "SELinux context restored on ${SLAPD_D}"
elif command -v chcon >/dev/null 2>&1; then
  chcon -Rt slapd_db_t "$SLAPD_D" 2>/dev/null || true
fi

# Configure SLAPD_URLS
if [[ -f "$DEFAULTS_FILE" ]]; then
  if grep -q '^SLAPD_URLS=' "$DEFAULTS_FILE"; then
    sed -i 's|^SLAPD_URLS=.*|SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"|' "$DEFAULTS_FILE"
  else
    echo 'SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"' >> "$DEFAULTS_FILE"
  fi
  log "Set SLAPD_URLS in ${DEFAULTS_FILE}"
fi

log "Replica cn=config initialised via slapd.conf+slaptest"
log "Syncrepl: provider=ldap://${MASTER_IP}:${LDAP_PORT}, binddn=${REPL_DN}"
log "Run 3-install-example approach: custom schema will be loaded by r3/r5 after service starts"
