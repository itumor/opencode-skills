#!/usr/bin/env bash
# deploy-fix-pipeline.sh
#
# Orchestrator to deploy and run the post-log-analysis fix scripts
# on both master and replica EC2 instances via SSH.
#
# This script runs from your local machine. It:
#   1. SCPs the fix scripts to master and replica
#   2. Runs fix-master-checksum.sh on master
#   3. Runs fix-replica-syncrepl-tls.sh on replica
#   4. Runs verify-post-fix.sh on both nodes
#   5. Reports results
#
# Prerequisites:
#   - SSH key at SSH_KEY_PATH
#   - EC2 instances with ec2-user access
#   - Master has ADMIN_PW set
#
# Required env:
#   MASTER_IP     - master public IP or hostname
#   REPLICA_IP    - replica public IP or hostname
#   ADMIN_PW      - admin password (must match master)
#
# Optional:
#   SSH_KEY_PATH  - path to SSH private key (default: terraform key)
#   SSH_USER      - SSH username (default: ec2-user)
#   REPL_PW       - replicator password (default: replpass)
#
# Usage:
#   MASTER_IP=54.245.18.142 REPLICA_IP=35.165.218.77 ADMIN_PW=TheN1le1 bash deploy-fix-pipeline.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- Config ----
MASTER_IP="${MASTER_IP:?MASTER_IP is required (master public IP)}"
REPLICA_IP="${REPLICA_IP:?REPLICA_IP is required (replica public IP)}"
ADMIN_PW="${ADMIN_PW:?ADMIN_PW is required (admin password)}"
REPL_PW="${REPL_PW:-replpass}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${REPO_ROOT}/terraform/openldap-master-replica/.local-ssh/openldap_master_replica}"
SSH_USER="${SSH_USER:-ec2-user}"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"

if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "[FATAL] SSH key not found: $SSH_KEY_PATH"
  exit 1
fi

SSH_OPTS="-i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -o ConnectTimeout=10"
REMOTE_DIR="/tmp/script/fix"

log()   { echo "[INFO] $*"; }
ok()    { echo "[ OK ] $*"; }
bad()   { echo "[FAIL] $*" >&2; }

echo ""
echo "============================================================"
echo "  Post-Log-Analysis Fix Pipeline"
echo "  Master:     ${MASTER_IP}"
echo "  Replica:    ${REPLICA_IP}"
echo "  Base DN:    ${BASE_DN}"
echo "============================================================"
echo ""

# ---- Pre-flight: verify SSH connectivity ----
echo "--- Pre-flight: SSH connectivity ---"

if ssh $SSH_OPTS ${SSH_USER}@${MASTER_IP} "hostname" >/dev/null 2>&1; then
  ok "Master SSH reachable"
else
  bad "Master SSH NOT reachable at ${MASTER_IP}"
  exit 1
fi

if ssh $SSH_OPTS ${SSH_USER}@${REPLICA_IP} "hostname" >/dev/null 2>&1; then
  ok "Replica SSH reachable"
else
  bad "Replica SSH NOT reachable at ${REPLICA_IP}"
  exit 1
fi

# ---- Stage scripts on both nodes ----
echo ""
echo "--- Staging scripts ---"

for remote_ip in "$MASTER_IP" "$REPLICA_IP"; do
  log "Staging on ${remote_ip}..."
  
  ssh $SSH_OPTS ${SSH_USER}@${remote_ip} "sudo mkdir -p ${REMOTE_DIR} && sudo chown -R ${SSH_USER}:${SSH_USER} /tmp/script/" 2>/dev/null || true
  
  scp $SSH_OPTS \
    "${SCRIPT_DIR}/fix-master-checksum.sh" \
    "${SCRIPT_DIR}/fix-replica-syncrepl-tls.sh" \
    "${SCRIPT_DIR}/verify-post-fix.sh" \
    "${SCRIPT_DIR}/replica/r9-verify-replica.sh" \
    "${SSH_USER}@${remote_ip}:${REMOTE_DIR}/"
done
ok "Scripts staged on both nodes"

# ---- Step 1: Fix master checksums ----
echo ""
echo "============================================================"
echo "  Step 1: Fix Master Checksums"
echo "============================================================"

ssh $SSH_OPTS ${SSH_USER}@${MASTER_IP} \
  "sudo bash ${REMOTE_DIR}/fix-master-checksum.sh" || {
    bad "Master checksum fix FAILED"
  }

# ---- Step 2: Fix replica syncrepl TLS ----
echo ""
echo "============================================================"
echo "  Step 2: Fix Replica Syncrepl TLS"
echo "============================================================"

ssh $SSH_OPTS ${SSH_USER}@${REPLICA_IP} \
  "sudo bash ${REMOTE_DIR}/fix-replica-syncrepl-tls.sh" || {
    bad "Replica syncrepl fix FAILED"
  }

# Wait for replication to catch up after restart
log "Waiting 15s for replication to stabilise..."
sleep 15

# ---- Step 3: Verify master ----
echo ""
echo "============================================================"
echo "  Step 3: Verify Master"
echo "============================================================"

