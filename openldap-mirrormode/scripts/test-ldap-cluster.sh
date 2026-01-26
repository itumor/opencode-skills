#!/usr/bin/env bash
set -euo pipefail

# =========================
# User-configurable values
# =========================
BASE_DN="${BASE_DN:-dc=cae,dc=local}"
ADMIN_DN="${ADMIN_DN:-cn=admin,${BASE_DN}}"
ADMIN_PW="${ADMIN_PW:-admin}"

# If you created a dedicated replication user, keep it here (not required for tests)
REPL_DN="${REPL_DN:-cn=replicator,${BASE_DN}}"
REPL_PW="${REPL_PW:-replpass}"

# Container names (must match your docker-compose)
MASTER_A="${MASTER_A:-ldap-master-a}"
MASTER_B="${MASTER_B:-ldap-master-b}"
REPLICA_A="${REPLICA_A:-ldap-replica-a}"
REPLICA_B="${REPLICA_B:-ldap-replica-b}"
LB_WRITE="${LB_WRITE:-ldap-write}"
LB_READ="${LB_READ:-ldap-read}"

# VIP ports INSIDE docker network (from the earlier compose example)
WRITE_LDAP_URI="${WRITE_LDAP_URI:-ldap://${LB_WRITE}:1389}"
WRITE_LDAPS_URI="${WRITE_LDAPS_URI:-ldaps://${LB_WRITE}:1636}"
READ_LDAP_URI="${READ_LDAP_URI:-ldap://${LB_READ}:2389}"
READ_LDAPS_URI="${READ_LDAPS_URI:-ldaps://${LB_READ}:2636}"

# Node URIs (inside docker network)
MASTER_A_LDAP_URI="${MASTER_A_LDAP_URI:-ldap://${MASTER_A}:389}"
MASTER_B_LDAP_URI="${MASTER_B_LDAP_URI:-ldap://${MASTER_B}:389}"
REPLICA_A_LDAP_URI="${REPLICA_A_LDAP_URI:-ldap://${REPLICA_A}:389}"
REPLICA_B_LDAP_URI="${REPLICA_B_LDAP_URI:-ldap://${REPLICA_B}:389}"

# CA cert path inside osixia/openldap containers
LDAPTLS_CACERT_PATH="${LDAPTLS_CACERT_PATH:-/container/service/slapd/assets/certs/ca.crt}"

# Which container to run ldap* client commands from (must have ldapsearch/ldapadd/ldapmodify)
# Use a replica by default so failover tests can stop a master safely.
EXEC_IN="${EXEC_IN:-$REPLICA_A}"

# How long to wait for replication after writes
REPL_WAIT_SECONDS="${REPL_WAIT_SECONDS:-15}"

# How long to wait after stopping a master before testing write failover
FAILOVER_WAIT_SECONDS="${FAILOVER_WAIT_SECONDS:-8}"

# Optional destructive tests
RUN_FAILOVER=0
RUN_CLEANUP=1

usage() {
  cat <<EOF
Usage: $0 [--failover] [--no-cleanup]

Environment overrides:
  BASE_DN, ADMIN_DN, ADMIN_PW, EXEC_IN,
  MASTER_A, MASTER_B, REPLICA_A, REPLICA_B, LB_WRITE, LB_READ,
  WRITE_LDAP_URI, READ_LDAP_URI, WRITE_LDAPS_URI, READ_LDAPS_URI,
  MASTER_A_LDAP_URI, MASTER_B_LDAP_URI, REPLICA_A_LDAP_URI, REPLICA_B_LDAP_URI,
  LDAPTLS_CACERT_PATH, REPL_WAIT_SECONDS, FAILOVER_WAIT_SECONDS

Examples:
  ./scripts/test-ldap-cluster.sh
  BASE_DN="dc=example,dc=org" ADMIN_PW="admin" ./scripts/test-ldap-cluster.sh
  ./scripts/test-ldap-cluster.sh --failover
EOF
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
# Command runners (host/container)
# ==============================
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }
}

need_cmd docker

docker_exec_ldap() {
  # Run ldap* tools inside EXEC_IN container with CA configured for LDAPS verification.
  docker exec -e "LDAPTLS_CACERT=${LDAPTLS_CACERT_PATH}" -i "${EXEC_IN}" "$@"
}

check_container_running() {
  local c="$1"
  docker ps --format '{{.Names}}' | grep -qx "$c"
}

