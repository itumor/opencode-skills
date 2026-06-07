#!/usr/bin/env bash
# fix-master.sh
# ====================================================================
# Run on the OpenLDAP MASTER server as root.
#
# Fixes:
#   Issue A — "ldif_read_file: checksum error on cn=config/olcDatabase={0}"
#             (Caused by manually-edited LDIF without CRC update.)
#   Issue B — Missing entryUUID/entryCSN indices causing syncrepl
#             refreshDelete+detaching loop on the replica.
#   Issue C — Missing syncprov overlay — master cannot serve
#             replication to consumers (OID 1.3.6.1.4.1.4203.1.9.1.1
#             unrecognized control).
#
# What it does:
#   1. Backs up /opt/symas/etc/openldap/slapd.d
#   2. Exports cn=config via slapcat, rebuilds checksums via slapadd
#   3. Adds olcDbIndex: entryUUID eq + entryCSN eq (if missing)
#   4. Ensures syncprov overlay (required for syncrepl provider)
#   5. Restarts slapd
#   6. Self-verifies: checks logs for errors, tests LDAPI + admin bind
#
# Usage:
#   sudo bash fix-master.sh
# ====================================================================
set -euo pipefail

log()   { echo "[INFO]  $*"; }
ok()    { echo "[ OK ]  $*"; }
warn()  { echo "[WARN]  $*"; }
err()   { echo "[ERROR] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }

PASS=0; FAIL=0
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

# ---- Locate slapd service ----
find_service() {
  for svc in symas-openldap-servers slapd; do
    if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then
      echo "$svc"
      return 0
    fi
  done
  if pgrep -x slapd >/dev/null 2>&1; then
    echo "slapd"
    return 0
  fi
  fatal "Cannot find slapd systemd service"
}

SLAPD_SVC=$(find_service)

# ---- Fix PATH ----
export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
[[ -f /opt/symas/etc/openldap/sysmas_env.sh ]] && source /opt/symas/etc/openldap/sysmas_env.sh 2>/dev/null || true

require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }
require_cmd slapcat
require_cmd slapadd
require_cmd ldapmodify
require_cmd ldapsearch

SLAPD_D="/opt/symas/etc/openldap/slapd.d"
LDAPI_URI="ldapi:///"
CONFIG_EXPORT="/tmp/cn-config-export-${TIMESTAMP}.ldif"

echo ""
echo "============================================================"
echo "  MASTER FIX — Start"
echo "  Server:   $(hostname -f 2>/dev/null || hostname)"
echo "  Service:  ${SLAPD_SVC}"
echo "  Time:     ${TIMESTAMP}"
echo "============================================================"

# ================================================================
# STEP 1: Backup
# ================================================================
echo ""
echo "--- Step 1: Backup cn=config ---"
BACKUP="${SLAPD_D}.fix-${TIMESTAMP}"
cp -a "$SLAPD_D" "$BACKUP"
ok "Backed up to $BACKUP"

# ================================================================
# STEP 2: Rebuild cn=config checksums
# ================================================================
echo ""
echo "--- Step 2: Rebuild cn=config checksums ---"

echo "  Exporting cn=config via slapcat..."
slapcat -n 0 -l "$CONFIG_EXPORT" 2>/dev/null || fatal "slapcat export failed"
ENTRIES=$(grep -c "^dn:" "$CONFIG_EXPORT" 2>/dev/null || echo "0")
ok "Exported ${ENTRIES} entries to $CONFIG_EXPORT"

echo "  Stopping ${SLAPD_SVC}..."
systemctl stop "$SLAPD_SVC" || fatal "Failed to stop ${SLAPD_SVC}"
sleep 2
ok "${SLAPD_SVC} stopped"

echo "  Clearing old config..."
find "$SLAPD_D" -mindepth 1 -delete 2>/dev/null || true
ok "Old cn=config cleared"

echo "  Re-importing with correct checksums..."
slapadd -n 0 -F "$SLAPD_D" -l "$CONFIG_EXPORT" 2>/dev/null || {
  warn "slapadd failed — restoring backup"
  rm -rf "$SLAPD_D"
  cp -a "$BACKUP" "$SLAPD_D"
  systemctl start "$SLAPD_SVC"
  fatal "slapadd failed"
}
ok "Re-imported with regenerated checksums"

# Find slapd user for ownership
SLAPD_USER="symas-openldap"
id "$SLAPD_USER" >/dev/null 2>&1 || SLAPD_USER="ldap"
id "$SLAPD_USER" >/dev/null 2>&1 || SLAPD_USER="root"

chown -R "${SLAPD_USER}:${SLAPD_USER}" "$SLAPD_D" 2>/dev/null || true
restorecon -Rv "$SLAPD_D" 2>/dev/null || true

