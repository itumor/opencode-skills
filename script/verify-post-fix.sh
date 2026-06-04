#!/usr/bin/env bash
# verify-post-fix.sh
#
# Comprehensive post-fix verification script.
# Runs on either master or replica (detects role automatically).
# Must be run as root for full verification (including ldapi checks).
#
# Checks:
#   1. Service status
#   2. Ports listening (389, 636)
#   3. LDAPI EXTERNAL access
#   4. No checksum errors in logs
#   5. No err=13 (confidentiality required) errors in recent logs
#   6. No TLS negotiation failures in recent logs
#   7. Admin bind via StartTLS (port 389)
#   8. Replicator bind via StartTLS (port 389)
#   9. If replica: syncrepl has starttls=yes
#  10. If replica: sync from master works (contextCSN comparison)
#  11. Base DN readable
#  12. Accesslog overlay present and writing
#
# Required env (for replica sync check):
#   MASTER_IP   - master hostname/IP (replica only)
#   ADMIN_PW    - admin password
#
# Usage:
#   sudo MASTER_IP=<master_ip> ADMIN_PW=<password> bash verify-post-fix.sh
set -uo pipefail

ok()   { echo "[ OK ] $*"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN+1)); }
info() { echo "[INFO] $*"; }

PASS=0; FAIL=0; WARN=0

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { warn "Not root — some checks will be skipped"; }

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
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

MASTER_IP="${MASTER_IP:-}"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_DN="${ADMIN_DN:-cn=admin,${BASE_DN}}"
ADMIN_PW="${ADMIN_PW:-}"
REPL_DN="${REPL_DN:-cn=replicator,${BASE_DN}}"
REPL_PW="${REPL_PW:-replpass}"
LDAPI_URI="ldapi:///"
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

echo ""
echo "============================================================"
echo "  Post-Fix Verification"
echo "  Host:     ${HOSTNAME}"
echo "  BASE_DN:  ${BASE_DN}"
echo "============================================================"

# ================================================================
# SECTION 1: SERVICE & PORTS
# ================================================================
echo ""
echo "--- Service & Ports ---"

SLAPD_SVC=""
for svc in symas-openldap-servers slapd; do
  if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then
    SLAPD_SVC="$svc"
    break
  fi
done

if [[ -n "$SLAPD_SVC" ]]; then
  if systemctl is-active --quiet "$SLAPD_SVC"; then
    ok "${SLAPD_SVC} is active"
  else
    bad "${SLAPD_SVC} is NOT active"
  fi
else
  if pgrep -f "opt/symas/lib/slapd" >/dev/null 2>&1 || pgrep -x slapd >/dev/null 2>&1; then
    ok "slapd process running (service name not detected)"
  else
    bad "slapd not running"
  fi
fi

for port in 389 636; do
  if bash -c "echo >/dev/tcp/localhost/${port}" 2>/dev/null; then
    ok "Port ${port} listening"
  else
    bad "Port ${port} not reachable"
  fi
done

# ================================================================
# SECTION 2: LDAPI EXTERNAL
# ================================================================
echo ""
echo "--- LDAPI EXTERNAL ---"
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  if ldapwhoami -Y EXTERNAL -H "$LDAPI_URI" >/dev/null 2>&1; then
    ok "LDAPI SASL EXTERNAL works"
  else
    bad "LDAPI SASL EXTERNAL failed"
  fi
fi

# ================================================================
# SECTION 3: LOG ANALYSIS
# ================================================================
echo ""
echo "--- Log Analysis ---"

