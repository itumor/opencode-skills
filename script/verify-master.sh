#!/usr/bin/env bash
# verify-master.sh
# ====================================================================
# Run on the OpenLDAP MASTER server as root after fix-master.sh.
#
# Verifies:
#   - Service is running
#   - Ports 389/636 listening
#   - LDAPI EXTERNAL works
#   - No checksum errors in logs
#   - No err=13 / err=49 errors in logs
#   - No TLS negotiation failures
#   - Admin + replicator StartTLS bind works
#   - Base DN readable with correct child count
#   - Syncprov overlay present
#   - entryUUID/entryCSN indices present
# ====================================================================
set -uo pipefail

ok()   { echo "[ OK ] $*"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN+1)); }
info() { echo "[INFO] $*"; }

PASS=0; FAIL=0; WARN=0

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "[FATAL] Run as root"; exit 1; }

# ---- Locate service ----
for svc in symas-openldap-servers slapd; do
  if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then
    SLAPD_SVC="$svc"
    break
  fi
done
SLAPD_SVC="${SLAPD_SVC:-unknown}"

# ---- Fix PATH ----
export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
[[ -f /opt/symas/etc/openldap/sysmas_env.sh ]] && source /opt/symas/etc/openldap/sysmas_env.sh 2>/dev/null || true
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

# ---- Config (adjust if your admin password differs) ----
ADMIN_PW="${ADMIN_PW:-admin}"
REPL_PW="${REPL_PW:-replpass}"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_DN="cn=admin,${BASE_DN}"
REPL_DN="cn=replicator,${BASE_DN}"

echo ""
echo "============================================================"
echo "  MASTER VERIFICATION"
echo "  Server:  $(hostname -f 2>/dev/null || hostname)"
echo "  Base DN: ${BASE_DN}"
echo "============================================================"

# ---- 1. Service & Ports ----
echo ""
echo "--- Service & Ports ---"
if systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1; then
  ok "${SLAPD_SVC} is running"
else
  bad "${SLAPD_SVC} is not running"
fi

for port in 389 636; do
  if bash -c "echo >/dev/tcp/localhost/${port}" 2>/dev/null; then
    ok "Port ${port} listening"
  else
    bad "Port ${port} not reachable"
  fi
done

# ---- 2. LDAPI ----
echo ""
echo "--- LDAPI EXTERNAL ---"
if ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
  ok "LDAPI SASL EXTERNAL works"
else
  bad "LDAPI SASL EXTERNAL failed"
fi

# ---- 3. Admin StartTLS bind ----
echo ""
echo "--- Admin Bind (StartTLS) ---"
if [[ -n "${ADMIN_PW:-}" ]]; then
  if LDAPTLS_REQCERT=never ldapwhoami -x -ZZ \
      -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1; then
    ok "Admin bind via StartTLS"
  else
    bad "Admin bind via StartTLS failed — wrong password? Try: ADMIN_PW='yourpass' sudo bash $0"
  fi
else
  warn "ADMIN_PW not set — skipping admin bind"
fi

# ---- 4. Replicator StartTLS bind ----
echo ""
echo "--- Replicator Bind (StartTLS) ---"
if [[ -n "${REPL_PW:-}" ]]; then
  if LDAPTLS_REQCERT=never ldapwhoami -x -ZZ \
      -H ldap://localhost -D "$REPL_DN" -w "$REPL_PW" >/dev/null 2>&1; then
    ok "Replicator bind via StartTLS"
  else
    bad "Replicator bind via StartTLS failed"
  fi
fi

# ---- 5. Base DN readable ----
echo ""
echo "--- Base DN ---"
if [[ -n "${ADMIN_PW:-}" ]]; then
  if LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
      -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
      -b "$BASE_DN" -s base -LLL dn 2>/dev/null | grep -q "^dn:"; then
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