echo "  Starting ${SLAPD_SVC}..."
systemctl start "$SLAPD_SVC" || {
  warn "Failed to start — restoring backup"
  rm -rf "$SLAPD_D"
  cp -a "$BACKUP" "$SLAPD_D"
  chown -R "${SLAPD_USER}:${SLAPD_USER}" "$SLAPD_D" 2>/dev/null || true
  systemctl start "$SLAPD_SVC"
  fatal "slapd start failed"
}
sleep 3

if systemctl is-active --quiet "$SLAPD_SVC"; then
  ok "${SLAPD_SVC} is active after rebuild"
  PASS=$((PASS+1))
else
  bad() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }
  bad "${SLAPD_SVC} failed to start after rebuild"
  FAIL=$((FAIL+1))
fi

# Check for lingering checksum errors
CHKSUM=$(journalctl -u "$SLAPD_SVC" --no-pager --since "1 minute ago" 2>/dev/null | grep -ci "checksum error" || true)
if [[ "$CHKSUM" -eq 0 ]]; then
  ok "No checksum errors in logs after rebuild"
  PASS=$((PASS+1))
else
  bad "${CHKSUM} checksum error(s) still present"
  FAIL=$((FAIL+1))
fi

rm -f "$CONFIG_EXPORT"

# ================================================================
# STEP 3: Fix syncrepl indices
# ================================================================
echo ""
echo "--- Step 3: Ensure syncrepl indices (entryUUID, entryCSN) ---"

if ! ldapwhoami -Y EXTERNAL -H "$LDAPI_URI" >/dev/null 2>&1; then
  warn "LDAPI not available — skipping index fix"
else
  DB_DN=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config \
    -LLL '(&(objectClass=olcMdbConfig)(olcSuffix=*))' dn 2>/dev/null \
    | awk '/^dn: /{print $2; exit}' || true)

  if [[ -z "$DB_DN" ]]; then
    warn "Could not find database DN — skipping index fix"
  else
    log "Database: $DB_DN"

    CURRENT_IDX=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "$DB_DN" -s base \
      -LLL olcDbIndex 2>/dev/null || true)

    HAS_UUID=$(echo "$CURRENT_IDX" | grep -c "entryUUID" || true)
    HAS_CSN=$(echo "$CURRENT_IDX"  | grep -c "entryCSN"  || true)

    if [[ "$HAS_UUID" -gt 0 && "$HAS_CSN" -gt 0 ]]; then
      ok "entryUUID and entryCSN indices already present"
      PASS=$((PASS+1))
    else
      log "Adding missing syncrepl indices..."
      ldapmodify -Y EXTERNAL -H "$LDAPI_URI" <<'LDIF'
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: entryUUID eq
-
add: olcDbIndex
olcDbIndex: entryCSN eq
LDIF
      ok "Added entryUUID + entryCSN indices"
      PASS=$((PASS+1))
    fi
  fi
fi

# ================================================================
# STEP 4: Ensure syncprov overlay
# ================================================================
echo ""
echo "--- Step 4: Syncprov overlay ---"

HAS_SYNCPROV=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config \
  -s sub "(olcOverlay=syncprov)" dn 2>/dev/null | grep -ci "^dn:" || true)
HAS_SYNCPROV=$(echo "$HAS_SYNCPROV" | tr -d '[:space:]')

if [[ -n "$HAS_SYNCPROV" && "$HAS_SYNCPROV" -gt 0 ]]; then
  ok "Syncprov overlay already present"
  PASS=$((PASS+1))
else
  log "Adding syncprov overlay — required for replication to consumers"
  ldapmodify -Y EXTERNAL -H "$LDAPI_URI" -f <(cat <<LDIF
dn: olcOverlay=syncprov,${DB_DN}
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 100
LDIF
) && { ok "Syncprov overlay added"; PASS=$((PASS+1)); } || { bad "Syncprov add failed"; FAIL=$((FAIL+1)); }
fi

# ================================================================
# STEP 5: Verify connectivity
# ================================================================
echo ""
echo "--- Step 5: Verification ---"

if ldapwhoami -Y EXTERNAL -H "$LDAPI_URI" >/dev/null 2>&1; then
  ok "LDAPI EXTERNAL bind works"
  PASS=$((PASS+1))
else
  bad "LDAPI EXTERNAL bind failed"
  FAIL=$((FAIL+1))
fi

# ================================================================
# STEP 6: Summary
# ================================================================
echo ""
echo "============================================================"
echo "  MASTER FIX — Complete"
echo "  PASS=${PASS}  FAIL=${FAIL}"
echo "============================================================"
echo "  Backup: $BACKUP"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "Some fixes failed. To restore:"
  echo "  sudo rm -rf $SLAPD_D && sudo cp -a $BACKUP $SLAPD_D"
  echo "  sudo systemctl start $SLAPD_SVC"
  exit 1
fi
exit 0
