#!/usr/bin/env bash
# r9-verify-replica.sh
#
# Verifies the replica is healthy and syncing from master.
# Checks:
#   1. Service active
#   2. Ports 389/636 listening
#   3. ldapi EXTERNAL access
#   4. Replication config present (olcSyncRepl)
#   5. olcUpdateRef set (write redirect to master)
#   6. Sync status (contextCSN matches master or lag is acceptable)
#   7. Admin bind via StartTLS
#   8. Base DN readable (data synced)
#   9. Test user write rejected (read-only enforcement)
#
# Required env:
#   MASTER_IP   - master hostname/IP
#   ADMIN_PW    - admin password
#   REPL_PW     - replication bind password
#
# Usage: sudo MASTER_IP=10.0.0.1 ADMIN_PW=secret bash r9-verify-replica.sh
set -uo pipefail

ok()   { echo "[ OK ] $*"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN+1)); }
info() { echo "[INFO] $*"; }

PASS=0; FAIL=0; WARN=0

ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  [[ -f "$prof" ]] && source "$prof" 2>/dev/null || true
  [[ ":${PATH}:" == *":/opt/symas/bin:"* ]]  || export PATH="/opt/symas/bin:${PATH}"
  [[ ":${PATH}:" == *":/opt/symas/sbin:"* ]] || export PATH="/opt/symas/sbin:${PATH}"
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

echo ""
echo "============================================================"
echo "  Replica Verification"
echo "  BASE_DN: ${BASE_DN}"
echo "  MASTER:  ${MASTER_IP:-<not set>}"
echo "============================================================"

# 1. Service
echo ""
echo "--- Service ---"
for svc in symas-openldap-servers slapd; do
  if systemctl list-units --type=service 2>/dev/null | grep -q "$svc"; then
    if systemctl is-active --quiet "$svc"; then
      ok "${svc} is active"
    else
      bad "${svc} is NOT active"
    fi
  fi
done
if pgrep -f "opt/symas/lib/slapd" >/dev/null 2>&1 || pgrep -x slapd >/dev/null 2>&1; then
  ok "slapd process running"
else
  bad "slapd process not found"
fi

# 2. Ports
echo ""
echo "--- Ports ---"
for port in 389 636; do
  if bash -c "echo >/dev/tcp/localhost/${port}" 2>/dev/null; then
    ok "Port ${port} listening"
  else
    bad "Port ${port} not reachable"
  fi
done

# 3. ldapi
echo ""
echo "--- ldapi EXTERNAL ---"
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  if ldapwhoami -Y EXTERNAL -H "$LDAPI_URI" >/dev/null 2>&1; then
    ok "ldapi SASL EXTERNAL works"
  else
    bad "ldapi SASL EXTERNAL failed"
  fi
else
  warn "Not root — skipping ldapi EXTERNAL checks"
fi

# 4. Replication config
echo ""
echo "--- Replication Config ---"
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  syncrepl="$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config \
    -LLL '(objectClass=olcMdbConfig)' olcSyncrepl 2>/dev/null | grep -i olcSyncrepl || true)"
  if [[ -n "$syncrepl" ]]; then
    ok "olcSyncrepl configured"
    info "$(echo "$syncrepl" | head -1)"
  else
    bad "olcSyncrepl not found in cn=config (run r2-configure-replica-instance.sh)"
  fi

  updateref="$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config \
    -LLL '(objectClass=olcMdbConfig)' olcUpdateRef 2>/dev/null | grep olcUpdateRef || true)"
  if [[ -n "$updateref" ]]; then
    ok "olcUpdateRef set (writes redirect to master)"
    info "$updateref"
  else
    bad "olcUpdateRef not set — replica may accept writes locally"
  fi
fi

# 5. Admin bind
echo ""
echo "--- Admin Bind ---"
if [[ -n "$ADMIN_PW" ]]; then
  if LDAPTLS_REQCERT=never ldapwhoami -x -ZZ \
      -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1; then
    ok "Admin bind via StartTLS"
  else
    bad "Admin bind via StartTLS failed"
  fi
else
  warn "ADMIN_PW not set — skipping admin bind"
fi

# 6. Base DN readable (data synced)
echo ""
echo "--- Data Sync ---"
if [[ -n "$ADMIN_PW" ]]; then
  result=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
    -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "$BASE_DN" -s one -LLL dn 2>/dev/null | grep "^dn:" || true)
  if [[ -n "$result" ]]; then
    ou_count=$(echo "$result" | wc -l)
    ok "Base DN readable — ${ou_count} child entries found (data synced)"
  else
    warn "Base DN readable but no children found — sync may still be in progress"
  fi

  # Check contextCSN vs master
  if [[ -n "$MASTER_IP" ]]; then
    replica_csn=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
      -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
      -b "$BASE_DN" -s base -LLL contextCSN 2>/dev/null | awk '/^contextCSN:/{print $2; exit}' || true)
    master_csn=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
      -H "ldap://${MASTER_IP}" -D "$ADMIN_DN" -w "$ADMIN_PW" \
      -b "$BASE_DN" -s base -LLL contextCSN 2>/dev/null | awk '/^contextCSN:/{print $2; exit}' || true)
    if [[ -n "$replica_csn" && -n "$master_csn" ]]; then
      if [[ "$replica_csn" == "$master_csn" ]]; then
        ok "contextCSN matches master — fully in sync"
      else
        warn "contextCSN differs from master — replica may be lagging"
        info "  Replica CSN: ${replica_csn}"
        info "  Master  CSN: ${master_csn}"
      fi
    else
      warn "Could not compare contextCSN (master unreachable or no data yet)"
    fi
  else
    warn "MASTER_IP not set — skipping contextCSN comparison"
  fi
fi

# 7. Write must be rejected (replica is read-only)
echo ""
echo "--- Write Rejection ---"
if [[ -n "$ADMIN_PW" ]]; then
  tmp_uid="verify-write-test-$$"
  tmp_dn="uid=${tmp_uid},ou=Users,${BASE_DN}"
  tmp_ldif="$(mktemp /tmp/replica-write-test.XXXXXX.ldif)"
  cat > "$tmp_ldif" <<LDIF
dn: ${tmp_dn}
objectClass: inetOrgPerson
uid: ${tmp_uid}
cn: Write Test
sn: WriteTest
LDIF
  write_out=$(LDAPTLS_REQCERT=never ldapadd -x -ZZ \
    -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -f "$tmp_ldif" 2>&1) && write_rc=0 || write_rc=$?
  rm -f "$tmp_ldif"
  if [[ $write_rc -ne 0 ]]; then
    if echo "$write_out" | grep -qi "referral\|updateRef\|unwilling\|read.only"; then
      ok "Write correctly rejected/referred to master (read-only enforced)"
    else
      ok "Write rejected (rc=${write_rc})"
    fi
  else
    bad "Write succeeded on replica — olcUpdateRef or read-only mode not enforced"
    # Cleanup if accidentally created
    LDAPTLS_REQCERT=never ldapdelete -x -ZZ \
      -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" "$tmp_dn" >/dev/null 2>&1 || true
  fi
fi

# 8. Summary
echo ""
echo "============================================================"
echo "  PASS=${PASS}  FAIL=${FAIL}  WARN=${WARN}"
echo "============================================================"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo "Result: FAIL"
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo "Result: PASS with warnings"
  exit 0
else
  echo "Result: ALL PASS"
  exit 0
fi
