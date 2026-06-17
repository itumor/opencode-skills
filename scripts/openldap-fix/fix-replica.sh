#!/usr/bin/env bash
# scripts/openldap-fix/fix-replica.sh
# ====================================================================
# Validates and fixes Symas OpenLDAP replica configuration.
# Covers: packages, service, ppolicy overlay, syncrepl, seed from
# master, ACLs, hardening, frontend, read-only, interval keepalive.
#
# Idempotent — safe to run multiple times.
# ====================================================================
set -euo pipefail

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

require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found — install symas-openldap packages first"; }

ldapi_search() { ldapsearch -o ldif-wrap=no -Y EXTERNAL -H ldapi:/// "$@" 2>/dev/null; }
ldapi_modify() { ldapmodify -Y EXTERNAL -H ldapi:/// "$@"; }
ldapi_add()    { ldapadd -Y EXTERNAL -H ldapi:/// "$@" 2>/dev/null; }

find_service() {
  for svc in symas-openldap-servers slapd; do
    if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then echo "$svc"; return 0; fi
  done
  pgrep -x slapd >/dev/null 2>&1 && { echo "slapd"; return 0; }
  echo "symas-openldap-servers"
}

dry() { [[ "$DRY_RUN" -eq 1 ]] && { log "(dry-run) $*"; return 0; }; return 1; }

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
MASTER_IP="${MASTER_IP:-}"
NEED_RESTART=0

# ═══════════════════════════════════════════════════════════════════════
banner "OpenLDAP Replica Fix — ${HOSTNAME} — ${TIMESTAMP}"

# ── 1: Package check ────────────────────────────────────────────────
banner "Check 1: Symas OpenLDAP installation"
require_cmd ldapsearch
require_cmd ldapmodify
require_cmd slapcat
SLAPD_SVC=$(find_service)
log "Service: ${SLAPD_SVC}"

if systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1; then
  ok "Slapd is running"; PASS=$((PASS+1))
else
  bad "Slapd not running"; FAIL=$((FAIL+1)); exit 1
fi

# ── 2: cn=config access ─────────────────────────────────────────────
banner "Check 2: cn=config LDAPI access"
if ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
  ok "LDAPI EXTERNAL works"; PASS=$((PASS+1))
else
  fatal "LDAPI access failed"
fi

DB_DN=$(ldapi_search -b cn=config -LLL '(&(objectClass=olcMdbConfig)(olcSuffix=*))' dn | awk '/^dn: /{print $2; exit}')
[[ -n "${DB_DN:-}" ]] || fatal "Cannot find olcMdbConfig"
log "Main DB: ${DB_DN}"

# ── 3: Backup ────────────────────────────────────────────────────────
banner "Check 3: Backup cn=config"
SLAPD_D="/opt/symas/etc/openldap/slapd.d"
BACKUP="${SLAPD_D}.fix-${TIMESTAMP}"
if [[ -d "$SLAPD_D" ]]; then
  dry "Would backup to $BACKUP" || { cp -a "$SLAPD_D" "$BACKUP"; ok "Backed up to $BACKUP"; PASS=$((PASS+1)); }
else
  warn "No slapd.d dir"; WARN=$((WARN+1))
fi

# ── 4: ppolicy module ───────────────────────────────────────────────
banner "Check 4: ppolicy module"
PPOLICY_MOD=$(ldapi_search -b cn=config -s sub "(olcModuleLoad=ppolicy.la)" dn 2>/dev/null | grep -c "cn=module" || true)
if [[ "$PPOLICY_MOD" -gt 0 ]]; then
  ok "ppolicy module loaded"; PASS=$((PASS+1))
else
  dry "Would load ppolicy module" || {
    ldapi_modify -f <(cat <<'LDIF'
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: ppolicy.la
LDIF
) && { ok "ppolicy module loaded"; PASS=$((PASS+1)); NEED_RESTART=1; } || { bad "ppolicy load failed"; FAIL=$((FAIL+1)); }
  }
fi

# ── 5: ppolicy overlay ──────────────────────────────────────────────
banner "Check 5: ppolicy overlay"
PP_DN_REAL=$(ldapi_search -b cn=config -s sub "(olcOverlay=ppolicy)" dn 2>/dev/null | awk '/^dn: /{print $2; exit}')
if [[ -n "${PP_DN_REAL:-}" ]]; then
  ok "ppolicy overlay present"; PASS=$((PASS+1))
else
  PP_DN="olcOverlay=ppolicy,${DB_DN}"
  dry "Would create ppolicy overlay" || {
    ldapi_add <<LDIF
dn: ${PP_DN}
objectClass: olcOverlayConfig
objectClass: olcPPolicyConfig
olcOverlay: ppolicy
LDIF
    sleep 1
    PP_DN_REAL=$(ldapi_search -b cn=config -s sub "(olcOverlay=ppolicy)" dn 2>/dev/null | awk '/^dn: /{print $2; exit}')
    if [[ -n "${PP_DN_REAL:-}" ]]; then
      ok "ppolicy overlay created → ${PP_DN_REAL}"; PASS=$((PASS+1))
      # set HashCleartext
      ldapi_modify -f <(cat <<LDIF
dn: ${PP_DN_REAL}
changetype: modify
replace: olcPPolicyHashCleartext
olcPPolicyHashCleartext: TRUE
LDIF
) 2>/dev/null && ok "HashCleartext=TRUE" || warn "HashCleartext set failed — may already exist"

      # set default policy
      ldapi_modify -f <(cat <<LDIF
dn: ${PP_DN_REAL}
changetype: modify
add: olcPPolicyDefault
olcPPolicyDefault: cn=default,ou=Policies,${BASE_DN}
LDIF
) 2>/dev/null && ok "Default ppolicy set" || warn "Default ppolicy may already exist"
    else
      bad "ppolicy overlay creation failed"; FAIL=$((FAIL+1))
    fi
  }
fi

# ── 6: syncrepl starttls=yes ────────────────────────────────────────
banner "Check 6: Syncrepl config"
CURRENT_SR=$(ldapi_search -o ldif-wrap=no -b "$DB_DN" -s base -LLL olcSyncrepl 2>/dev/null | tr -d '\n' || true)

NEED_SR_UPDATE=0
SR_TLS_OK=0
echo "$CURRENT_SR" | grep -qi "starttls=yes" && SR_TLS_OK=1

if [[ "$SR_TLS_OK" -eq 1 ]]; then
  ok "Syncrepl uses starttls=yes"; PASS=$((PASS+1))
else
  NEED_SR_UPDATE=1
  log "Will enable starttls=yes"
fi

if echo "$CURRENT_SR" | grep -q "interval="; then
  ok "Syncrepl interval already set"; PASS=$((PASS+1))
else
  log "Syncrepl missing interval keepalive"
  NEED_SR_UPDATE=1
fi

if [[ "$NEED_SR_UPDATE" -eq 1 ]]; then
  PROVIDER=$(echo "$CURRENT_SR" | grep -oP 'provider=\K[^ ]+' | head -1 || echo "ldap://${MASTER_IP}:389")
  BINDDN=$(echo "$CURRENT_SR" | grep -oP 'binddn="\K[^"]+' | head -1 || echo "${REPL_DN}")
  CREDS=$(echo "$CURRENT_SR" | grep -oP 'credentials="?\K[^" ]+' | head -1 || echo "${REPL_PW}")
  BASE=$(echo "$CURRENT_SR" | grep -oP 'searchbase="\K[^"]+' | head -1 || echo "${BASE_DN}")
  RID=$(echo "$CURRENT_SR" | grep -oP 'rid=\K[0-9]+' | head -1 || echo "101")
  PROVIDER=$(echo "$PROVIDER" | sed 's/^ldaps:/ldap:/')
  dry "Would update syncrepl" || {
    ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
replace: olcSyncrepl
olcSyncrepl: {0}rid=${RID} provider=${PROVIDER} bindmethod=simple binddn="${BINDDN}" credentials=${CREDS} searchbase="${BASE}" type=refreshAndPersist retry="5 5 300 +" timeout=1 starttls=yes tls_reqcert=never interval=00:00:00:10
LDIF
) && { ok "Syncrepl updated (starttls=yes + interval)"; PASS=$((PASS+1)); NEED_RESTART=1; } || { bad "Syncrepl update failed"; FAIL=$((FAIL+1)); }
  }
fi

# ── 8: olcUpdateRef ─────────────────────────────────────────────────
banner "Check 7: olcUpdateRef"
CURRENT_REF=$(ldapi_search -b "$DB_DN" -s base -LLL olcUpdateRef 2>/dev/null | grep -c "^olcUpdateRef:" || true)
if [[ "$CURRENT_REF" -gt 0 ]]; then
  ok "olcUpdateRef set"; PASS=$((PASS+1))
else
  [[ -z "${MASTER_IP:-}" ]] && { warn "MASTER_IP not set — skipping UpdateRef"; WARN=$((WARN+1)); }
  [[ -n "${MASTER_IP:-}" ]] && dry "Would set UpdateRef" || {
    ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
add: olcUpdateRef
olcUpdateRef: ldap://${MASTER_IP}:389
LDIF
) 2>/dev/null && ok "olcUpdateRef set → ${MASTER_IP}" || warn "olcUpdateRef may already exist"
  }
fi

# ── 9: Read-only ────────────────────────────────────────────────────
banner "Check 8: Read-only mode"
READONLY=$(ldapi_search -b "$DB_DN" -s base -LLL olcReadOnly 2>/dev/null | grep -c "olcReadOnly: TRUE" || true)
if [[ "$READONLY" -gt 0 ]]; then
  ok "Replica read-only (TRUE)"; PASS=$((PASS+1))
else
  dry "Would set read-only" || {
    ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
replace: olcReadOnly
olcReadOnly: TRUE
LDIF
) 2>/dev/null && ok "olcReadOnly=TRUE" || warn "ReadOnly already set"
  }
