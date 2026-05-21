#!/usr/bin/env bash
# install-symas-openldap-replica-all-in-one.sh
#
# Full replica setup orchestrator.
# Runs all r1..r9 replica scripts in order on a fresh RHEL 9 node.
#
# Prerequisites:
#   - Symas SOLDAP repo enabled via Red Hat Satellite
#   - Master is already installed and running (install-symas-openldap-all-in-one.sh)
#   - Master has run 26-configure-bindings.sh (cn=replicator user + syncprov)
#   - Master has run 24-configure-ssl-tls.sh (CA cert available)
#   - SSH access from this replica to master (for CA cert copy)
#
# Required env:
#   MASTER_IP   - IP or hostname of master
#   ADMIN_PW    - Admin password (must match master)
#
# Optional env:
#   REPL_PW          - Replication bind password (default: replpass)
#   BASE_DN          - LDAP base DN (default: dc=eab,dc=bank,dc=local)
#   SERVER_ID        - olcServerID for this replica (default: 2)
#   SSH_KEY          - Path to SSH key to copy CA cert from master
#   SSH_USER         - SSH user on master (default: ec2-user)
#   COPY_FROM_MASTER - 1=copy CA from master (default), 0=self-signed
#   LDAPTLS_REQCERT  - TLS verify mode for tests (default: never)
#
# Usage:
#   sudo MASTER_IP=10.0.0.1 ADMIN_PW=secret bash install-symas-openldap-replica-all-in-one.sh
#
# What this does (in order):
#   r1  Install Symas OpenLDAP packages (via Satellite repo)
#   r2  Initialise cn=config with SERVER_ID + olcSyncRepl + olcUpdateRef
#   r3  Start and enable symas-openldap-servers daemon
#   r4  Fix system PATH/LDAPCONF env (symas_env.sh)
#   r5  Configure TLS (copy CA from master or self-signed)
#   r6  Fix ldapi:// SASL/EXTERNAL ACL on cn=config
#   r7  Harden (disable anon bind, require TLS, fix fs permissions)
#   r8  Tune (LimitNOFILE, SLAPD_URLS)
#   r9  Verify replica health and sync status
#   tests  Run integration test suite
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPLICA_DIR="${SCRIPT_DIR}/replica"
TEST_DIR="${REPLICA_DIR}/test"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Must be run as root"
  exit 1
fi

# Validate required vars
: "${MASTER_IP:?MASTER_IP is required (IP or hostname of master node)}"
: "${ADMIN_PW:?ADMIN_PW is required (must match master admin password)}"

export MASTER_IP
export ADMIN_PW
export REPL_PW="${REPL_PW:-replpass}"
export BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
export SERVER_ID="${SERVER_ID:-2}"
export SSH_KEY="${SSH_KEY:-}"
export SSH_USER="${SSH_USER:-ec2-user}"
export COPY_FROM_MASTER="${COPY_FROM_MASTER:-1}"
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

echo ""
echo "============================================================"
echo "  Symas OpenLDAP Replica — All-in-One Installer"
echo "============================================================"
echo "  Master IP:   ${MASTER_IP}"
echo "  Base DN:     ${BASE_DN}"
echo "  Server ID:   ${SERVER_ID}"
echo "  Repl DN:     cn=replicator,${BASE_DN}"
echo "  TLS mode:    $([ "$COPY_FROM_MASTER" = "1" ] && echo "copy CA from master" || echo "self-signed")"
echo "============================================================"
echo ""

run() {
  local script_name="$1"
  local path="${REPLICA_DIR}/${script_name}"
  if [[ ! -f "$path" ]]; then
    echo "[FATAL] Missing script: $path"
    exit 1
  fi
  echo ""
  echo "=== Running ${script_name} ==="
  bash "$path"
}

run_test() {
  local test_name="$1"
  local path="${TEST_DIR}/${test_name}"
  if [[ ! -f "$path" ]]; then
    echo "[WARN] Missing test: $path"
    return 0
  fi
  echo ""
  echo "=== Test: ${test_name} ==="
  bash "$path"
}

# ---- Installation & Configuration ----
run "r1-install-symas-openldap-replica.sh"
run "r2-configure-replica-instance.sh"
run "r3-start-replica-daemon.sh"
run "r4-fix-replica-env.sh"

# ---- Schema (must run after service starts, before TLS/hardening) ----
# Load cosine/inetorgperson if .ldif format only (no .schema files)
echo ""
echo "=== Loading base schemas (cosine, inetorgperson) ==="
SCHEMA_DIR="/opt/symas/etc/openldap/schema"
for schema in cosine inetorgperson; do
  if [[ -f "${SCHEMA_DIR}/${schema}.ldif" ]] && ! [[ -f "${SCHEMA_DIR}/${schema}.schema" ]]; then
    existing=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=schema,cn=config -s one -LLL dn 2>/dev/null | grep "$schema" || true)
    if [[ -n "$existing" ]]; then
      echo "[INFO] Schema ${schema} already loaded"
    else
      ldapadd -Y EXTERNAL -H ldapi:/// -f "${SCHEMA_DIR}/${schema}.ldif" 2>&1 | grep -v "^SASL" | head -3
    fi
  fi
done

# Custom bank schema
SCRIPT_DIR_OUTER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo ""
echo "=== Loading custom bank schema ==="
bash "${SCRIPT_DIR_OUTER}/12-Create_custom_schema.sh"
bash "${SCRIPT_DIR_OUTER}/13-Create_custom_schema_attr.sh"

# Restart after schema load
systemctl restart symas-openldap-servers 2>/dev/null || systemctl restart slapd 2>/dev/null || true
sleep 5

run "r5-configure-replica-tls.sh"
run "r6-fix-replica-ldapi-acl.sh"
run "r7-harden-replica.sh"
run "r8-tune-replica.sh"
run "r9-verify-replica.sh"

# ---- Tests ----
echo ""
echo "=== Running Tests ==="

run_test "test_replica_connections.sh"
run_test "test_replica_readonly.sh"

echo ""
echo "[INFO] Waiting 15s before sync test to allow initial replication..."
sleep 15

run_test "test_replica_sync.sh"

echo ""
echo "============================================================"
echo "  Replica installation complete"
echo "  Master:   ${MASTER_IP}"
echo "  Replica:  $(hostname -f 2>/dev/null || hostname)"
echo "  Base DN:  ${BASE_DN}"
echo "============================================================"
echo ""
echo "Connect from CLI:"
echo "  LDAPTLS_REQCERT=never ldapsearch -x -ZZ \\"
echo "    -H ldap://$(hostname -I | awk '{print $1}') \\"
echo "    -D 'cn=admin,${BASE_DN}' -w '\${ADMIN_PW}' \\"
echo "    -b '${BASE_DN}' -s one '(objectClass=*)' dn"
echo ""
echo "  To re-run verification:"
echo "  sudo MASTER_IP=${MASTER_IP} ADMIN_PW=\$ADMIN_PW bash replica/r9-verify-replica.sh"