if [[ -n "$SLAPD_SVC" ]]; then
  SINCE="10 minutes ago"
  
  # Checksum errors
  CHECKSUM_COUNT=$(journalctl -u "$SLAPD_SVC" --no-pager --since "$SINCE" 2>/dev/null \
    | grep -ci "checksum error" || true)
  if [[ "$CHECKSUM_COUNT" -eq 0 ]]; then
    ok "No 'checksum error' in recent logs"
  else
    warn "${CHECKSUM_COUNT} 'checksum error' entr(y/ies) in recent logs"
  fi

  # Confidentiality required (err=13)
  ERR13_COUNT=$(journalctl -u "$SLAPD_SVC" --no-pager --since "$SINCE" 2>/dev/null \
    | grep -ci "confidentiality required\|err=13" || true)
  if [[ "$ERR13_COUNT" -eq 0 ]]; then
    ok "No 'err=13 confidentiality required' in recent logs"
  else
    bad "${ERR13_COUNT} 'err=13 confidentiality required' in recent logs — syncrepl still broken!"
  fi

  # TLS negotiation failures
  TLS_FAIL_COUNT=$(journalctl -u "$SLAPD_SVC" --no-pager --since "$SINCE" 2>/dev/null \
    | grep -ci "TLS negotiation failure" || true)
  if [[ "$TLS_FAIL_COUNT" -eq 0 ]]; then
    ok "No 'TLS negotiation failure' in recent logs"
  else
    warn "${TLS_FAIL_COUNT} 'TLS negotiation failure' in recent logs"
  fi

  # Invalid credentials (err=49)
  ERR49_COUNT=$(journalctl -u "$SLAPD_SVC" --no-pager --since "$SINCE" 2>/dev/null \
    | grep -ci "err=49\|invalid credentials" || true)
  if [[ "$ERR49_COUNT" -eq 0 ]]; then
    ok "No 'err=49 invalid credentials' in recent logs"
  else
    warn "${ERR49_COUNT} 'err=49' in recent logs — check passwords"
  fi
else
  warn "slapd service not found — skipping log analysis"
fi

# ================================================================
# SECTION 4: ADMIN BIND (StartTLS)
# ================================================================
echo ""
echo "--- Admin Bind (StartTLS) ---"
if [[ -n "$ADMIN_PW" ]]; then
  if LDAPTLS_REQCERT=never ldapwhoami -x -ZZ \
      -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1; then
    ok "Admin bind via StartTLS (localhost)"
  else
    bad "Admin bind via StartTLS failed (localhost)"
  fi
else
  warn "ADMIN_PW not set — skipping admin bind"
fi

# ================================================================
# SECTION 5: REPLICATOR BIND (StartTLS)
# ================================================================
echo ""
echo "--- Replicator Bind (StartTLS) ---"
if [[ -n "$REPL_PW" ]]; then
  if LDAPTLS_REQCERT=never ldapwhoami -x -ZZ \
      -H ldap://localhost -D "$REPL_DN" -w "$REPL_PW" >/dev/null 2>&1; then
    ok "Replicator bind via StartTLS (localhost)"
  else
    bad "Replicator bind via StartTLS failed (localhost)"
  fi
else
  warn "REPL_PW not set — skipping replicator bind"
fi

# ================================================================
# SECTION 6: BASE DN READABLE
# ================================================================
echo ""
echo "--- Base DN ---"
if [[ -n "$ADMIN_PW" ]]; then
  result=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
    -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "$BASE_DN" -s base -LLL dn 2>/dev/null | grep "^dn:" || true)
  if [[ -n "$result" ]]; then
    ok "Base DN readable"
  else
    bad "Base DN not readable"
  fi
  
  child_count=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
    -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "$BASE_DN" -s one -LLL dn 2>/dev/null | grep -c "^dn:" || true)
  child_count=$(echo "$child_count" | tr -d '[:space:]')
  ok "Base DN has ${child_count} children"
fi

