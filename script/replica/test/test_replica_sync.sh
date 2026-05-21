#!/usr/bin/env bash
# test/test_replica_sync.sh
#
# Integration test: verifies data written to master appears on replica.
# Creates test user on master, reads it from replica, then cleans up.
#
# Required env:
#   MASTER_IP   - master IP/hostname
#   ADMIN_PW    - admin password
#   BASE_DN     - LDAP base DN (default: dc=eab,dc=bank,dc=local)
#
# Usage: sudo MASTER_IP=10.0.0.1 ADMIN_PW=secret bash test_replica_sync.sh
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
SYNC_WAIT="${SYNC_WAIT:-10}"  # seconds to wait for replication

TEST_UID="repl-sync-test-$(date +%Y%m%d%H%M%S)"
TEST_DN="uid=${TEST_UID},ou=Users,${BASE_DN}"

echo "======================================"
echo "Test: Replication Sync (master→replica)"
echo "  Master:   ${MASTER_IP}"
echo "  Replica:  localhost"
echo "  BASE_DN:  ${BASE_DN}"
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

if LDAPTLS_REQCERT=never ldapadd -x -ZZ \
    -H "ldap://${MASTER_IP}" \
    -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -f "$tmp_ldif" 2>&1; then
  pass "Test user created on master: ${TEST_DN}"
else
  fail "Could not create test user on master — check MASTER_IP, ADMIN_PW, master health"
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
result=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
  -H ldap://localhost \
  -D "$ADMIN_DN" -w "$ADMIN_PW" \
  -b "ou=Users,${BASE_DN}" \
  "(uid=${TEST_UID})" dn 2>/dev/null | grep "^dn:" || true)

if [[ -n "$result" ]]; then
  pass "Test user found on replica after ${SYNC_WAIT}s: ${TEST_DN}"
else
  fail "Test user NOT found on replica after ${SYNC_WAIT}s — sync lag or replication broken"
  fail "Try increasing SYNC_WAIT or check: journalctl -u symas-openldap-servers -n 30"
fi

# Cleanup: delete from master (will sync to replica)
echo ""
echo "[INFO] Cleaning up test entry on master"
LDAPTLS_REQCERT=never ldapdelete -x -ZZ \
  -H "ldap://${MASTER_IP}" \
  -D "$ADMIN_DN" -w "$ADMIN_PW" \
  "$TEST_DN" >/dev/null 2>&1 && echo "[INFO] Test entry deleted from master" || \
  echo "[WARN] Could not delete test entry — clean up manually: ${TEST_DN}"

echo ""
echo "======================================"
echo "PASS=${PASS}  FAIL=${FAIL}"
[[ "$FAIL" -eq 0 ]] && echo "[SUCCESS] Replication sync test passed" || echo "[FAIL] Replication sync test failed"
echo "======================================"
[[ "$FAIL" -eq 0 ]]
