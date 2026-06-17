#!/usr/bin/env bash
# scripts/openldap-fix/fix-master.sh
# ====================================================================
# Validates and fixes Symas OpenLDAP master configuration.
# Covers: packages, service, accesslog (30GB + 360d purge), replicator
# limits, syncprov, indices, TLS, ACLs, hardening, backup.
#
# Idempotent — safe to run multiple times.
# ====================================================================
set -euo pipefail

# ── logging ──────────────────────────────────────────────────────────
log()   { echo "[INFO]  $*"; }
ok()    { echo "[ OK ]  $*"; }
warn()  { echo "[WARN]  $*"; }
bad()   { echo "[FAIL] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }
banner() { echo ""; echo "============================================================"; echo "  $*"; echo "============================================================"; }

PASS=0; FAIL=0; WARN=0; SKIP=0
TS=$(date +%Y%m%d-%H%M%S)
TIMESTAMP="${TIMESTAMP:-$TS}"
HOSTNAME="${HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
DRY_RUN="${DRY_RUN:-0}"

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

export PATH="/opt/symas/bin:/opt/symas/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
[[ -f /opt/symas/etc/openldap/sysmas_env.sh ]] && source /opt/symas/etc/openldap/sysmas_env.sh 2>/dev/null || true
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

# ── helpers ──────────────────────────────────────────────────────────
require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found — install symas-openldap packages first"; }

ldapi_search() { ldapsearch -o ldif-wrap=no -Y EXTERNAL -H ldapi:/// "$@" 2>/dev/null; }
ldapi_modify() { ldapmodify -Y EXTERNAL -H ldapi:/// "$@"; }
ldapi_add()    { ldapadd -Y EXTERNAL -H ldapi:/// "$@" 2>/dev/null; }

ssha_hash() {
  python3 -c "
import hashlib, base64, os
salt = os.urandom(8)
h = hashlib.sha1(b'${1}')
h.update(salt)
digest = base64.b64encode(h.digest() + salt).decode()
print('{SSHA}' + digest)
"
}

# ── configs (env-overridable) ───────────────────────────────────────
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_DN="cn=admin,${BASE_DN}"
ADMIN_PW="${ADMIN_PW:-TheN1le1}"
REPL_DN="cn=replicator,${BASE_DN}"
REPL_PW="${REPL_PW:-replpass}"
ACCESSLOG_GB="${ACCESSLOG_GB:-30}"
ACCESSLOG_BYTES=$(( ACCESSLOG_GB * 1073741824 ))
RETENTION_DAYS="${RETENTION_DAYS:-360}"
PURGE_AGE="${RETENTION_DAYS}+00:00 01:00:00"

find_service() {
  for svc in symas-openldap-servers slapd; do
    if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then echo "$svc"; return 0; fi
  done
  pgrep -x slapd >/dev/null 2>&1 && { echo "slapd"; return 0; }
  echo "symas-openldap-servers"
}

dry() { [[ "$DRY_RUN" -eq 1 ]] && { log "(dry-run) $*"; return 0; }; return 1; }

# ═══════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════

banner "OpenLDAP Master Fix — ${HOSTNAME} — ${TIMESTAMP}"

# ── 1: Package + binary check ───────────────────────────────────────
banner "Check 1: Symas OpenLDAP installation"
require_cmd ldapsearch
require_cmd ldapmodify
require_cmd slapcat
require_cmd slaptest

SLAPD_SVC=$(find_service)
log "Service: ${SLAPD_SVC}"

if systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1; then
  ok "Slapd is running"; PASS=$((PASS+1))
else
  bad "Slapd not running — start it first"; FAIL=$((FAIL+1)); exit 1
fi

# ── 2: cn=config access ─────────────────────────────────────────────
banner "Check 2: cn=config LDAPI access"
if ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
  ok "LDAPI EXTERNAL access works"; PASS=$((PASS+1))
else
  fatal "LDAPI access failed — cannot fix"
fi

# ── 3: Detect database DN ───────────────────────────────────────────
DB_DN=$(ldapi_search -b cn=config -LLL '(&(objectClass=olcMdbConfig)(olcSuffix=*))' dn | awk '/^dn: /{print $2; exit}')
[[ -n "${DB_DN:-}" ]] || fatal "Cannot find olcMdbConfig with suffix"
log "Main DB: ${DB_DN}"

# ── 4: Backup ────────────────────────────────────────────────────────
banner "Check 3: Backup cn=config"
SLAPD_D="/opt/symas/etc/openldap/slapd.d"
BACKUP="${SLAPD_D}.fix-${TIMESTAMP}"
if [[ -d "$SLAPD_D" ]]; then
  dry "Would backup to $BACKUP" || { cp -a "$SLAPD_D" "$BACKUP"; ok "Backed up to $BACKUP"; PASS=$((PASS+1)); }
else
  warn "No slapd.d dir — fresh install?"; WARN=$((WARN+1))
fi

# ── 5: Rebuild checksums ────────────────────────────────────────────
banner "Check 4: Rebuild cn=config checksums"
CONFIG_EXPORT="/tmp/cn-config-export-${TIMESTAMP}.ldif"
dry "Would rebuild checksums" || {
  slapcat -n 0 -l "$CONFIG_EXPORT" 2>/dev/null || warn "slapcat config export had warnings"
  ENTRIES=$(grep -c "^dn:" "$CONFIG_EXPORT" 2>/dev/null || echo "0")
  log "Exported ${ENTRIES} config entries"

  systemctl stop "$SLAPD_SVC"; sleep 2
  find "$SLAPD_D" -mindepth 1 -delete 2>/dev/null || true
  slapadd -n 0 -F "$SLAPD_D" -l "$CONFIG_EXPORT" 2>/dev/null || { warn "slapadd failed — restoring"; rm -rf "$SLAPD_D"; cp -a "$BACKUP" "$SLAPD_D"; }

  SLAPD_USER="symas-openldap"; id "$SLAPD_USER" >/dev/null 2>&1 || SLAPD_USER="ldap"
  id "$SLAPD_USER" >/dev/null 2>&1 || SLAPD_USER="root"
  chown -R "${SLAPD_USER}:${SLAPD_USER}" "$SLAPD_D" 2>/dev/null || true
  restorecon -Rv "$SLAPD_D" 2>/dev/null || true

  systemctl start "$SLAPD_SVC"; sleep 3
  if systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1; then
    ok "Checksums rebuilt — slapd active"; PASS=$((PASS+1))
  else
    bad "Slapd failed after checksum rebuild — restore from $BACKUP"; FAIL=$((FAIL+1))
    rm -rf "$SLAPD_D"; cp -a "$BACKUP" "$SLAPD_D"; systemctl start "$SLAPD_SVC"
  fi
  rm -f "$CONFIG_EXPORT"
}

# ── 6: Syncprov overlay ─────────────────────────────────────────────
banner "Check 5: Syncprov overlay"
HAS_SYNCPROV=$(ldapi_search -b cn=config -s sub "(olcOverlay=syncprov)" dn 2>/dev/null | grep -ci "^dn:" || true)
if [[ "$HAS_SYNCPROV" -gt 0 ]]; then
  ok "Syncprov overlay present"; PASS=$((PASS+1))
else
  dry "Would add syncprov" || {
    ldapi_modify -f <(cat <<LDIF
dn: olcOverlay=syncprov,${DB_DN}
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 100
LDIF
) && { ok "Syncprov overlay added"; PASS=$((PASS+1)); } || { bad "Syncprov add failed"; FAIL=$((FAIL+1)); }
  }
fi

# ── 7: entryUUID/entryCSN indices ───────────────────────────────────
banner "Check 6: Syncrepl indices"
INDICES=$(ldapi_search -b "$DB_DN" -s base -LLL olcDbIndex 2>/dev/null || true)
MISSING=""
echo "$INDICES" | grep -q "entryUUID" || MISSING="$MISSING entryUUID"
echo "$INDICES" | grep -q "entryCSN"  || MISSING="$MISSING entryCSN"
if [[ -z "$MISSING" ]]; then
  ok "entryUUID + entryCSN indices present"; PASS=$((PASS+1))
else
  log "Adding missing:$MISSING"
  dry "Would add indices" || {
    ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
add: olcDbIndex
olcDbIndex: entryUUID eq
-
add: olcDbIndex
olcDbIndex: entryCSN eq
LDIF
) && { ok "Indices added"; PASS=$((PASS+1)); } || { bad "Index add failed"; FAIL=$((FAIL+1)); }
  }
fi

# ── 8: accesslog DB size + purge ────────────────────────────────────
banner "Check 7: Accesslog sizing (${ACCESSLOG_GB}GB / ${RETENTION_DAYS}d purge)"
ACCESSLOG_DN=$(ldapi_search -b cn=config -s sub "(olcSuffix=cn=accesslog)" dn 2>/dev/null | awk '/^dn: /{print $2; exit}')
ACL_OVERLAY_DN=$(ldapi_search -b cn=config -s sub "(olcAccessLogDB=cn=accesslog)" dn 2>/dev/null | awk '/^dn: /{print $2; exit}')

if [[ -n "${ACCESSLOG_DN:-}" ]]; then
  CURRENT_SIZE=$(ldapi_search -b "$ACCESSLOG_DN" -s base -LLL olcDbMaxSize 2>/dev/null | awk '/^olcDbMaxSize:/{print $2; exit}')
  CURRENT_SIZE="${CURRENT_SIZE:-unknown}"
  if [[ "${CURRENT_SIZE:-0}" -ge "$ACCESSLOG_BYTES" ]]; then
    ok "Accesslog maxsize OK ($(($CURRENT_SIZE/1073741824))GB >= ${ACCESSLOG_GB}GB)"; PASS=$((PASS+1))
  else
    dry "Would resize accesslog to ${ACCESSLOG_GB}GB" || {
      ldapi_modify -f <(cat <<LDIF
dn: ${ACCESSLOG_DN}
changetype: modify
replace: olcDbMaxSize
olcDbMaxSize: ${ACCESSLOG_BYTES}
LDIF
) && { ok "Accesslog maxsize → ${ACCESSLOG_GB}GB (was: ${CURRENT_SIZE})"; PASS=$((PASS+1)); } || { bad "Resize failed"; FAIL=$((FAIL+1)); }
    }
  fi

  if [[ -n "${ACL_OVERLAY_DN:-}" ]]; then
    CURRENT_PURGE=$(ldapi_search -b "$ACL_OVERLAY_DN" -s base -LLL olcAccessLogPurge 2>/dev/null | awk '/^olcAccessLogPurge:/{print $2" "$3; exit}')
    if [[ "${CURRENT_PURGE:-}" == "${PURGE_AGE}" ]]; then
      ok "Accesslog purge OK (${RETENTION_DAYS}d)"; PASS=$((PASS+1))
    else
      dry "Would set purge to ${RETENTION_DAYS} days" || {
        ldapi_modify -f <(cat <<LDIF
dn: ${ACL_OVERLAY_DN}
changetype: modify
replace: olcAccessLogPurge
olcAccessLogPurge: ${PURGE_AGE}
LDIF
) && { ok "Accesslog purge → ${RETENTION_DAYS}d (was: ${CURRENT_PURGE:-none})"; PASS=$((PASS+1)); } || { bad "Purge update failed"; FAIL=$((FAIL+1)); }
      }
    fi
  fi
else
  warn "No accesslog DB found — skipping sizing"; WARN=$((WARN+1))
fi

# ── 9: replicator unlimited limits ───────────────────────────────────
banner "Check 8: Replicator olcLimits"
HAS_LIMITS=$(ldapi_search -b "$DB_DN" -s base -LLL olcLimits 2>/dev/null | grep -c "replicator" || true)
if [[ "$HAS_LIMITS" -gt 0 ]]; then
  ok "Replicator limits present"; PASS=$((PASS+1))
else
  dry "Would add unlimited limits" || {
    ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
add: olcLimits
olcLimits: dn.exact="${REPL_DN}" time.soft=unlimited time.hard=unlimited size.soft=unlimited size.hard=unlimited
LDIF
) && { ok "Replicator unlimited limits set"; PASS=$((PASS+1)); } || { bad "Limits update failed"; FAIL=$((FAIL+1)); }
  }
fi

# ── 10: ACL for replicator + mw ─────────────────────────────────────
banner "Check 9: Data ACLs"
ACL_OK=$(ldapi_search -b "$DB_DN" -s base -LLL olcAccess 2>/dev/null | grep -c "replicator" || true)
if [[ "$ACL_OK" -gt 0 ]]; then
  ok "Replicator ACL present"; PASS=$((PASS+1))
else
  dry "Would add ACLs" || {
    ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword by self write by anonymous auth by * none
olcAccess: {1}to * by dn.exact="${REPL_DN}" read by * read
LDIF
) && { ok "ACLs configured"; PASS=$((PASS+1)); } || { bad "ACL failed"; FAIL=$((FAIL+1)); }
  }
fi

# ── 11: Admin password ──────────────────────────────────────────────
banner "Check 10: Admin password"
dry "Would reset admin password" || {
  NEW_HASH=$(ssha_hash "$ADMIN_PW")
  ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
replace: olcRootPW
olcRootPW: ${NEW_HASH}
LDIF
) && { ok "Admin password set (SSHA)"; PASS=$((PASS+1)); } || { bad "Password set failed"; FAIL=$((FAIL+1)); }
}

