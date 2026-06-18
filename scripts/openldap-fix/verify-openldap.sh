#!/usr/bin/env bash
# scripts/openldap-fix/verify-openldap.sh
# Health verification for Symas OpenLDAP. Auto-detects master/replica role.
# Returns non-zero if any critical check fails.
set -euo pipefail

log()   { echo "[INFO]  $*"; }
ok()    { echo "[ OK ]  $*"; }
warn()  { echo "[WARN]  $*"; }
bad()   { echo "[FAIL] $*" >&2; }
banner() { echo ""; echo "=== $* ==="; }

PASS=0; FAIL=0; WARN=0
TS=$(date +%Y%m%d-%H%M%S)
HOSTNAME="${HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "[FATAL] Run as root" >&2; exit 1; }

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

detect_service() {
  for s in symas-openldap-servers slapd; do
    systemctl list-units --type=service 2>/dev/null | grep -qF "$s" && { echo "$s"; return; }
  done
  pgrep -x slapd >/dev/null 2>&1 && echo "slapd" || echo "symas-openldap-servers"
}

BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_DN="cn=admin,${BASE_DN}"
ADMIN_PW="${ADMIN_PW:-TheN1le1}"
SLAPD_SVC=$(detect_service)

ldapi_search() { ldapsearch -o ldif-wrap=no -Y EXTERNAL -H ldapi:/// "$@" 2>/dev/null; }

banner "OpenLDAP Verification — ${HOSTNAME}"

# ── Service ──
banner "1. Service status"
if systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1; then
  ok "Slapd running"; PASS=$((PASS+1))
else
  bad "Slapd not running"; FAIL=$((FAIL+1))
fi

# ── Ports ──
banner "2. LDAP ports"
for port in 389 636; do
  if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    ok "Port ${port} listening"; PASS=$((PASS+1))
  else
    warn "Port ${port} not listening"; WARN=$((WARN+1))
  fi
done

# ── LDAPI ──
banner "3. LDAPI access"
if ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
  ok "LDAPI works"; PASS=$((PASS+1))
else
  bad "LDAPI failed"; FAIL=$((FAIL+1)); exit 1
fi

DB_DN=$(ldapi_search -b cn=config -LLL '(&(objectClass=olcMdbConfig)(olcSuffix=*))' dn | awk '/^dn: /{print $2; exit}')
[[ -z "${DB_DN:-}" ]] && { bad "No MDB config found"; FAIL=$((FAIL+1)); exit 1; }

# ── Config readable ──
banner "4. Config readable"
if ldapi_search -b cn=config -s base dn 2>/dev/null | grep -q "^dn:"; then
  ok "cn=config readable"; PASS=$((PASS+1))
else
  bad "cn=config not readable"; FAIL=$((FAIL+1))
fi

# ── Data readable ──
banner "5. Data readable"
ENTRIES=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
  -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$BASE_DN" -s one -LLL dn 2>/dev/null | grep -c "^dn:" || true)
ENTRIES=$(echo "$ENTRIES" | tr -d '[:space:]')
if [[ -n "$ENTRIES" && "$ENTRIES" -gt 0 ]]; then
  ok "Base DN readable — ${ENTRIES} children"; PASS=$((PASS+1))
else
  warn "Base DN has 0 children — DB may be empty"; WARN=$((WARN+1))
fi

# ── TLS ──
banner "6. TLS connection"
if LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1; then
  ok "StartTLS bind works"; PASS=$((PASS+1))
elif ldapwhoami -x -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1; then
  warn "Plain bind works (StartTLS not available — hardening may need review)"; WARN=$((WARN+1))
else
  bad "Admin bind failed entirely"; FAIL=$((FAIL+1))
fi

# ── Cert expiry ──
banner "7. Certificate validity"
if [[ -f /opt/symas/etc/openldap/tls/ldap.crt ]]; then
  EXPIRY=$(openssl x509 -in /opt/symas/etc/openldap/tls/ldap.crt -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
  EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [[ "$EXPIRY_EPOCH" -gt "$NOW" ]]; then
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW) / 86400 ))
    ok "Cert valid for ${DAYS_LEFT} days (expires: ${EXPIRY})"; PASS=$((PASS+1))
  else
    bad "Cert expired: ${EXPIRY}"; FAIL=$((FAIL+1))
  fi
else
  warn "No ldap.crt found"; WARN=$((WARN+1))
fi

# ── slaptest ──
banner "8. Config validation (slaptest -u)"
if slaptest -F /opt/symas/etc/openldap/slapd.d -u 2>&1 | grep -q "config file testing succeeded"; then
  ok "Config valid"; PASS=$((PASS+1))
else
  bad "Config validation failed"; FAIL=$((FAIL+1))
fi

# ── Role detection ──
HAS_SYNCREPL=$(ldapi_search -b "$DB_DN" -s base -LLL olcSyncrepl 2>/dev/null | grep -ci olcSyncrepl || true)
HAS_SYNCPROV=$(ldapi_search -b cn=config -s sub "(olcOverlay=syncprov)" dn 2>/dev/null | grep -ci "^dn:" || true)

