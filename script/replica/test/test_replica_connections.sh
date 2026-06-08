#!/usr/bin/env bash
# test/test_replica_connections.sh
#
# Verifies all connection types work on replica.
# TLS-mode-aware: StartTLS/LDAPS when TLS_MODE=yes, plain LDAP when no.
#
# Usage: sudo ADMIN_PW=secret REPL_PW=replpass TLS_MODE=yes bash test_replica_connections.sh
set -uo pipefail

export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  [[ -f "$prof" ]] && source "$prof" 2>/dev/null || true
  [[ ":${PATH}:" == *":/opt/symas/bin:"* ]]  || export PATH="/opt/symas/bin:${PATH}"
}
ensure_symas_env

BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_DN="${ADMIN_DN:-cn=admin,${BASE_DN}}"
ADMIN_PW="${ADMIN_PW:?ADMIN_PW is required}"
REPL_DN="${REPL_DN:-cn=replicator,${BASE_DN}}"
REPL_PW="${REPL_PW:-replpass}"
LDAP_URI="${LDAP_URI:-ldap://localhost}"
LDAPS_URI="${LDAPS_URI:-ldaps://localhost}"
TLS_MODE="${TLS_MODE:-yes}"

PASS=0; FAIL=0; WARN=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }

# Build LDAP args based on TLS mode
if [[ "$TLS_MODE" == "no" ]]; then
  BIND_ARGS=( -x -H "$LDAP_URI" )
  BIND_LABEL="plain LDAP"
else
  BIND_ARGS=( -x -ZZ -H "$LDAP_URI" )
  BIND_LABEL="StartTLS"
fi

echo "======================================"
echo "Test: Replica Connection Tests"
echo "  LDAP:  ${LDAP_URI}"
echo "  TLS:   ${TLS_MODE}"
echo "======================================"

echo ""
echo "=== Port Connectivity ==="
for port in 389; do
  bash -c "echo >/dev/tcp/localhost/${port}" 2>/dev/null \
    && pass "Port ${port} reachable" \
    || fail "Port ${port} not reachable"
done
if [[ "$TLS_MODE" != "no" ]]; then
  bash -c "echo >/dev/tcp/localhost/636" 2>/dev/null \
    && pass "Port 636 reachable (LDAPS)" \
    || fail "Port 636 not reachable"
fi

if [[ "$TLS_MODE" != "no" ]]; then
  echo ""
  echo "=== LDAP Plain + StartTLS ==="
  out=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H "$LDAP_URI" -b '' -s base \
    supportedLDAPVersion 2>&1) || true
  if echo "$out" | grep -qi "anonymous bind disallowed\|Inappropriate\|confidentiality"; then
    pass "StartTLS: server responded (anon bind disabled - expected)"
  elif echo "$out" | grep -qi "supportedLDAPVersion"; then
    pass "StartTLS: RootDSE query OK"
  else
    fail "StartTLS: no response or unexpected error"
  fi
fi

if [[ "$TLS_MODE" != "no" ]]; then
  echo ""
  echo "=== LDAPS (636) ==="
  out=$(LDAPTLS_REQCERT=never ldapsearch -x -H "$LDAPS_URI" -b '' -s base \
    supportedLDAPVersion 2>&1) || true
  if echo "$out" | grep -qi "anonymous bind disallowed\|Inappropriate\|confidentiality"; then
    pass "LDAPS: server responded (anon bind disabled - expected)"
  elif echo "$out" | grep -qi "supportedLDAPVersion"; then
    pass "LDAPS: RootDSE query OK"
  elif echo "$out" | grep -qi "Can't contact\|Connection refused"; then
    fail "LDAPS: port 636 not reachable"
  else
    fail "LDAPS: unexpected error"
  fi
fi

echo ""
echo "=== Admin Bind ==="
if LDAPTLS_REQCERT=never ldapwhoami "${BIND_ARGS[@]}" \
    -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1; then
  pass "Admin bind via ${BIND_LABEL}"
else
  fail "Admin bind via ${BIND_LABEL} failed"
fi

echo ""
echo "=== Replication Bind ==="
out=$(LDAPTLS_REQCERT=never ldapwhoami "${BIND_ARGS[@]}" \
  -D "$REPL_DN" -w "$REPL_PW" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
  pass "Replication bind OK: ${REPL_DN}"
elif echo "$out" | grep -qi "No such object\|32"; then
  warn "Replication DN not found on replica yet (may sync from master)"
else
  fail "Replication bind failed (rc=${rc})"
fi

echo ""
echo "=== Base DN Readable ==="
out=$(LDAPTLS_REQCERT=never ldapsearch "${BIND_ARGS[@]}" \
  -D "$ADMIN_DN" -w "$ADMIN_PW" \
  -b "$BASE_DN" -s base -LLL dn 2>/dev/null) || true
if echo "$out" | grep -qi "^dn:"; then
  pass "Base DN readable: ${BASE_DN}"
else
  warn "Base DN not yet readable - sync may still be in progress"
fi

echo ""
echo "======================================"
echo "PASS=${PASS}  FAIL=${FAIL}  WARN=${WARN}"
[[ "$FAIL" -eq 0 ]] && echo "[SUCCESS] All connection tests passed" || echo "[FAIL] Some connection tests failed"
echo "======================================"
[[ "$FAIL" -eq 0 ]]