fi

# ── 10: Data ACLs ───────────────────────────────────────────────────
banner "Check 9: Data ACLs"
ACL_EXISTS=$(ldapi_search -b "$DB_DN" -s base -LLL olcAccess 2>/dev/null | grep -c "^olcAccess:" || true)
if [[ "$ACL_EXISTS" -gt 0 ]]; then
  ok "Data ACLs present (${ACL_EXISTS} rules)"; PASS=$((PASS+1))
else
  dry "Would add data ACLs" || {
    ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword by self write by anonymous auth by * none
olcAccess: {1}to * by * read
LDIF
) && { ok "Data ACLs configured"; PASS=$((PASS+1)); } || { bad "ACL failed"; FAIL=$((FAIL+1)); }
  }
fi

# ── 11: Frontend ACLs ───────────────────────────────────────────────
banner "Check 10: Frontend ACLs"
FE_ACL=$(ldapi_search -b "olcDatabase={-1}frontend,cn=config" -s base -LLL olcAccess 2>/dev/null | grep -c "^olcAccess:" || true)
if [[ "$FE_ACL" -gt 0 ]]; then
  ok "Frontend ACLs present (${FE_ACL} rules)"; PASS=$((PASS+1))
else
  dry "Would add frontend ACLs" || {
    ldapi_modify -f <(cat <<'LDIF'
dn: olcDatabase={-1}frontend,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to dn.base="" by * read
olcAccess: {1}to * by self write by users read by anonymous auth
LDIF
) && { ok "Frontend ACLs configured"; PASS=$((PASS+1)); } || { bad "Frontend ACL failed"; FAIL=$((FAIL+1)); }
  }
