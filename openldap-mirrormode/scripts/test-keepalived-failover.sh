#!/usr/bin/env bash
set -euo pipefail

# =========================
# User-configurable values
# =========================
BASE_DN="${BASE_DN:-dc=cae,dc=local}"
ADMIN_DN="${ADMIN_DN:-cn=admin,${BASE_DN}}"
ADMIN_PW="${ADMIN_PW:-admin}"

VIP_HOST="${VIP_HOST:-192.168.56.50}"
VIP_LDAP_PORT="${VIP_LDAP_PORT:-389}"
VIP_URI="${VIP_URI:-ldap://${VIP_HOST}:${VIP_LDAP_PORT}}"

# Optional direct node URIs for replication verification
MASTER_A_URI="${MASTER_A_URI:-}"
MASTER_B_URI="${MASTER_B_URI:-}"

# How long to wait for replication after writes
REPL_WAIT_SECONDS="${REPL_WAIT_SECONDS:-10}"

# How long to wait after failover trigger
FAILOVER_WAIT_SECONDS="${FAILOVER_WAIT_SECONDS:-5}"

# Optional commands to trigger failover/failback (e.g., ssh to stop/start keepalived)
FAILOVER_CMD="${FAILOVER_CMD:-}"
FAILBACK_CMD="${FAILBACK_CMD:-}"

RUN_FAILOVER=0
RUN_CLEANUP=1

usage() {
  cat <<USAGE
Usage: $0 [--failover] [--no-cleanup]

Environment overrides:
  BASE_DN, ADMIN_DN, ADMIN_PW,
  VIP_HOST, VIP_LDAP_PORT, VIP_URI,
  MASTER_A_URI, MASTER_B_URI,
  REPL_WAIT_SECONDS, FAILOVER_WAIT_SECONDS,
  FAILOVER_CMD, FAILBACK_CMD

Examples:
  VIP_HOST=192.168.10.50 ./scripts/test-keepalived-failover.sh
  MASTER_A_URI=ldap://ldap1:389 MASTER_B_URI=ldap://ldap2:389
  FAILOVER_CMD="ssh root@ldap1 'systemctl stop keepalived'"
  FAILBACK_CMD="ssh root@ldap1 'systemctl start keepalived'"
  ./scripts/test-keepalived-failover.sh --failover
USAGE
}

for arg in "$@"; do
  [[ -z "$arg" ]] && continue
  case "$arg" in
    --failover) RUN_FAILOVER=1 ;;
    --no-cleanup) RUN_CLEANUP=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $arg"; usage; exit 2 ;;
  esac
done

# ================
# Output helpers
# ================
PASS_COUNT=0
FAIL_COUNT=0
declare -a RESULTS

green() { printf "\033[0;32m%s\033[0m\n" "$*"; }
red()   { printf "\033[0;31m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[0;33m%s\033[0m\n" "$*"; }

record_pass() { PASS_COUNT=$((PASS_COUNT+1)); RESULTS+=("PASS | $1"); green "PASS: $1"; }
record_fail() { FAIL_COUNT=$((FAIL_COUNT+1)); RESULTS+=("FAIL | $1"); red   "FAIL: $1"; }

# ==============================
# Command runners
# ==============================
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }
}

need_cmd ldapwhoami
need_cmd ldapsearch
need_cmd ldapadd
need_cmd ldapmodify
need_cmd ldapdelete

ldap_whoami() {
  local uri="$1"
  ldapwhoami -x -H "$uri" -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1
}

ldap_entry_exists() {
  local uri="$1"
  local uid="$2"
  ldapsearch -LLL -x -H "$uri" -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "$BASE_DN" "(uid=${uid})" dn 2>/dev/null | grep -q "^dn:"
}

entry_sn_is() {
  local uri="$1"
  local uid="$2"
  local expected="$3"
  ldapsearch -LLL -x -H "$uri" -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "$BASE_DN" "(uid=${uid})" sn 2>/dev/null | grep -q "^sn: ${expected}$"
}

wait_for_entry() {
  local uri="$1"
  local uid="$2"
  local start=$SECONDS
  local deadline=$((start + REPL_WAIT_SECONDS))
  while true; do
    if ldap_entry_exists "$uri" "$uid"; then
      return 0
    fi
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 1
  done
}

check_entry_on() {
  local message="$1"
  local uri="$2"
  local uid="$3"
  if wait_for_entry "$uri" "$uid"; then
    record_pass "$message"
  else
    record_fail "$message"
  fi
}

ldap_add_user() {
  local uri="$1"
  local uid="$2"
  local sn="$3"
  local cn="$4"
  ldapadd -x -H "$uri" -D "$ADMIN_DN" -w "$ADMIN_PW" <<LDIF >/dev/null
dn: uid=${uid},${BASE_DN}
objectClass: inetOrgPerson
cn: ${cn}
sn: ${sn}
uid: ${uid}
userPassword: Test1234!
LDIF
}

