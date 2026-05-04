#!/usr/bin/env bash
set -euo pipefail

# Verifies OpenLDAP replication across live/dr masters and replicas.
#
# What it checks:
# - SSH connectivity to all nodes
# - Per-node serverID and replication config (olcSyncRepl/olcReadOnly)
# - contextCSN convergence between masters
# - A write on each master appears on all nodes
# - Cleanup (delete test entries) replicates everywhere
#
# Usage:
#   bash terraform/openldap/ldif-public-ips/verify_replication.sh
#   LIVE_MASTER_IP=... DR_MASTER_IP=... bash terraform/openldap/ldif-public-ips/verify_replication.sh
#
# Requirements:
# - Key: terraform/openldap/.local-ssh/openldap_mm
# - User: ec2-user

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

if [[ -f terraform/key.aws.text ]]; then
  # Only eval AWS exports (the file may contain non-shell notes).
  eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"
fi

KEY="${KEY_PATH:-terraform/openldap/.local-ssh/openldap_mm}"
USER="${SSH_USER:-ec2-user}"
SSH_BASE=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$KEY")

if command -v terraform >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  if [[ -z "${LIVE_MASTER_IP:-}" ]]; then
    LIVE_MASTER_IP="$(terraform -chdir=terraform/openldap output -json instance_public_ips 2>/dev/null | jq -r '."live-master-1" // empty' 2>/dev/null)"
  fi
  if [[ -z "${DR_MASTER_IP:-}" ]]; then
    DR_MASTER_IP="$(terraform -chdir=terraform/openldap output -json instance_public_ips 2>/dev/null | jq -r '."dr-master-1" // empty' 2>/dev/null)"
  fi
  if [[ -z "${LIVE_REPLICA_1_IP:-}" ]]; then
    LIVE_REPLICA_1_IP="$(terraform -chdir=terraform/openldap output -json instance_public_ips 2>/dev/null | jq -r '."live-replica-1" // empty' 2>/dev/null)"
  fi
  if [[ -z "${LIVE_REPLICA_2_IP:-}" ]]; then
    LIVE_REPLICA_2_IP="$(terraform -chdir=terraform/openldap output -json instance_public_ips 2>/dev/null | jq -r '."live-replica-2" // empty' 2>/dev/null)"
  fi
  if [[ -z "${DR_REPLICA_1_IP:-}" ]]; then
    DR_REPLICA_1_IP="$(terraform -chdir=terraform/openldap output -json instance_public_ips 2>/dev/null | jq -r '."dr-replica-1" // empty' 2>/dev/null)"
  fi
  if [[ -z "${DR_REPLICA_2_IP:-}" ]]; then
    DR_REPLICA_2_IP="$(terraform -chdir=terraform/openldap output -json instance_public_ips 2>/dev/null | jq -r '."dr-replica-2" // empty' 2>/dev/null)"
  fi
fi

LIVE_MASTER_IP="${LIVE_MASTER_IP:-44.200.226.106}"
DR_MASTER_IP="${DR_MASTER_IP:-3.231.153.142}"
LIVE_REPLICA_1_IP="${LIVE_REPLICA_1_IP:-54.209.91.112}"
LIVE_REPLICA_2_IP="${LIVE_REPLICA_2_IP:-100.31.188.126}"
DR_REPLICA_1_IP="${DR_REPLICA_1_IP:-52.90.105.119}"
DR_REPLICA_2_IP="${DR_REPLICA_2_IP:-100.53.225.127}"

ADMIN_DN="${ADMIN_DN:-cn=admin,dc=cae,dc=local}"
ADMIN_PW="${ADMIN_PW:-admin}"
BASE_DN="${BASE_DN:-dc=cae,dc=local}"

LIVE_MASTER_NAME="live-master-1"
DR_MASTER_NAME="dr-master-1"

declare -a NODES=(
  "${LIVE_MASTER_NAME}:${LIVE_MASTER_IP}"
  "${DR_MASTER_NAME}:${DR_MASTER_IP}"
  "live-replica-1:${LIVE_REPLICA_1_IP}"
  "live-replica-2:${LIVE_REPLICA_2_IP}"
  "dr-replica-1:${DR_REPLICA_1_IP}"
  "dr-replica-2:${DR_REPLICA_2_IP}"
)

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

ssh_run() {
  local ip="$1"
  shift
  "${SSH_BASE[@]}" "${USER}@${ip}" "$@"
}