tcp_check_from_container() {
  # Uses bash TCP connect from inside container (no netcat dependency)
  local hostport="$1" # e.g. ldap-write:1389
  docker exec -i "${EXEC_IN}" bash -lc "echo > /dev/tcp/${hostport/:/\/}" >/dev/null 2>&1
}

ldap_whoami() {
  local uri="$1"
  docker_exec_ldap ldapwhoami -x -H "$uri" -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1
}

ldap_get_contextcsn() {
  local uri="$1"
  docker_exec_ldap ldapsearch -LLL -x -H "$uri" -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -s base -b "$BASE_DN" "(objectClass=*)" contextCSN + 2>/dev/null \
    | awk -F': ' '/^contextCSN:/ {print $2; exit}'
}

ldap_entry_exists() {
  local uri="$1"
  local uid="$2"
  docker_exec_ldap ldapsearch -LLL -x -H "$uri" -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "$BASE_DN" "(uid=${uid})" dn 2>/dev/null | grep -q "^dn:"
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
  docker_exec_ldap ldapadd -x -H "$uri" -D "$ADMIN_DN" -w "$ADMIN_PW" <<EOF >/dev/null
dn: uid=${uid},${BASE_DN}
objectClass: inetOrgPerson
cn: ${cn}
sn: ${sn}
uid: ${uid}
userPassword: Test1234!
EOF
}

ldap_modify_sn() {
  local uri="$1"
  local uid="$2"
  local new_sn="$3"
  docker_exec_ldap ldapmodify -x -H "$uri" -D "$ADMIN_DN" -w "$ADMIN_PW" <<EOF >/dev/null
dn: uid=${uid},${BASE_DN}
changetype: modify
replace: sn
sn: ${new_sn}
EOF
}

ldap_delete_user() {
  local uri="$1"
  local uid="$2"
  docker_exec_ldap ldapdelete -x -H "$uri" -D "$ADMIN_DN" -w "$ADMIN_PW" \
    "uid=${uid},${BASE_DN}" >/dev/null 2>&1 || true
}

# ======================
# Test workflow
# ======================
echo "=== OpenLDAP Cluster Test ==="
echo "BASE_DN   : ${BASE_DN}"
echo "ADMIN_DN  : ${ADMIN_DN}"
echo "EXEC_IN   : ${EXEC_IN}"
echo

# 1) Containers running
for c in "$MASTER_A" "$MASTER_B" "$REPLICA_A" "$REPLICA_B" "$LB_WRITE" "$LB_READ"; do
  if check_container_running "$c"; then
    record_pass "Container running: $c"
  else
    record_fail "Container running: $c"
  fi
done

echo

# 2) TCP reachability (inside docker network)
declare -a TCP_TARGETS=(
  "${LB_WRITE}:1389"
  "${LB_WRITE}:1636"
  "${LB_READ}:2389"
  "${LB_READ}:2636"
  "${MASTER_A}:389"
  "${MASTER_B}:389"
  "${REPLICA_A}:389"
  "${REPLICA_B}:389"
)

for hp in "${TCP_TARGETS[@]}"; do
  if tcp_check_from_container "$hp"; then
    record_pass "TCP reachable: $hp"
  else
    record_fail "TCP reachable: $hp"
  fi
done

echo

# 3) Bind/auth checks (LDAP + LDAPS) via VIPs and nodes
declare -a URIS=(
  "$WRITE_LDAP_URI"
  "$READ_LDAP_URI"
  "$WRITE_LDAPS_URI"
  "$READ_LDAPS_URI"
  "$MASTER_A_LDAP_URI"
  "$MASTER_B_LDAP_URI"
  "$REPLICA_A_LDAP_URI"
  "$REPLICA_B_LDAP_URI"
)

for uri in "${URIS[@]}"; do
  if ldap_whoami "$uri"; then
    record_pass "Bind works: $uri"
  else
    record_fail "Bind works: $uri"
  fi
done

echo

