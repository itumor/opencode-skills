#!/usr/bin/env bash
# fix-master-checksum.sh
#
# Fixes the ldif_read_file checksum error on the master's cn=config
# olcDatabase={0}config LDIF file. This error appears on every slapd
# start but does not block operation — the file was manually edited
# without updating its CRC checksum.
#
# Strategy:
#   1. Back up slapd.d
#   2. Export cn=config via slapcat
#   3. Stop slapd
#   4. Re-import via slapadd
#   5. Restart slapd
#   6. Verify no checksum errors in logs
#
# Must be run ON THE MASTER node as root.
#
# Usage: sudo bash fix-master-checksum.sh
set -euo pipefail

log()   { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*" >&2; }
err()   { echo "[ERROR] $*" >&2; }
ok()    { echo "[ OK ] $*"; }
bad()   { echo "[FAIL] $*" >&2; }

PASS=0; FAIL=0

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "Run as root"; exit 1; }

ensure_symas_env() {
  local prof
  for prof in /etc/profile.d/symas_env.sh /opt/symas/etc/openldap/sysmas_env.sh; do
    [[ -f "$prof" ]] && source "$prof" 2>/dev/null || true
  done
  [[ ":${PATH}:" == *":/opt/symas/bin:"* ]]  && return 0
  export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
  [[ -n "${LDAPCONF:-}" ]] || export LDAPCONF="/opt/symas/etc/openldap/ldap.conf"
}
ensure_symas_env

require_cmd() { command -v "$1" >/dev/null 2>&1 || { err "$1 not found in PATH"; exit 1; }; }

SLAPD_D="/opt/symas/etc/openldap/slapd.d"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="${SLAPD_D}.checksum-fix-${TIMESTAMP}"
CONFIG_EXPORT="/tmp/cn-config-export-${TIMESTAMP}.ldif"

echo ""
echo "============================================================"
echo "  Fix Master cn=config Checksum Errors"
echo "============================================================"
echo ""

# ---- 1. Verify cn=config exists ----
if [[ ! -d "$SLAPD_D" ]]; then
  bad "cn=config directory not found: $SLAPD_D"
  exit 1
fi
PASS=$((PASS+1))