ldap_add_ldif() {
  local ip="$1"
  ssh_run "$ip" "sudo /opt/symas/bin/ldapadd -x -H ldap://localhost:389 -D '${ADMIN_DN}' -w '${ADMIN_PW}' -f /tmp/codex_repl_test.ldif"
}

ldap_delete_dn() {
  local ip="$1"
  local dn="$2"
  # Ignore if already gone.
  ssh_run "$ip" "sudo /opt/symas/bin/ldapdelete -x -H ldap://localhost:389 -D '${ADMIN_DN}' -w '${ADMIN_PW}' '${dn}' >/dev/null 2>&1 || true"
}

ldap_search_dn() {
  local ip="$1"
  local filter="$2"
  ssh_run "$ip" "sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 -D '${ADMIN_DN}' -w '${ADMIN_PW}' -b '${BASE_DN}' '${filter}' dn cn description 2>/dev/null || true"
}

wait_for_all_nodes() {
  local filter="$1"
  local expect_present="$2" # "yes" or "no"
  local deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    local ok=1
    local name ip out
    for entry in "${NODES[@]}"; do
      name="${entry%%:*}"
      ip="${entry#*:}"
      out="$(ldap_search_dn "$ip" "$filter")"
      if [[ "$expect_present" == "yes" ]]; then
        if ! grep -q '^dn: ' <<<"$out"; then ok=0; fi
      else
        if grep -q '^dn: ' <<<"$out"; then ok=0; fi
      fi
    done
    if (( ok == 1 )); then
      return 0
    fi
    sleep 2
  done
  return 1
}

cleanup() {
  local dn
  for dn in "${TEST_DN_1:-}" "${TEST_DN_2:-}"; do
    [[ -z "$dn" ]] && continue
    ldap_delete_dn "$LIVE_MASTER_IP" "$dn"
    ldap_delete_dn "$DR_MASTER_IP" "$dn"
  done
}
trap cleanup EXIT

log "Checking SSH connectivity..."
for entry in "${NODES[@]}"; do
  name="${entry%%:*}"
  ip="${entry#*:}"
  ssh_run "$ip" "echo ok: ${name}:\$(hostname)" >/dev/null
done
log "SSH connectivity ok (6/6)."

log "Dumping replication config and CSNs (for visibility)..."
for entry in "${NODES[@]}"; do
  name="${entry%%:*}"
  ip="${entry#*:}"
  log "Node ${name} (${ip})"
  ssh_run "$ip" "set -e;
    sudo /opt/symas/bin/ldapsearch -LLL -Y EXTERNAL -H 'ldapi://%2Fvar%2Fsymas%2Frun%2Fldapi' -b cn=config '(objectClass=olcGlobal)' olcServerID 2>/dev/null || true;
    sudo /opt/symas/bin/ldapsearch -LLL -Y EXTERNAL -H 'ldapi://%2Fvar%2Fsymas%2Frun%2Fldapi' -b 'olcDatabase={1}mdb,cn=config' -s base olcSyncRepl olcMirrorMode olcMultiProvider olcReadOnly olcUpdateRef 2>/dev/null || true;
    sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 -D '${ADMIN_DN}' -w '${ADMIN_PW}' -b '${BASE_DN}' -s base contextCSN 2>/dev/null || true" | sed 's/^/  /'
done

log "Validating masters have cross-site syncrepl enabled..."
live_cfg="$(ssh_run "$LIVE_MASTER_IP" "sudo /opt/symas/bin/ldapsearch -LLL -Y EXTERNAL -H 'ldapi://%2Fvar%2Fsymas%2Frun%2Fldapi' -b 'olcDatabase={1}mdb,cn=config' -s base olcSyncRepl olcMirrorMode olcMultiProvider 2>/dev/null || true")"
dr_cfg="$(ssh_run "$DR_MASTER_IP" "sudo /opt/symas/bin/ldapsearch -LLL -Y EXTERNAL -H 'ldapi://%2Fvar%2Fsymas%2Frun%2Fldapi' -b 'olcDatabase={1}mdb,cn=config' -s base olcSyncRepl olcMirrorMode olcMultiProvider 2>/dev/null || true")"
# ldapsearch output may wrap long values; normalize whitespace to make matching stable.
live_cfg_norm="$(tr '\n' ' ' <<<"$live_cfg" | tr -s ' ')"
dr_cfg_norm="$(tr '\n' ' ' <<<"$dr_cfg" | tr -s ' ')"
grep -qi 'provider=ldap://10\.20\.0\.10:389' <<<"$live_cfg_norm" || die "${LIVE_MASTER_NAME} missing provider=ldap://10.20.0.10:389 in olcSyncRepl"
grep -qi 'provider=ldap://10\.10\.0\.10:389' <<<"$dr_cfg_norm" || die "${DR_MASTER_NAME} missing provider=ldap://10.10.0.10:389 in olcSyncRepl"

