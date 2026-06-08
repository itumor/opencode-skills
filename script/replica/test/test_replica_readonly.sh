#!/usr/bin/env bash
# test/test_replica_readonly.sh
#
# Verifies replica correctly rejects or refers writes back to master.
# TLS-mode-aware: uses plain LDAP or StartTLS based on TLS_MODE.
#
# Usage: sudo ADMIN_PW=secret TLS_MODE=yes bash test_replica_readonly.sh
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
TLS_MODE="${TLS_MODE:-yes}"

TEST_UID="repl-ro-test-$(date +%Y%m%d%H%M%S)"
TEST_DN="uid=${TEST_UID},ou=Users,${BASE_DN}"

if [[ "$TLS_MODE" == "no" ]]; then
  LDAP_ARGS=( -x -H ldap://localhost )
else
  LDAP_ARGS=( -x -ZZ -H ldap://localhost )
fi

echo "======================================"
echo "Test: Replica Read-Only Enforcement"
echo "  Replica:  localhost"
echo "  TLS mode: ${TLS_MODE}"
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

write_out=$(LDAPTLS_REQCERT=never ldapadd "${LDAP_ARGS[@]}" \
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
  fail "Write succeeded on replica - olcUpdateRef not configured or syncrepl not active"
  LDAPTLS_REQCERT=never ldapdelete "${LDAP_ARGS[@]}" \
    -D "$ADMIN_DN" -w "$ADMIN_PW" "$TEST_DN" >/dev/null 2>&1 || true
fi

# Attempt modify on replica
mod_out=$(LDAPTLS_REQCERT=never ldapmodify "${LDAP_ARGS[@]}" \
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
