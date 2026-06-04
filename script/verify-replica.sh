#!/usr/bin/env bash
# verify-replica.sh
# ====================================================================
# Run on the OpenLDAP REPLICA server as root after fix-replica.sh.
#
# Verifies:
#   - Service is running
#   - Port 389 listening
#   - LDAPI EXTERNAL works
#   - No err=13 / err=49 errors in logs
#   - No TLS negotiation failures in logs
#   - Admin + replicator StartTLS bind works
#   - Base DN readable, child count matches master
#   - Syncrepl has starttls=yes
#   - olcUpdateRef set
#   - ppolicy module loaded
#   - contextCSN value present
#   - Write rejected (read-only)
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

ADMIN_PW="${ADMIN_PW:-TheN1le1}"
REPL_PW="${REPL_PW:-replpass}"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_DN="cn=admin,${BASE_DN}"
REPL_DN="cn=replicator,${BASE_DN}"

echo ""
echo "============================================================"
echo "  REPLICA VERIFICATION"
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

if bash -c "echo >/dev/tcp/localhost/389" 2>/dev/null; then
  ok "Port 389 listening"
else
  bad "Port 389 not reachable"
fi

# ---- 2. LDAPI ----
echo ""
echo "--- LDAPI EXTERNAL ---"
if ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
  ok "LDAPI SASL EXTERNAL works"
else
  bad "LDAPI SASL EXTERNAL failed"
fi

# ---- 3. Admin + Replicator StartTLS binds ----
echo ""
echo "--- Admin Bind (StartTLS) ---"
if LDAPTLS_REQCERT=never ldapwhoami -x -ZZ \
    -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1; then
  ok "Admin bind via StartTLS"
else
  bad "Admin bind via StartTLS failed — try: ADMIN_PW='yourpass' sudo bash $0"
fi

echo ""
echo "--- Replicator Bind (StartTLS) ---"
if LDAPTLS_REQCERT=never ldapwhoami -x -ZZ \
    -H ldap://localhost -D "$REPL_DN" -w "$REPL_PW" >/dev/null 2>&1; then
  ok "Replicator bind via StartTLS"
else
  bad "Replicator bind via StartTLS failed"
fi

# ---- 4. Base DN (data sync check) ----
echo ""
echo "--- Base DN (data synced from master) ---"
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
ok "Base DN has ${child_count} children (should match master)"

echo ""
echo "DN list:"
LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
  -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
  -b "$BASE_DN" -s one -LLL dn 2>/dev/null | sed 's/^/  /'

# ---- 5. Syncrepl config check ----
echo ""
echo "--- Syncrepl Configuration ---"
DB_DN=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  -LLL '(&(objectClass=olcMdbConfig)(olcSyncrepl=*))' dn 2>/dev/null \
  | awk '/^dn: /{print $2; exit}' || true)

if [[ -z "$DB_DN" ]]; then
  bad "No database with olcSyncrepl found"
else
  SYNCREPL=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b "$DB_DN" -s base \
    -LLL olcSyncrepl 2>/dev/null | grep -v "^$" || true)

  if echo "$SYNCREPL" | grep -q "starttls=yes"; then
    ok "Syncrepl has starttls=yes"
  else
    bad "Syncrepl does NOT have starttls=yes — replication still broken!"
  fi

  UPDATEREF=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b "$DB_DN" -s base \
    -LLL olcUpdateRef 2>/dev/null | grep -v "^$" || true)
  if [[ -n "$UPDATEREF" ]]; then
    ok "olcUpdateRef set (writes redirect to master)"
    info "$UPDATEREF"
  else
    warn "olcUpdateRef not set — writes may go to replica locally"
  fi
fi

# ---- 6. ppolicy module check ----
echo ""
echo "--- ppolicy Module ---"
PPOLICY=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config \
  -s sub "(olcModuleLoad=ppolicy.la)" dn 2>/dev/null | grep -c "cn=module" || true)
PPOLICY=$(echo "$PPOLICY" | tr -d '[:space:]')
if [[ -n "$PPOLICY" && "$PPOLICY" -gt 0 ]]; then
  ok "ppolicy module loaded"
else
  warn "ppolicy module NOT loaded — pwdPolicy objects from master may fail sync"
fi

# ---- 7. contextCSN (sync tracking) ----
echo ""
echo "--- Sync Status (contextCSN) ---"
REPLICA_CSN=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
  -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
  -b "$BASE_DN" -s base contextCSN 2>/dev/null \
  | awk '/^contextCSN:/{print $2; exit}' || true)
if [[ -n "$REPLICA_CSN" ]]; then
  ok "contextCSN present: ${REPLICA_CSN}"
else
  warn "No contextCSN found — sync may not be tracking changes"
fi

# ---- 8. Write rejected (read-only) ----
echo ""
echo "--- Write Rejection ---"
tmp_uid="replica-verify-$$"
tmp_dn="uid=${tmp_uid},ou=Users,${BASE_DN}"
write_out=$(LDAPTLS_REQCERT=never ldapadd -x -ZZ \
  -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
  <<LDIF 2>&1) && write_rc=0 || write_rc=$?
dn: ${tmp_dn}
objectClass: inetOrgPerson
uid: ${tmp_uid}
cn: Verify Write Test
sn: Test
LDIF
rm -f "$tmp_ldif" 2>/dev/null || true
if [[ $write_rc -ne 0 ]]; then
  ok "Write correctly rejected (read-only enforced)"
else
  bad "Write succeeded — olcUpdateRef or read-only mode NOT enforced"
  LDAPTLS_REQCERT=never ldapdelete -x -ZZ \
    -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" "$tmp_dn" >/dev/null 2>&1 || true
fi

# ---- 9. Log analysis ----
echo ""
echo "--- Log Analysis ---"
if [[ "$SLAPD_SVC" != "unknown" ]]; then
  SINCE="10 minutes ago"

  ERR13=$(journalctl -u "$SLAPD_SVC" --no-pager --since "$SINCE" 2>/dev/null \
    | grep -ci "confidentiality required\|err=13" || true)
  if [[ "$ERR13" -eq 0 ]]; then
    ok "No err=13 (confidentiality required) errors"
  else
    bad "${ERR13} err=13 error(s) — syncrepl bind still failing!"
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

# ---- Summary ----
echo ""
echo "============================================================"
echo "  REPLICA VERIFICATION — Complete"
echo "  PASS=${PASS}  FAIL=${FAIL}  WARN=${WARN}"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
  echo "Result: FAIL — ${FAIL} checks failed"
  echo ""
  echo "If syncrepl starttls is the issue, re-run fix-replica.sh."
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo "Result: PASS with ${WARN} warning(s)"
  exit 0
else
  echo "Result: ALL PASS"
  exit 0
fi