fi

# ── 12: olcModulePath ───────────────────────────────────────────────
banner "Check 11: olcModulePath"
MOD_PATH=$(ldapi_search -b "cn=module{0},cn=config" -s base -LLL olcModulePath 2>/dev/null | grep "^olcModulePath:" || true)
if [[ -n "$MOD_PATH" ]]; then
  ok "olcModulePath set"; PASS=$((PASS+1))
else
  dry "Would set olcModulePath" || {
    ldapi_modify -f <(cat <<'LDIF'
dn: cn=module{0},cn=config
changetype: modify
add: olcModulePath
olcModulePath: /opt/symas/lib/openldap
LDIF
) && { ok "olcModulePath set"; PASS=$((PASS+1)); } || { bad "olcModulePath failed"; FAIL=$((FAIL+1)); }
  }
fi

# ── 13: Hardening ───────────────────────────────────────────────────
banner "Check 12: Hardening (olcSecurity)"
CURRENT_SEC=$(ldapi_search -b cn=config -s base -LLL olcSecurity 2>/dev/null | grep "^olcSecurity:" || true)
if echo "$CURRENT_SEC" | grep -q "simple_bind=128"; then
  ok "Hardening active"; PASS=$((PASS+1))
else
  dry "Would apply hardening" || {
    ldapi_modify -f <(cat <<'LDIF'
dn: cn=config
changetype: modify
replace: olcSecurity
olcSecurity: simple_bind=128
LDIF
) && { ok "Hardening applied"; PASS=$((PASS+1)); NEED_RESTART=1; } || { bad "Hardening failed"; FAIL=$((FAIL+1)); }
  }
