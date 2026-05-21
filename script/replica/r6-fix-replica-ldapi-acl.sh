#!/usr/bin/env bash
# r6-fix-replica-ldapi-acl.sh
#
# Ensures SASL/EXTERNAL has manage access to cn=config on replica.
# Mirrors 8.0-fix_ldapi_acl.sh from master but replica-aware:
#   - Does NOT reset olcRootPW (data synced from master)
#   - Does NOT add syncprov (replica is consumer only)
#   - Only fixes cn=config ACL
#
# Usage: sudo bash r6-fix-replica-ldapi-acl.sh
set -euo pipefail

log()   { echo -e "[INFO] $*"; }
warn()  { echo -e "[WARN] $*"; }
fatal() { echo -e "[FAIL] $*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  [[ -f "$prof" ]] && source "$prof" 2>/dev/null || true
  [[ ":${PATH}:" == *":/opt/symas/bin:"* ]]  || export PATH="/opt/symas/bin:${PATH}"
  [[ ":${PATH}:" == *":/opt/symas/sbin:"* ]] || export PATH="/opt/symas/sbin:${PATH}"
}
ensure_symas_env

LDAPI_CANDIDATES=(
  ldapi:///
  "ldapi://%2Fvar%2Fsymas%2Frun%2Fldapi"
  "ldapi://%2Fvar%2Frun%2Fslapd%2Fldapi"
  "ldapi://%2Frun%2Fslapd%2Fldapi"
)
LDAPI_URI=""
for u in "${LDAPI_CANDIDATES[@]}"; do
  if ldapwhoami -Y EXTERNAL -H "$u" >/dev/null 2>&1; then
    LDAPI_URI="$u"
    break
  fi
done
[[ -n "$LDAPI_URI" ]] || fatal "Cannot find active ldapi socket"
log "Using ldapi socket: ${LDAPI_URI}"

# Check EXTERNAL identity
log "Checking SASL/EXTERNAL identity"
ldapwhoami -Y EXTERNAL -H "$LDAPI_URI"

# Check if manage ACL already set on cn=config
current_acl=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "cn=config" \
  -s base -LLL olcAccess 2>/dev/null | grep -i "manage" || true)

if echo "$current_acl" | grep -qi "peercred.*manage\|manage.*peercred"; then
  log "cn=config manage ACL already set"
  exit 0
fi

log "Manage ACL missing — patching cn=config offline"

# Detect service name
detect_svc() {
  for svc in symas-openldap-servers slapd; do
    if systemctl list-units --type=service 2>/dev/null | grep -q "$svc"; then
      echo "$svc"; return
    fi
  done
  echo "symas-openldap-servers"
}
SVC="$(detect_svc)"

# Find cn=config LDIF file (dynamic name on Symas 2.6.x)
CONFIG_DIR="/opt/symas/etc/openldap/slapd.d/cn=config"
CONFIG_LDIF=""
for candidate in \
  "${CONFIG_DIR}/olcDatabase={0}config.ldif" \
  "${CONFIG_DIR}/olcDatabase=config.ldif"; do
  if [[ -f "$candidate" ]]; then
    CONFIG_LDIF="$candidate"
    break
  fi
done
# Fallback: search dynamically
if [[ -z "$CONFIG_LDIF" ]]; then
  CONFIG_LDIF="$(find "$CONFIG_DIR" -maxdepth 1 -name 'olcDatabase*config*' 2>/dev/null | head -1 || true)"
fi
[[ -n "$CONFIG_LDIF" ]] || fatal "Cannot find olcDatabase=config LDIF in ${CONFIG_DIR}"

log "Stopping service: ${SVC}"
systemctl stop "$SVC"
sleep 2

# Ensure ownership
chown -R root:root "/opt/symas/etc/openldap/slapd.d" 2>/dev/null || true

# Patch: replace olcAccess in config LDIF with manage rule
MANAGE_RULE='olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * none'
if grep -q "^olcAccess:" "$CONFIG_LDIF"; then
  sed -i '/^olcAccess:/d' "$CONFIG_LDIF"
fi

# Also remove any dangling continuation lines from a previous corrupted edit
# (lines starting with space that aren't legitimate LDIF continuations after a known attr)
# Safest: only remove lines that are orphaned manage/none continuations
sed -i '/^ .*cn=auth manage by \* none/d' "$CONFIG_LDIF"

# Append the correct ACL
echo "$MANAGE_RULE" >> "$CONFIG_LDIF"

# Refresh checksums — slaptest will rewrite the CRC line
slaptest -F "/opt/symas/etc/openldap/slapd.d" -u 2>/dev/null || true

# Restore SELinux context on slapd.d after offline edit
if command -v restorecon >/dev/null 2>&1; then
  restorecon -Rv "/opt/symas/etc/openldap/slapd.d" 2>/dev/null || true
elif command -v chcon >/dev/null 2>&1; then
  chcon -Rt slapd_db_t "/opt/symas/etc/openldap/slapd.d" 2>/dev/null || true
fi

log "Starting service: ${SVC}"
systemctl start "$SVC"
sleep 3

systemctl is-active --quiet "$SVC" || fatal "${SVC} failed to start after ACL patch"

# Verify
if ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "cn=config" -s base -LLL olcAccess 2>/dev/null \
     | grep -qi "peercred.*manage\|manage.*peercred"; then
  log "ACL patch verified — EXTERNAL manage access confirmed"
else
  warn "ACL patch may not have applied — check cn=config manually"
fi