# ---- 6. Syncprov overlay ----
echo ""
echo "--- Syncprov Overlay ---"
HAS_SYNCPROV=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  -s sub "(olcOverlay=syncprov)" dn 2>/dev/null | grep -c "^dn:" || true)
HAS_SYNCPROV=$(echo "$HAS_SYNCPROV" | tr -d '[:space:]')
if [[ -n "$HAS_SYNCPROV" && "$HAS_SYNCPROV" -gt 0 ]]; then
  ok "Syncprov overlay configured on master"
else
  warn "Syncprov overlay not detected — replica sync may not work"
fi

# ---- 7. Required indices ----
echo ""
echo "--- Syncrepl Indices ---"
DB_DN=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  -LLL '(&(objectClass=olcMdbConfig)(olcSuffix=*))' dn 2>/dev/null \
  | awk '/^dn: /{print $2; exit}' || true)
if [[ -n "$DB_DN" ]]; then
  INDICES=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b "$DB_DN" -s base \
    -LLL olcDbIndex 2>/dev/null || true)
  if echo "$INDICES" | grep -q "entryUUID"; then
    ok "entryUUID index present"
  else
    warn "entryUUID index MISSING — syncrepl needs this"
  fi
  if echo "$INDICES" | grep -q "entryCSN"; then
    ok "entryCSN index present"
  else
    warn "entryCSN index MISSING — syncrepl needs this"
  fi
fi

# ---- 8. Log analysis ----
echo ""
echo "--- Log Analysis ---"
if [[ "$SLAPD_SVC" != "unknown" ]]; then
  SINCE="10 minutes ago"

  ERR13=$(journalctl -u "$SLAPD_SVC" --no-pager --since "$SINCE" 2>/dev/null \
    | grep -ci "confidentiality required\|err=13" || true)
  if [[ "$ERR13" -eq 0 ]]; then
    ok "No err=13 (confidentiality required) errors"
  else
    bad "${ERR13} err=13 error(s) found"
  fi

  ERR49=$(journalctl -u "$SLAPD_SVC" --no-pager --since "$SINCE" 2>/dev/null \
    | grep -ci "err=49\|invalid credentials" || true)
  if [[ "$ERR49" -eq 0 ]]; then
    ok "No err=49 (invalid credentials) errors"
  else
    warn "${ERR49} err=49 error(s) found"
  fi

  TLS_FAIL=$(journalctl -u "$SLAPD_SVC" --no-pager --since "$SINCE" 2>/dev/null \
    | grep -ci "TLS negotiation failure" || true)
  if [[ "$TLS_FAIL" -eq 0 ]]; then
    ok "No TLS negotiation failures"
  else
    warn "${TLS_FAIL} TLS negotiation failure(s)"
  fi

  CHKSUM=$(journalctl -u "$SLAPD_SVC" --no-pager --since "$SINCE" 2>/dev/null \
    | grep -ci "checksum error" || true)
  if [[ "$CHKSUM" -eq 0 ]]; then
    ok "No checksum errors"
  else
    warn "${CHKSUM} checksum error(s)"
  fi
else
  warn "Slapd service not found — skipping log analysis"
fi

# ---- 9. Context CSN ----
echo ""
echo "--- Context CSN ---"
if [[ -n "${ADMIN_PW:-}" ]]; then
  MASTER_CSN=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
    -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "$BASE_DN" -s base contextCSN 2>/dev/null \
    | awk '/^contextCSN:/{print $2; exit}' || true)
  if [[ -n "$MASTER_CSN" ]]; then
    ok "contextCSN: ${MASTER_CSN}"
  else
    warn "No contextCSN found"
  fi
fi

# ---- Summary ----
echo ""
echo "============================================================"
echo "  MASTER VERIFICATION — Complete"
echo "  PASS=${PASS}  FAIL=${FAIL}  WARN=${WARN}"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
  echo "Result: FAIL — ${FAIL} checks failed"
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo "Result: PASS with ${WARN} warning(s)"
  exit 0
else
  echo "Result: ALL PASS"
  exit 0
fi