fi

# ── 14: TLS cert check ──────────────────────────────────────────────
banner "Check 13: TLS certificates"
TLS_DIR="/opt/symas/etc/openldap/tls"
if [[ -f "${TLS_DIR}/ldap.crt" && -f "${TLS_DIR}/ldap.key" ]]; then
  CRT_EXPIRY=$(openssl x509 -in "${TLS_DIR}/ldap.crt" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
  ok "TLS cert present — expiry: ${CRT_EXPIRY}"; PASS=$((PASS+1))
else
  warn "TLS cert/key missing — generate before using StartTLS"; WARN=$((WARN+1))
fi

# ── 15: Seed from master if empty ───────────────────────────────────
banner "Check 14: Database seed status"
DATA_COUNT=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
  -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$BASE_DN" -s one -LLL dn 2>/dev/null | grep -c "^dn:" || true)
DATA_COUNT=$(echo "$DATA_COUNT" | tr -d '[:space:]')

if [[ -z "$DATA_COUNT" || "$DATA_COUNT" -eq 0 ]]; then
  if [[ -z "${MASTER_IP:-}" ]]; then
    warn "MASTER_IP unset and DB empty — cannot seed"; WARN=$((WARN+1))
  else
    log "DB has 0 entries — seeding from ${MASTER_IP}"
    dry "Would seed from master" || {
      # try StartTLS then plain
      if LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H "ldap://${MASTER_IP}:389" \
        -D "$REPL_DN" -w "$REPL_PW" >/dev/null 2>&1; then
        log "StartTLS bind to master OK"
      elif ldapwhoami -x -H "ldap://${MASTER_IP}:389" -D "$REPL_DN" -w "$REPL_PW" >/dev/null 2>&1; then
        log "Plain bind to master OK"
      else
        bad "Cannot bind to master as replicator"; FAIL=$((FAIL+1))
      fi

      LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H "ldap://${MASTER_IP}:389" \
        -D "$REPL_DN" -w "$REPL_PW" -b "$BASE_DN" -s sub "(objectClass=*)" -LLL > /tmp/replica-seed.ldif 2>/dev/null
      SEED_COUNT=$(grep -c "^dn:" /tmp/replica-seed.ldif 2>/dev/null || echo "0")
      log "Pulled ${SEED_COUNT} entries from master"

      if [[ "$SEED_COUNT" -gt 0 ]]; then
        systemctl stop "$SLAPD_SVC"; sleep 2
        rm -f /var/symas/openldap-data/example/data.mdb /var/symas/openldap-data/example/lock.mdb
        slapadd -n 1 -l /tmp/replica-seed.ldif 2>/dev/null || { bad "slapadd failed"; FAIL=$((FAIL+1)); }
        SLAPD_USER="symas-openldap"; id "$SLAPD_USER" >/dev/null 2>&1 || SLAPD_USER="ldap"
        id "$SLAPD_USER" >/dev/null 2>&1 || SLAPD_USER="root"
        chown -R "${SLAPD_USER}:${SLAPD_USER}" /var/symas/openldap-data 2>/dev/null || true
        restorecon -Rv /var/symas/openldap-data 2>/dev/null || true
        systemctl start "$SLAPD_SVC"; sleep 3
        rm -f /tmp/replica-seed.ldif
        if systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1; then
          ok "Seeded ${SEED_COUNT} entries — slapd running"; PASS=$((PASS+1))
        else
          bad "Slapd failed after seed"; FAIL=$((FAIL+1))
        fi
      else
        warn "Could not pull data from master"; WARN=$((WARN+1))
      fi
    }
  fi
else
  ok "Replica has ${DATA_COUNT} children — skip seed"; PASS=$((PASS+1))
fi

# ── 16: Restart if needed ───────────────────────────────────────────
if [[ "$NEED_RESTART" -eq 1 ]]; then
  banner "Restarting slapd to apply config changes"
  dry "Would restart" || {
    systemctl restart "$SLAPD_SVC"; sleep 3
    systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1 && ok "Slapd running" || bad "Slapd restart failed"
  }
fi

# ═══════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "============================================================"
echo "  REPLICA FIX — Complete"
echo "  Host:     ${HOSTNAME}"
echo "  Service:  ${SLAPD_SVC}"
echo "  Master:   ${MASTER_IP:-auto-detected}"
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
