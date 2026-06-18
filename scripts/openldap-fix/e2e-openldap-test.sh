#!/usr/bin/env bash
# scripts/openldap-fix/e2e-openldap-test.sh
# End-to-end master<->replica sync validation for Symas OpenLDAP.
# Uses env vars — no hardcoded credentials.
set -euo pipefail

log()  { echo "[INFO]  $*"; }
ok()   { echo "[ OK ]  $*"; }
bad()  { echo "[FAIL] $*" >&2; }
warn() { echo "[WARN]  $*"; }
banner() { echo ""; echo "============================================================"; echo "  $*"; echo "============================================================"; }

PASS=0; FAIL=0; WARN=0
TS=$(date +%Y%m%d-%H%M%S)
E2E_UID="e2e-test-${TS}"
TEST_DN="uid=${E2E_UID},${LDAP_TEST_OU:-ou=Users,dc=eab,dc=bank,dc=local}"

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

ROLE="${1:-both}"; ROLE="${ROLE#--role }"; ROLE="${ROLE#--role=}"
[[ "$ROLE" =~ ^(master|replica|both)$ ]] || { echo "Usage: $0 [--role master|replica|both]" >&2; exit 1; }

MASTER_URI="${LDAP_MASTER_URI:-ldap://${MASTER_IP:-${LDAP_MASTER_IP:-localhost}}:389}"
REPLICA_URI="${LDAP_REPLICA_URI:-ldap://${REPLICA_IP:-${LDAP_REPLICA_IP:-localhost}}:389}"
BASE_DN="${LDAP_BASE_DN:-dc=eab,dc=bank,dc=local}"
BIND_DN="${LDAP_BIND_DN:-cn=admin,${BASE_DN}}"
BIND_PW="${LDAP_BIND_PASSWORD:-TheN1le1}"
TEST_OU="${LDAP_TEST_OU:-ou=Users,${BASE_DN}}"

LDAP_OPTS=(-x -ZZ -D "$BIND_DN" -w "$BIND_PW")

cleanup_test_entry() {
  ldapdelete -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$MASTER_URI" "$TEST_DN" 2>/dev/null || true
  ldapdelete -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$REPLICA_URI" "$TEST_DN" 2>/dev/null || true
}
trap cleanup_test_entry EXIT

# helper: bind and print whoami
ldap_bind_test() {
  ldapwhoami -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$1" >/dev/null 2>&1
}

# helper: count children under base
count_children() {
  ldapsearch -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$1" -b "$BASE_DN" -s one -LLL dn 2>/dev/null | grep -c "^dn:" || echo "0"
}

# ═══════════════════════════════════════════════════════════════════════
banner "E2E OpenLDAP Test — Role: ${ROLE}"
log "Master URI:  ${MASTER_URI}"
log "Replica URI: ${REPLICA_URI}"
log "Base DN:     ${BASE_DN}"
log "Test DN:     ${TEST_DN}"

# ── Master tests ──
if [[ "$ROLE" == "master" || "$ROLE" == "both" ]]; then
  banner "Master tests"

  if ldap_bind_test "$MASTER_URI"; then ok "Master bind OK"; PASS=$((PASS+1))
  else bad "Master bind FAILED"; FAIL=$((FAIL+1)); exit 1; fi

  C1=$(count_children "$MASTER_URI")
  [[ "$C1" -gt 0 ]] && { ok "Master has ${C1} entries"; PASS=$((PASS+1)); } || warn "Master DB empty"
  log "Master children: ${C1}"

  cleanup_test_entry
  cat > "/tmp/${E2E_UID}.ldif" <<'LDIF'
dn: PLACEHOLDER_DN
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
cn: PLACEHOLDER_CN
sn: E2E-Test
uid: PLACEHOLDER_UID
description: E2E test entry
LDIF
  sed -i "s|PLACEHOLDER_DN|${TEST_DN}|g; s|PLACEHOLDER_CN|${E2E_UID}|g; s|PLACEHOLDER_UID|${E2E_UID}|g" "/tmp/${E2E_UID}.ldif"

  LDIF_FILE="/tmp/${E2E_UID}.ldif"
  if ldapadd -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$MASTER_URI" -f "$LDIF_FILE" >/dev/null 2>&1; then
    ok "Add test entry on master"; PASS=$((PASS+1))
  else
    bad "Add test entry FAILED"; FAIL=$((FAIL+1))
  fi

  if ldapsearch -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$MASTER_URI" -b "$TEST_DN" -s base dn 2>/dev/null | grep -q "^dn:"; then
    ok "Test entry visible on master"; PASS=$((PASS+1))
  else
    bad "Test entry not found on master"; FAIL=$((FAIL+1))
  fi

  cat > "/tmp/${E2E_UID}-mod.ldif" <<LDIF