ssh $SSH_OPTS ${SSH_USER}@${MASTER_IP} \
  "sudo MASTER_IP=${MASTER_IP} ADMIN_PW='${ADMIN_PW}' REPL_PW='${REPL_PW}' BASE_DN=${BASE_DN} bash ${REMOTE_DIR}/verify-post-fix.sh" || {
    bad "Master verification FAILED (see output above)"
  }

# ---- Step 4: Verify replica ----
echo ""
echo "============================================================"
echo "  Step 4: Verify Replica"
echo "============================================================"

ssh $SSH_OPTS ${SSH_USER}@${REPLICA_IP} \
  "sudo MASTER_IP=${MASTER_IP} ADMIN_PW='${ADMIN_PW}' REPL_PW='${REPL_PW}' BASE_DN=${BASE_DN} bash ${REMOTE_DIR}/verify-post-fix.sh" || {
    bad "Replica verification FAILED (see output above)"
  }

# ---- Step 5: Run replica verification test ----
echo ""
echo "============================================================"
echo "  Step 5: Replica r9 Verification"
echo "============================================================"

ssh $SSH_OPTS ${SSH_USER}@${REPLICA_IP} \
  "sudo MASTER_IP=${MASTER_IP} ADMIN_PW='${ADMIN_PW}' REPL_PW='${REPL_PW}' LDAPTLS_REQCERT=never bash ${REMOTE_DIR}/r9-verify-replica.sh" || {
    bad "r9-verify-replica FAILED (see output above)"
  }

# ---- Step 6: Create test entry on master, verify syncs to replica ----
echo ""
echo "============================================================"
echo "  Step 6: End-to-End Replication Test"
echo "============================================================"

TEST_UID="fix-verify-$(date +%Y%m%d-%H%M%S)"
TEST_DN="uid=${TEST_UID},ou=Users,${BASE_DN}"

# Add on master
log "Adding test entry '${TEST_DN}' on master..."
ADD_OUTPUT=$(ssh $SSH_OPTS ${SSH_USER}@${MASTER_IP} \
  "sudo bash -c 'source /etc/profile.d/symas_env.sh 2>/dev/null || true
   LDAPTLS_REQCERT=never ldapadd -x -ZZ -H ldap://localhost \
     -D \"cn=admin,${BASE_DN}\" -w \"${ADMIN_PW}\" <<EOF
dn: ${TEST_DN}
objectClass: inetOrgPerson
objectClass: organizationalPerson
objectClass: person
uid: ${TEST_UID}
cn: Fix Verify Test
sn: FixTest
EOF' 2>&1")

if echo "$ADD_OUTPUT" | grep -q "adding new entry"; then
  ok "Test entry created on master"
else
  bad "Failed to create test entry on master: $(echo "$ADD_OUTPUT" | head -3)"
fi

# Wait for replication
log "Waiting 10s for replication..."
sleep 10

# Check on replica
log "Checking test entry on replica..."
SEARCH_OUTPUT=$(ssh $SSH_OPTS ${SSH_USER}@${REPLICA_IP} \
  "sudo bash -c 'source /etc/profile.d/symas_env.sh 2>/dev/null || true
   LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
     -D \"cn=admin,${BASE_DN}\" -w \"${ADMIN_PW}\" \
     -b \"${TEST_DN}\" -s base -LLL dn 2>&1'")

if echo "$SEARCH_OUTPUT" | grep -q "^dn: ${TEST_DN}"; then
  ok "Test entry REPLICATED successfully"
else
  bad "Test entry NOT found on replica — replication still broken"
  echo "$SEARCH_OUTPUT" | head -3
fi

# Cleanup test entry
log "Cleaning up test entry..."
ssh $SSH_OPTS ${SSH_USER}@${MASTER_IP} \
  "sudo bash -c 'source /etc/profile.d/symas_env.sh 2>/dev/null || true
   LDAPTLS_REQCERT=never ldapdelete -x -ZZ -H ldap://localhost \
     -D \"cn=admin,${BASE_DN}\" -w \"${ADMIN_PW}\" \"${TEST_DN}\" 2>&1'" >/dev/null 2>&1 || true

# ---- Final Summary ----
echo ""
echo "============================================================"
echo "  Fix Pipeline Complete"
echo "============================================================"
echo "  Master:   ${MASTER_IP}"
echo "  Replica:  ${REPLICA_IP}"
echo ""
echo "  To re-verify manually:"
echo "    ssh ${SSH_USER}@${MASTER_IP} sudo bash ${REMOTE_DIR}/verify-post-fix.sh"
echo "    ssh ${SSH_USER}@${REPLICA_IP} sudo MASTER_IP=${MASTER_IP} ADMIN_PW='...' bash ${REMOTE_DIR}/verify-post-fix.sh"
echo ""
echo "  To check logs on either node:"
echo "    ssh ${SSH_USER}@<ip> sudo journalctl -u symas-openldap-servers --no-pager -n 50"
echo "============================================================"

# Play audible confirmation
printf '\a' 2>/dev/null || true
afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || true