ldap_modify_sn() {
  local uri="$1"
  local uid="$2"
  local new_sn="$3"
  ldapmodify -x -H "$uri" -D "$ADMIN_DN" -w "$ADMIN_PW" <<LDIF >/dev/null
dn: uid=${uid},${BASE_DN}
changetype: modify
replace: sn
sn: ${new_sn}
LDIF
}

ldap_delete_user() {
  local uri="$1"
  local uid="$2"
  ldapdelete -x -H "$uri" -D "$ADMIN_DN" -w "$ADMIN_PW" \
    "uid=${uid},${BASE_DN}" >/dev/null 2>&1 || true
}

run_cmd() {
  local label="$1"
  local cmd="$2"
  if bash -lc "$cmd" >/dev/null 2>&1; then
    record_pass "$label"
  else
    record_fail "$label"
  fi
}

# ======================
# Test workflow
# ======================
echo "=== Keepalived VIP Failover Test ==="
echo "BASE_DN  : ${BASE_DN}"
echo "ADMIN_DN : ${ADMIN_DN}"
echo "VIP_URI  : ${VIP_URI}"
[[ -n "$MASTER_A_URI" ]] && echo "MASTER_A_URI: ${MASTER_A_URI}"
[[ -n "$MASTER_B_URI" ]] && echo "MASTER_B_URI: ${MASTER_B_URI}"
echo

# 1) VIP bind check
if ldap_whoami "$VIP_URI"; then
  record_pass "Bind works via VIP"
else
  record_fail "Bind works via VIP"
fi

echo

# 2) Write test through VIP
TEST_UID="vip-test-$(date +%Y%m%d%H%M%S)-$RANDOM"
CN="$TEST_UID"
SN="v1"

ldap_delete_user "$VIP_URI" "$TEST_UID"

if ldap_add_user "$VIP_URI" "$TEST_UID" "$SN" "$CN"; then
  record_pass "Write (add user) via VIP"
else
  record_fail "Write (add user) via VIP"
fi

sleep "$REPL_WAIT_SECONDS"

# 3) Optional replication checks on masters
if [[ -n "$MASTER_A_URI" ]]; then
  check_entry_on "Entry exists on Master A" "$MASTER_A_URI" "$TEST_UID"
else
  yellow "SKIP: MASTER_A_URI not set"
fi

if [[ -n "$MASTER_B_URI" ]]; then
  check_entry_on "Entry exists on Master B" "$MASTER_B_URI" "$TEST_UID"
else
  yellow "SKIP: MASTER_B_URI not set"
fi

# 4) Optional failover test
if [[ "$RUN_FAILOVER" -eq 1 ]]; then
  if [[ -z "$FAILOVER_CMD" || -z "$FAILBACK_CMD" ]]; then
    echo "FAILOVER_CMD and FAILBACK_CMD are required for --failover" >&2
    exit 2
  fi

  yellow "=== Triggering failover (VIP should move to backup) ==="
  run_cmd "Failover command" "$FAILOVER_CMD"
  sleep "$FAILOVER_WAIT_SECONDS"

  if ldap_modify_sn "$VIP_URI" "$TEST_UID" "v2-after-failover"; then
    record_pass "Write via VIP succeeds during failover"
  else
    record_fail "Write via VIP succeeds during failover"
  fi

  yellow "=== Restoring primary (VIP should preempt back) ==="
  run_cmd "Failback command" "$FAILBACK_CMD"
  sleep "$REPL_WAIT_SECONDS"

  if [[ -n "$MASTER_A_URI" ]]; then
    if entry_sn_is "$MASTER_A_URI" "$TEST_UID" "v2-after-failover"; then
      record_pass "Master A caught up after failover"
    else
      record_fail "Master A caught up after failover"
    fi
  fi

  if [[ -n "$MASTER_B_URI" ]]; then
    if entry_sn_is "$MASTER_B_URI" "$TEST_UID" "v2-after-failover"; then
      record_pass "Master B has updated entry after failover"
    else
      record_fail "Master B has updated entry after failover"
    fi
  fi
fi

# 5) Cleanup
if [[ "$RUN_CLEANUP" -eq 1 ]]; then
  ldap_delete_user "$VIP_URI" "$TEST_UID"
  record_pass "Cleanup: deleted test entry"
else
  yellow "Skipping cleanup; test user remains: uid=${TEST_UID},${BASE_DN}"
fi

echo
echo "=== Summary ==="
printf "%s\n" "${RESULTS[@]}" | sed 's/^/  /'
echo
echo "PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