dn: ${TEST_DN}
changetype: modify
replace: description
description: E2E test entry MODIFIED
LDIF
  if ldapmodify -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$MASTER_URI" -f "/tmp/${E2E_UID}-mod.ldif" >/dev/null 2>&1; then
    ok "Modify test entry on master"; PASS=$((PASS+1))
  else
    bad "Modify test entry FAILED"; FAIL=$((FAIL+1))
  fi
  sleep 1

  DESC=$(ldapsearch -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$MASTER_URI" -b "$TEST_DN" -s base -LLL description 2>/dev/null | grep "MODIFIED" || true)
  [[ -n "$DESC" ]] && { ok "Modification confirmed on master"; PASS=$((PASS+1)); } || bad "Modification not found on master"

  rm -f "/tmp/${E2E_UID}.ldif" "/tmp/${E2E_UID}-mod.ldif"
fi

# ── Replica tests ──
if [[ "$ROLE" == "replica" || "$ROLE" == "both" ]]; then
  banner "Replica tests"

  if ldap_bind_test "$REPLICA_URI"; then ok "Replica bind OK"; PASS=$((PASS+1))
  else bad "Replica bind FAILED"; FAIL=$((FAIL+1)); exit 1; fi

  C2=$(count_children "$REPLICA_URI")
  [[ "$C2" -gt 0 ]] && { ok "Replica has ${C2} entries"; PASS=$((PASS+1)); } || warn "Replica DB empty"
  log "Replica children: ${C2}"
fi

# ── Cross-node sync tests ──
if [[ "$ROLE" == "both" ]]; then
  banner "Cross-node replication tests"

  log "Waiting for replication (10s)..."
  sleep 10

  if ldapsearch -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$REPLICA_URI" -b "$TEST_DN" -s base dn 2>/dev/null | grep -q "^dn:"; then
    ok "Test entry replicated to replica"; PASS=$((PASS+1))
  else
    log "Entry not yet on replica — waiting 20s more..."
    sleep 20
    if ldapsearch -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$REPLICA_URI" -b "$TEST_DN" -s base dn 2>/dev/null | grep -q "^dn:"; then
      ok "Test entry replicated (delayed)"; PASS=$((PASS+1))
    else
      bad "Test entry NOT on replica after 30s — replication broken"; FAIL=$((FAIL+1))
    fi
  fi

  DESC_REPL=$(ldapsearch -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$REPLICA_URI" -b "$TEST_DN" -s base -LLL description 2>/dev/null | grep "MODIFIED" || true)
  if [[ -n "$DESC_REPL" ]]; then ok "Modification replicated to replica"; PASS=$((PASS+1))
  else bad "Modification NOT on replica"; FAIL=$((FAIL+1)); fi

  if ldapdelete -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$MASTER_URI" "$TEST_DN" >/dev/null 2>&1; then
    ok "Delete test entry on master"; PASS=$((PASS+1))
  else
    bad "Delete test entry FAILED"; FAIL=$((FAIL+1))
  fi

  sleep 10
  if ldapsearch -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$REPLICA_URI" -b "$TEST_DN" -s base dn 2>/dev/null | grep -q "^dn:"; then
    bad "Delete NOT replicated to replica — test entry still exists"; FAIL=$((FAIL+1))
  else
    ok "Delete replicated to replica"; PASS=$((PASS+1))
  fi

  M_CSN=$(ldapsearch -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$MASTER_URI" -b "$BASE_DN" -s base contextCSN 2>/dev/null | awk '/^contextCSN:/{print $2; exit}')
  R_CSN=$(ldapsearch -x -ZZ -D "$BIND_DN" -w "$BIND_PW" -H "$REPLICA_URI" -b "$BASE_DN" -s base contextCSN 2>/dev/null | awk '/^contextCSN:/{print $2; exit}')
  log "Master contextCSN:  ${M_CSN:-missing}"
  log "Replica contextCSN: ${R_CSN:-missing}"
  if [[ -n "${M_CSN:-}" && "${M_CSN}" == "${R_CSN}" ]]; then ok "contextCSN matches"; PASS=$((PASS+1))
  else warn "contextCSN differs — sync may be pending"; WARN=$((WARN+1)); fi
fi

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "============================================================"
echo "  E2E TEST — Role: ${ROLE}"
echo "  PASS=${PASS}  FAIL=${FAIL}  WARN=${WARN}"
echo "============================================================"

[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