log "Validating masters CSN convergence..."
live_csn="$(ssh_run "$LIVE_MASTER_IP" "sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 -D '${ADMIN_DN}' -w '${ADMIN_PW}' -b '${BASE_DN}' -s base contextCSN 2>/dev/null || true" | awk -F': ' '/^contextCSN:/{print $2; exit}')"
dr_csn="$(ssh_run "$DR_MASTER_IP" "sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 -D '${ADMIN_DN}' -w '${ADMIN_PW}' -b '${BASE_DN}' -s base contextCSN 2>/dev/null || true" | awk -F': ' '/^contextCSN:/{print $2; exit}')"
[[ -n "$live_csn" && -n "$dr_csn" ]] || die "Unable to read contextCSN from one or both masters"
if [[ "$live_csn" != "$dr_csn" ]]; then
  log "Masters not converged yet: live=${live_csn} dr=${dr_csn} (waiting up to 90s)"
  deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    live_csn="$(ssh_run "$LIVE_MASTER_IP" "sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 -D '${ADMIN_DN}' -w '${ADMIN_PW}' -b '${BASE_DN}' -s base contextCSN 2>/dev/null || true" | awk -F': ' '/^contextCSN:/{print $2; exit}')"
    dr_csn="$(ssh_run "$DR_MASTER_IP" "sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 -D '${ADMIN_DN}' -w '${ADMIN_PW}' -b '${BASE_DN}' -s base contextCSN 2>/dev/null || true" | awk -F': ' '/^contextCSN:/{print $2; exit}')"
    [[ "$live_csn" == "$dr_csn" ]] && break
    sleep 2
  done
fi
[[ "$live_csn" == "$dr_csn" ]] || die "Masters contextCSN still differ: live=${live_csn} dr=${dr_csn}"
log "Masters contextCSN match: ${live_csn}"

TS="$(date -u +%Y%m%d%H%M%S)"
TEST_DN_1="cn=codex-repl-test-${TS},${BASE_DN}"
TEST_DN_2="cn=codex-repl-test2-${TS},${BASE_DN}"

log "Test 1: write on ${LIVE_MASTER_NAME}, verify everywhere..."
printf "dn: %s\nobjectClass: organizationalRole\ncn: codex-repl-test-%s\ndescription: replication-test-%s\n" \
  "$TEST_DN_1" "$TS" "$TS" > /tmp/codex_repl_test.ldif
ssh_run "$LIVE_MASTER_IP" "cat > /tmp/codex_repl_test.ldif" < /tmp/codex_repl_test.ldif
ldap_add_ldif "$LIVE_MASTER_IP"

filter1="(cn=codex-repl-test-${TS})"
wait_for_all_nodes "$filter1" "yes" || die "Test 1 did not replicate to all nodes within timeout"
log "Test 1 replicated to all nodes."

log "Test 2: write on ${DR_MASTER_NAME}, verify everywhere..."
printf "dn: %s\nobjectClass: organizationalRole\ncn: codex-repl-test2-%s\ndescription: replication-test2-%s\n" \
  "$TEST_DN_2" "$TS" "$TS" > /tmp/codex_repl_test.ldif
ssh_run "$DR_MASTER_IP" "cat > /tmp/codex_repl_test.ldif" < /tmp/codex_repl_test.ldif
ldap_add_ldif "$DR_MASTER_IP"

filter2="(cn=codex-repl-test2-${TS})"
wait_for_all_nodes "$filter2" "yes" || die "Test 2 did not replicate to all nodes within timeout"
log "Test 2 replicated to all nodes."

log "Cleanup: delete both test entries and verify removal everywhere..."
ldap_delete_dn "$LIVE_MASTER_IP" "$TEST_DN_1"
ldap_delete_dn "$LIVE_MASTER_IP" "$TEST_DN_2"
ldap_delete_dn "$DR_MASTER_IP" "$TEST_DN_1"
ldap_delete_dn "$DR_MASTER_IP" "$TEST_DN_2"

wait_for_all_nodes "(|(cn=codex-repl-test-${TS})(cn=codex-repl-test2-${TS}))" "no" || die "Deletions did not replicate to all nodes within timeout"
log "Cleanup replicated to all nodes."

log "PASS: replication verified across live/dr masters and all replicas."