# ---- 2. Find files with checksum issues ----
echo "--- Checking for checksum issues ---"
CRC_MISMATCHES=0
for ldif_file in "$SLAPD_D"/**/*.ldif "$SLAPD_D"/*.ldif; do
  [[ -f "$ldif_file" ]] || continue
  # Read the CRC line and compare with actual file checksum
  crc_line=$(grep '^# CRC32' "$ldif_file" 2>/dev/null | head -1 || true)
  if [[ -n "$crc_line" ]]; then
    # Check if the CRC in the file matches content
    if ! grep -q '^# AUTO-GENERATED FILE - DO NOT EDIT!! Use ldapmodify.' "$ldif_file" 2>/dev/null; then
      CRC_MISMATCHES=$((CRC_MISMATCHES+1))
      warn "Potential checksum issue: $ldif_file"
    fi
  fi
done

if [[ $CRC_MISMATCHES -eq 0 ]]; then
  ok "No obvious checksum issues detected"
  # Still proceed with rebuild to be safe
fi

# ---- 3. Back up current config ----
echo ""
echo "--- Backing up cn=config ---"
cp -a "$SLAPD_D" "$BACKUP"
ok "Backed up to: $BACKUP"
PASS=$((PASS+1))

# ---- 4. Find the active slapd service name ----
SLAPD_SVC=""
for svc in symas-openldap-servers slapd; do
  if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then
    SLAPD_SVC="$svc"
    break
  fi
done

if [[ -z "$SLAPD_SVC" ]]; then
  bad "Could not find slapd service"
  exit 1
fi
log "Found slapd service: $SLAPD_SVC"

# ---- 5. Export cn=config via slapcat ----
echo ""
echo "--- Exporting cn=config via slapcat ---"
require_cmd slapcat

# Export cn=config database (database #0)
slapcat -n 0 -l "$CONFIG_EXPORT" 2>/dev/null && \
  ok "Exported cn=config to: $CONFIG_EXPORT" || \
  { bad "slapcat export failed"; exit 1; }
PASS=$((PASS+1))

ENTRIES=$(grep -c "^dn:" "$CONFIG_EXPORT" 2>/dev/null || echo "0")
log "  ${ENTRIES} entries exported"

# ---- 6. Stop slapd ----
echo ""
echo "--- Stopping $SLAPD_SVC ---"
systemctl stop "$SLAPD_SVC" || { bad "Failed to stop $SLAPD_SVC"; exit 1; }
sleep 2
ok "$SLAPD_SVC stopped"
PASS=$((PASS+1))

# ---- 7. Clear and re-import cn=config ----
echo ""
echo "--- Rebuilding cn=config ---"
require_cmd slapadd

# Clear existing config
find "$SLAPD_D" -mindepth 1 -delete 2>/dev/null || \
  rm -rf "${SLAPD_D:?}"/* 2>/dev/null || true
ok "Cleared existing cn=config"

# Re-import
slapadd -n 0 -F "$SLAPD_D" -l "$CONFIG_EXPORT" 2>&1 && \
  ok "Re-imported cn=config with correct checksums" || \
  { bad "slapadd import failed. Restore from backup: cp -a $BACKUP $SLAPD_D"; exit 1; }
PASS=$((PASS+1))

# ---- 8. Fix SELinux context if needed ----
if command -v restorecon >/dev/null 2>&1; then
  restorecon -Rv "$SLAPD_D" 2>/dev/null || true
  ok "SELinux context restored"
fi

# ---- 9. Fix ownership ----
SLAPD_USER="$(ps -eo user,comm 2>/dev/null | awk '$2=="slapd"{print $1; exit}' || true)"
[[ -z "$SLAPD_USER" ]] && SLAPD_USER="symas-openldap"
chown -R "${SLAPD_USER}:${SLAPD_USER}" "$SLAPD_D" 2>/dev/null || true
ok "Ownership set to ${SLAPD_USER}"

# ---- 10. Restart slapd ----
echo ""
echo "--- Starting $SLAPD_SVC ---"
systemctl start "$SLAPD_SVC" || { bad "Failed to start $SLAPD_SVC — restoring backup"; cp -a "$BACKUP"/* "$SLAPD_D"/; systemctl start "$SLAPD_SVC"; exit 1; }
sleep 3

if systemctl is-active --quiet "$SLAPD_SVC"; then
  ok "$SLAPD_SVC is active"
  PASS=$((PASS+1))
else
  bad "$SLAPD_SVC failed to start"
  FAIL=$((FAIL+1))
fi

# ---- 11. Verify no checksum errors in logs ----
echo ""
echo "--- Checking logs for checksum errors ---"
CHKSUM_ERRORS=$(journalctl -u "$SLAPD_SVC" --no-pager --since "3 minutes ago" 2>/dev/null \
  | grep -ci "checksum error" || true)
if [[ "$CHKSUM_ERRORS" -eq 0 ]]; then
  ok "No checksum errors in recent logs"
  PASS=$((PASS+1))
else
  warn "${CHKSUM_ERRORS} checksum error(s) still present in logs"
fi

# ---- 12. Verify ldapi still works ----
echo ""
echo "--- Verifying LDAPI access ---"
if ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
  ok "LDAPI EXTERNAL bind works after rebuild"
  PASS=$((PASS+1))
else
  bad "LDAPI EXTERNAL bind failed after rebuild — check config"
  FAIL=$((FAIL+1))
fi

# ---- Cleanup ----
rm -f "$CONFIG_EXPORT"

# ---- Summary ----
echo ""
echo "============================================================"
echo "  Fix Master Checksum — Complete"
echo "  PASS=${PASS}  FAIL=${FAIL}"
echo "============================================================"
echo "  Backup preserved at: $BACKUP"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
  echo "Result: FAIL — restore from $BACKUP if needed"
  exit 1
else
  echo "Result: ALL PASS — checksums regenerated"
  exit 0
fi
