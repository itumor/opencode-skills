#!/usr/bin/env bash
# test/test_replica_sync.sh
#
# Integration test: verifies data written to master appears on replica.
# TLS-mode-aware: uses StartTLS when TLS_MODE=yes, plain LDAP when no.
#
# Required env:
#   MASTER_IP   - master IP/hostname
#   ADMIN_PW    - admin password
#   BASE_DN     - LDAP base DN (default: dc=eab,dc=bank,dc=local)
#
# Optional: TLS_MODE=yes|no (default yes)
#
# Usage: sudo MASTER_IP=10.0.0.1 ADMIN_PW=secret TLS_MODE=yes bash test_replica_sync.sh
set -uo pipefail

export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  [[ -f "$prof" ]] && source "$prof" 2>/dev/null || true
  [[ ":${PATH}:" == *":/opt/symas/bin:"* ]]  || export PATH="/opt/symas/bin:${PATH}"
}
ensure_symas_env

MASTER_IP="${MASTER_IP:?MASTER_IP is required}"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_DN="${ADMIN_DN:-cn=admin,${BASE_DN}}"
ADMIN_PW="${ADMIN_PW:?ADMIN_PW is required}"
SYNC_WAIT="${SYNC_WAIT:-10}"
TLS_MODE="${TLS_MODE:-yes}"

TEST_UID="repl-sync-test-$(date +%Y%m%d%H%M%S)"
TEST_DN="uid=${TEST_UID},ou=people,${BASE_DN}"

# Build LDAP args based on TLS mode
if [[ "$TLS_MODE" == "no" ]]; then
  MASTER_LDAP_ARGS=( -x -H "ldap://${MASTER_IP}" )
  LOCAL_LDAP_ARGS=( -x -H ldap://localhost )
else
  MASTER_LDAP_ARGS=( -x -ZZ -H "ldap://${MASTER_IP}" )
  LOCAL_LDAP_ARGS=( -x -ZZ -H ldap://localhost )
fi

echo "======================================"
echo "Test: Replication Sync (master->replica)"
echo "  Master:   ${MASTER_IP}"
echo "  Replica:  localhost"
echo "  BASE_DN:  ${BASE_DN}"
echo "  TLS mode: ${TLS_MODE}"
echo "  Test UID: ${TEST_UID}"
echo "======================================"

PASS=0; FAIL=0

pass() { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }

# Write test user to MASTER
echo ""
echo "[INFO] Writing test user to master ${MASTER_IP}"
tmp_ldif="$(mktemp /tmp/repl-sync-test.XXXXXX.ldif)"
cat > "$tmp_ldif" <<LDIF
dn: ${TEST_DN}
objectClass: inetOrgPerson
uid: ${TEST_UID}
cn: Repl Sync Test
sn: SyncTest
description: Created by test_replica_sync.sh
LDIF

if LDAPTLS_REQCERT=never ldapadd "${MASTER_LDAP_ARGS[@]}" \
    -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -f "$tmp_ldif" 2>&1; then
  pass "Test user created on master: ${TEST_DN}"
else
  fail "Could not create test user on master - check MASTER_IP, ADMIN_PW, master health"
  rm -f "$tmp_ldif"
  exit 1
fi
rm -f "$tmp_ldif"

# Wait for replication
echo ""
echo "[INFO] Waiting ${SYNC_WAIT}s for replication..."
sleep "$SYNC_WAIT"

# Read test user from REPLICA (localhost)
echo "[INFO] Searching for test user on replica (localhost)"
result=$(LDAPTLS_REQCERT=never ldapsearch "${LOCAL_LDAP_ARGS[@]}" \
  -D "$ADMIN_DN" -w "$ADMIN_PW" \
  -b "ou=people,${BASE_DN}" \
  "(uid=${TEST_UID})" dn 2>/dev/null | grep "^dn:" || true)

if [[ -n "$result" ]]; then
  pass "Test user found on replica after ${SYNC_WAIT}s: ${TEST_DN}"
else
  fail "Test user NOT found on replica after ${SYNC_WAIT}s - sync lag or replication broken"
  fail "Try increasing SYNC_WAIT or check: journalctl -u symas-openldap-servers -n 30"
fi

# Cleanup: delete from master (will sync to replica)
echo ""
echo "[INFO] Cleaning up test entry on master"
LDAPTLS_REQCERT=never ldapdelete "${MASTER_LDAP_ARGS[@]}" \
  -D "$ADMIN_DN" -w "$ADMIN_PW" \
  "$TEST_DN" >/dev/null 2>&1 && echo "[INFO] Test entry deleted from master" || \
  echo "[WARN] Could not delete test entry - clean up manually: ${TEST_DN}"

echo ""
echo "======================================"
echo "PASS=${PASS}  FAIL=${FAIL}"
[[ "$FAIL" -eq 0 ]] && echo "[SUCCESS] Replication sync test passed" || echo "[FAIL] Replication sync test failed"
echo "======================================"
[[ "$FAIL" -eq 0 ]]
