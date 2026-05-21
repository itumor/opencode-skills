#!/usr/bin/env bash
# test/test_replica_readonly.sh
#
# Verifies replica correctly rejects or refers writes back to master.
# A write attempt on the replica should return:
#   - referral (ldap_modify: Referral) pointing to master, OR
#   - unwillingToPerform / read-only error
#
# Usage: sudo ADMIN_PW=secret bash test_replica_readonly.sh
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

TEST_UID="repl-ro-test-$(date +%Y%m%d%H%M%S)"
TEST_DN="uid=${TEST_UID},ou=Users,${BASE_DN}"

echo "======================================"
echo "Test: Replica Read-Only Enforcement"
echo "  Replica:  localhost"
echo "  BASE_DN:  ${BASE_DN}"
echo "======================================"

PASS=0; FAIL=0
pass() { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }

# Attempt write on replica
tmp_ldif="$(mktemp /tmp/repl-ro-test.XXXXXX.ldif)"
cat > "$tmp_ldif" <<LDIF
dn: ${TEST_DN}
objectClass: inetOrgPerson
uid: ${TEST_UID}
cn: RO Test
sn: ROTest
LDIF

write_out=$(LDAPTLS_REQCERT=never ldapadd -x -ZZ \
  -H ldap://localhost \
  -D "$ADMIN_DN" -w "$ADMIN_PW" \
  -f "$tmp_ldif" 2>&1) && write_rc=0 || write_rc=$?
rm -f "$tmp_ldif"

if [[ $write_rc -ne 0 ]]; then
  if echo "$write_out" | grep -qi "referral\|updateRef"; then
    pass "Write correctly referred to master (ldap_add: Referral)"
  elif echo "$write_out" | grep -qi "unwilling\|read.only\|53"; then
    pass "Write correctly rejected (unwillingToPerform / read-only)"
  else
    pass "Write rejected on replica (rc=${write_rc})"
  fi
else
  fail "Write succeeded on replica — olcUpdateRef not configured or syncrepl not active"
  # Cleanup if write accidentally went through
  LDAPTLS_REQCERT=never ldapdelete -x -ZZ \
    -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" "$TEST_DN" >/dev/null 2>&1 || true
fi

# Attempt modify on replica
mod_out=$(LDAPTLS_REQCERT=never ldapmodify -x -ZZ \
  -H ldap://localhost \
  -D "$ADMIN_DN" -w "$ADMIN_PW" 2>&1 <<LDIF || true
dn: ${BASE_DN}
changetype: modify
replace: description
description: replica-write-test
LDIF
)
if echo "$mod_out" | grep -qi "referral\|updateRef\|unwilling\|read.only"; then
  pass "Modify correctly rejected/referred on replica"
else
  fail "Modify did not produce expected referral/rejection on replica"
fi

echo ""
echo "======================================"
echo "PASS=${PASS}  FAIL=${FAIL}"
[[ "$FAIL" -eq 0 ]] && echo "[SUCCESS] Read-only enforcement verified" || echo "[FAIL] Read-only enforcement test failed"
echo "======================================"
[[ "$FAIL" -eq 0 ]]