if [[ "$HAS_SYNCREPL" -gt 0 ]]; then
  ROLE="replica"
else
  ROLE="master"
fi
log "Detected role: ${ROLE}"

# ── MASTER CHECKS ──
if [[ "$ROLE" == "master" ]]; then
  banner "Master-specific checks"

  if [[ "$HAS_SYNCPROV" -gt 0 ]]; then ok "Syncprov overlay present"; PASS=$((PASS+1)); else bad "Syncprov missing"; FAIL=$((FAIL+1)); fi

  IND=$(ldapi_search -b "$DB_DN" -s base -LLL olcDbIndex 2>/dev/null || true)
  echo "$IND" | grep -q "entryUUID" && ok "entryUUID index present" || bad "entryUUID index missing"
  echo "$IND" | grep -q "entryCSN"  && ok "entryCSN index present"  || bad "entryCSN index missing"
  if echo "$IND" | grep -q "entryUUID" && echo "$IND" | grep -q "entryCSN"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

  SERVID=$(ldapi_search -b cn=config -s base -LLL olcServerID 2>/dev/null | grep -c "olcServerID" || true)
  if [[ "$SERVID" -gt 0 ]]; then ok "ServerID set"; PASS=$((PASS+1)); else warn "ServerID not set"; WARN=$((WARN+1)); fi

  if ldapi_search -b "$DB_DN" -s base -LLL olcAccess 2>/dev/null | grep -q "replicator"; then ok "Replicator ACL present"; PASS=$((PASS+1)); else bad "Replicator ACL missing"; FAIL=$((FAIL+1)); fi

  # Accesslog check
  if ldapi_search -b cn=config -s sub "(olcOverlay=accesslog)" dn 2>/dev/null | grep -q "^dn:"; then
    ok "Accesslog overlay present"; PASS=$((PASS+1))
  else
    warn "Accesslog overlay not present"; WARN=$((WARN+1))
  fi
fi

# ── REPLICA CHECKS ──
if [[ "$ROLE" == "replica" ]]; then
  banner "Replica-specific checks"

  SR=$(ldapi_search -o ldif-wrap=no -b "$DB_DN" -s base -LLL olcSyncrepl 2>/dev/null | tr -d '\n' || true)
  if echo "$SR" | grep -qi "starttls=yes"; then ok "Syncrepl starttls=yes"; PASS=$((PASS+1)); else bad "Syncrepl starttls missing"; FAIL=$((FAIL+1)); fi
  if echo "$SR" | grep -q "interval="; then ok "Syncrepl interval set"; PASS=$((PASS+1)); else warn "No interval keepalive"; WARN=$((WARN+1)); fi

  if ldapi_search -b "$DB_DN" -s base -LLL olcUpdateRef 2>/dev/null | grep -q "ldap://"; then ok "olcUpdateRef set"; PASS=$((PASS+1)); else warn "olcUpdateRef missing"; WARN=$((WARN+1)); fi

  if ldapi_search -b "$DB_DN" -s base -LLL olcReadOnly 2>/dev/null | grep -q "olcReadOnly: TRUE"; then ok "Read-only enforced"; PASS=$((PASS+1)); else warn "Read-only not set"; WARN=$((WARN+1)); fi

  if ldapi_search -b cn=config -s sub "(olcOverlay=ppolicy)" dn 2>/dev/null | grep -q "^dn:"; then ok "ppolicy overlay present"; PASS=$((PASS+1)); else bad "ppolicy overlay missing"; FAIL=$((FAIL+1)); fi

  if ldapi_search -b "olcDatabase={-1}frontend,cn=config" -s base -LLL olcAccess 2>/dev/null | grep -q "^olcAccess:"; then
    ok "Frontend ACLs present"; PASS=$((PASS+1))
  else
    warn "Frontend ACLs missing"; WARN=$((WARN+1))
  fi
fi

# ── Log sanity ──
banner "9. Recent log errors"
JOURNAL=$(journalctl -u "$SLAPD_SVC" --no-pager --since "5 minutes ago" 2>/dev/null || true)
for e in "MDB_MAP_FULL" "TLS negotiation failure" "err=13" "err=49"; do
  C=$(echo "$JOURNAL" | grep -ci "$e" || true)
  if [[ "$C" -eq 0 ]]; then
    ok "No '${e}' in recent logs"; PASS=$((PASS+1))
  else
    warn "${C}x '${e}' found"; WARN=$((WARN+1))
  fi
done

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "============================================================"
echo "  VERIFICATION — ${ROLE^^}"
echo "  Host:  ${HOSTNAME}"
echo "  PASS=${PASS}  FAIL=${FAIL}  WARN=${WARN}"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
  echo "Result: FAIL — ${FAIL} checks failed"; exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo "Result: PASS with ${WARN} warning(s)"; exit 0
else
  echo "Result: ALL PASS"; exit 0
fi