# ── 12: Hardening ───────────────────────────────────────────────────
banner "Check 11: Hardening (olcSecurity)"
CURRENT_SEC=$(ldapi_search -b cn=config -s base -LLL olcSecurity 2>/dev/null | grep "^olcSecurity:" || true)
if echo "$CURRENT_SEC" | grep -q "simple_bind=128"; then
  ok "Hardening active — plaintext binds blocked"; PASS=$((PASS+1))
else
  dry "Would apply hardening" || {
    ldapi_modify -f <(cat <<'LDIF'
dn: cn=config
changetype: modify
replace: olcSecurity
olcSecurity: simple_bind=128
LDIF
) && { ok "Hardening applied (simple_bind=128)"; PASS=$((PASS+1)); } || { bad "Hardening failed"; FAIL=$((FAIL+1)); }
  }
fi

# ── 13: TLS cert validation ─────────────────────────────────────────
banner "Check 12: TLS certificates"
TLS_DIR="/opt/symas/etc/openldap/tls"
if [[ -f "${TLS_DIR}/ldap.crt" && -f "${TLS_DIR}/ldap.key" ]]; then
  CRT_EXPIRY=$(openssl x509 -in "${TLS_DIR}/ldap.crt" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
  CRT_SUBJECT=$(openssl x509 -in "${TLS_DIR}/ldap.crt" -noout -subject 2>/dev/null | sed 's/^subject=//' || echo "unknown")
  ok "TLS cert: ${CRT_SUBJECT}  expiry: ${CRT_EXPIRY}"; PASS=$((PASS+1))
else
  warn "TLS cert/key missing — generate with r5-configure-replica-tls.sh or equivalent"; WARN=$((WARN+1))
fi

# ── 14: Restart ─────────────────────────────────────────────────────
banner "Restarting slapd"
dry "Would restart ${SLAPD_SVC}" || {
  systemctl restart "$SLAPD_SVC"; sleep 3
  if systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1; then
    ok "Slapd running after fixes"; PASS=$((PASS+1))
  else
    bad "Slapd failed — restore from $BACKUP"; FAIL=$((FAIL+1)); exit 1
  fi
}

# ── 15: Verify no MDB_MAP_FULL in recent logs ────────────────────────
banner "Check 13: Recent log sanity"
RECENT=$(journalctl -u "$SLAPD_SVC" --no-pager --since "3 minutes ago" 2>/dev/null || true)
MAP_FULL=$(echo "$RECENT" | grep -ci "MDB_MAP_FULL" || true)
if [[ "$MAP_FULL" -eq 0 ]]; then
  ok "No MDB_MAP_FULL in recent logs"; PASS=$((PASS+1))
else
  warn "${MAP_FULL} MDB_MAP_FULL found — monitor accesslog usage"; WARN=$((WARN+1))
fi

# ═══════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "============================================================"
echo "  MASTER FIX — Complete"
echo "  Host:     ${HOSTNAME}"
echo "  Service:  ${SLAPD_SVC}"
echo "  Accesslog: ${ACCESSLOG_GB}GB / ${RETENTION_DAYS}d purge"
echo "  PASS=${PASS}  FAIL=${FAIL}  WARN=${WARN}  SKIP=${SKIP}"
echo "  Backup:   ${BACKUP}"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
  echo "Result: FAIL — ${FAIL} check(s) failed"
  echo "Rollback: cp -a ${BACKUP} ${SLAPD_D} && systemctl restart ${SLAPD_SVC}"
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo "Result: PASS with ${WARN} warning(s)"
  exit 0
else
  echo "Result: ALL PASS"
  exit 0
fi