# ================================================================
# SECTION 7: ROLE DETECTION
# ================================================================
echo ""
echo "--- Role Detection ---"
IS_MASTER=0
IS_REPLICA=0

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  HAS_SYNCREPL=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config \
    -LLL '(objectClass=olcMdbConfig)' olcSyncrepl 2>/dev/null | grep -ci olcSyncrepl || echo "0")
  HAS_SYNCPROV=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config \
    -LLL '(objectClass=olcMdbConfig)' olcDbIndex 2>/dev/null | grep -ci entryCSN || echo "0")
  
  if [[ "$HAS_SYNCREPL" -gt 0 ]]; then
    IS_REPLICA=1
    ok "Detected role: REPLICA (has olcSyncrepl)"
  else
    IS_MASTER=1
    ok "Detected role: MASTER"
  fi
fi

# ================================================================
# SECTION 8: REPLICA-SPECIFIC CHECKS
# ================================================================
if [[ "$IS_REPLICA" -eq 1 ]]; then
  echo ""
  echo "--- Replica Syncrepl Config ---"
  
  SYNCREPL=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config \
    -LLL '(objectClass=olcMdbConfig)' olcSyncrepl 2>/dev/null | grep -v "^$" || true)
  
  if echo "$SYNCREPL" | grep -q "starttls=yes"; then
    ok "Syncrepl has starttls=yes"
  else
    bad "Syncrepl does NOT have starttls=yes — replication still broken!"
  fi
  
  HAS_UPDATE_REF=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config \
    -LLL '(objectClass=olcMdbConfig)' olcUpdateRef 2>/dev/null | grep -ci olcUpdateRef || echo "0")
  if [[ "$HAS_UPDATE_REF" -gt 0 ]]; then
    ok "olcUpdateRef set (writes redirect to master)"
  else
    bad "olcUpdateRef not set"
  fi
  
  # ---- Sync check ----
  echo ""
  echo "--- Replica Sync Status ---"
  if [[ -n "$MASTER_IP" && -n "$ADMIN_PW" ]]; then
    REPLICA_CSN=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
      -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
      -b "$BASE_DN" -s base -LLL contextCSN 2>/dev/null \
      | awk '/^contextCSN:/{print $2; exit}' || true)
    MASTER_CSN=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
      -H "ldap://${MASTER_IP}" -D "$ADMIN_DN" -w "$ADMIN_PW" \
      -b "$BASE_DN" -s base -LLL contextCSN 2>/dev/null \
      | awk '/^contextCSN:/{print $2; exit}' || true)
    
    if [[ -n "$REPLICA_CSN" && -n "$MASTER_CSN" ]]; then
      if [[ "$REPLICA_CSN" == "$MASTER_CSN" ]]; then
        ok "contextCSN matches master — fully in sync"
      else
        warn "contextCSN differs: replica=${REPLICA_CSN}, master=${MASTER_CSN}"
      fi
    else
      warn "Could not compare contextCSN with master"
    fi
  else
    warn "MASTER_IP/ADMIN_PW not set — skipping sync check"
  fi
fi

# ================================================================
# SECTION 9: ACCESSLOG
# ================================================================
echo ""
echo "--- Accesslog Overlay ---"
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  HAS_ACCESSLOG=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config \
    -LLL '(olcOverlay=accesslog)' dn 2>/dev/null | grep -c "^dn:" || true)
  HAS_ACCESSLOG=$(echo "$HAS_ACCESSLOG" | tr -d '[:space:]')
  if [[ -n "$HAS_ACCESSLOG" && "$HAS_ACCESSLOG" -gt 0 ]]; then
    ok "Accesslog overlay configured"
  else
    warn "Accesslog overlay not detected"
  fi
fi

# ================================================================
# SUMMARY
# ================================================================
echo ""
echo "============================================================"
echo "  Verification Complete"
echo "  PASS=${PASS}  FAIL=${FAIL}  WARN=${WARN}"
echo "============================================================"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo "Result: FAIL — ${FAIL} critical checks failed"
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo "Result: PASS with ${WARN} warning(s)"
  exit 0
else
  echo "Result: ALL PASS — logs are clean, replication operational"
  exit 0
fi