# 4) Show contextCSN snapshot (debug signal)
echo "=== contextCSN snapshot (debug) ==="
printf "  WRITE VIP : %s\n" "$(ldap_get_contextcsn "$WRITE_LDAP_URI" | head -n1 || true)"
printf "  READ  VIP : %s\n" "$(ldap_get_contextcsn "$READ_LDAP_URI"  | head -n1 || true)"
printf "  Master A  : %s\n" "$(ldap_get_contextcsn "$MASTER_A_LDAP_URI" | head -n1 || true)"
printf "  Master B  : %s\n" "$(ldap_get_contextcsn "$MASTER_B_LDAP_URI" | head -n1 || true)"
printf "  Replica A : %s\n" "$(ldap_get_contextcsn "$REPLICA_A_LDAP_URI" | head -n1 || true)"
printf "  Replica B : %s\n" "$(ldap_get_contextcsn "$REPLICA_B_LDAP_URI" | head -n1 || true)"
echo

# 5) Write test through WRITE VIP + replication presence tests
TEST_UID="cluster-test-$(date +%Y%m%d%H%M%S)-$RANDOM"
CN="$TEST_UID"
SN="v1"

# Ensure clean
ldap_delete_user "$WRITE_LDAP_URI" "$TEST_UID"

if ldap_add_user "$WRITE_LDAP_URI" "$TEST_UID" "$SN" "$CN"; then
  record_pass "Write (add user) via WRITE VIP"
else
  record_fail "Write (add user) via WRITE VIP"
fi

sleep "$REPL_WAIT_SECONDS"

# Existence checks across nodes (replication signal)
check_entry_on "Entry exists on Master A" "$MASTER_A_LDAP_URI" "$TEST_UID"
check_entry_on "Entry exists on Master B (master-master replication)" "$MASTER_B_LDAP_URI" "$TEST_UID"
check_entry_on "Entry exists on Replica A (replication)" "$REPLICA_A_LDAP_URI" "$TEST_UID"
check_entry_on "Entry exists on Replica B (replication)" "$REPLICA_B_LDAP_URI" "$TEST_UID"

# 6) Read-only enforcement via READ VIP (expected failure)
# If replicas are configured olcReadOnly=TRUE, a modify through READ VIP should fail ("unwilling to perform").
# We treat FAILURE of ldapmodify here as PASS (read-only enforced).
if ldap_modify_sn "$READ_LDAP_URI" "$TEST_UID" "should-not-work" 2>/dev/null; then
  record_fail "READ VIP rejects writes (read-only) [unexpectedly allowed]"
else
  record_pass "READ VIP rejects writes (read-only enforced)"
fi

# 7) Optional failover test: stop master-a, write via WRITE VIP should still succeed (master-b)
if [[ "$RUN_FAILOVER" -eq 1 ]]; then
  yellow "=== Running FAILOVER test (will stop/start ${MASTER_A}) ==="

  if docker stop "$MASTER_A" >/dev/null; then
    record_pass "Stopped Master A for failover test"
  else
    record_fail "Stopped Master A for failover test"
  fi

  sleep "$FAILOVER_WAIT_SECONDS"

  # Modify through WRITE VIP
  if ldap_modify_sn "$WRITE_LDAP_URI" "$TEST_UID" "v2-after-failover"; then
    record_pass "Write via WRITE VIP succeeds during Master A down (failover ok)"
  else
    record_fail "Write via WRITE VIP succeeds during Master A down (failover ok)"
  fi

  if docker start "$MASTER_A" >/dev/null; then
    record_pass "Started Master A after failover test"
  else
    record_fail "Started Master A after failover test"
  fi

  sleep "$REPL_WAIT_SECONDS"

  # Ensure Master A eventually sees the changed sn
  if docker_exec_ldap ldapsearch -LLL -x -H "$MASTER_A_LDAP_URI" -D "$ADMIN_DN" -w "$ADMIN_PW" \
      -b "$BASE_DN" "(uid=${TEST_UID})" sn 2>/dev/null | grep -q "^sn: v2-after-failover$"; then
    record_pass "Master A caught up after failover (replication back)"
  else
    record_fail "Master A caught up after failover (replication back)"
  fi
fi

# 8) Cleanup
if [[ "$RUN_CLEANUP" -eq 1 ]]; then
  ldap_delete_user "$WRITE_LDAP_URI" "$TEST_UID"
  record_pass "Cleanup: deleted test entry"
else
  yellow "Skipping cleanup; test user remains: uid=${TEST_UID},${BASE_DN}"
fi

echo
echo "=== Summary ==="
printf "%s\n" "${RESULTS[@]}" | sed 's/^/  /'
echo
echo "PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}"

# Fail the script if anything failed
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
