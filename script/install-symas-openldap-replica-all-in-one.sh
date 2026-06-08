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
#
# Required env:
#   MASTER_IP   - IP or hostname of master
#   ADMIN_PW    - Admin password (must match master)
#
# Optional env:
#   REPL_PW          - Replication bind password (default: replpass)
#   BASE_DN          - LDAP base DN (default: dc=eab,dc=bank,dc=local)
#   SERVER_ID        - olcServerID for this replica (default: 2)
#   COPY_FROM_MASTER - 0=self-signed (default), 1=manual staging of master CA
#   STAGED_CA_CERT   - path to pre-staged CA cert (if COPY_FROM_MASTER=1)
#   STAGED_CA_KEY    - path to pre-staged CA key  (if COPY_FROM_MASTER=1)
#   LDAPTLS_REQCERT  - TLS verify mode for tests (default: never)
#   TLS_MODE         - yes (default) or no — when 'no', skips TLS + TLS hardening
#
# Note: No SSH/SCP from replica to master. TLS is self-signed by default.
#       To use master's CA, manually copy ca.crt+ca.key from master and set
#       STAGED_CA_CERT/STAGED_CA_KEY.
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
export COPY_FROM_MASTER="${COPY_FROM_MASTER:-0}"
export STAGED_CA_CERT="${STAGED_CA_CERT:-}"
export STAGED_CA_KEY="${STAGED_CA_KEY:-}"
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"
export TLS_MODE="${TLS_MODE:-yes}"

echo ""
echo "============================================================"
echo "  Symas OpenLDAP Replica — All-in-One Installer"
echo "============================================================"
echo "  Master IP:   ${MASTER_IP}"
echo "  Base DN:     ${BASE_DN}"
echo "  Server ID:   ${SERVER_ID}"
echo "  Repl DN:     cn=replicator,${BASE_DN}"
echo "  TLS mode:    $([ "$TLS_MODE" = "no" ] && echo "disabled (no-TLS)" || echo "$([ "$COPY_FROM_MASTER" = "1" ] && echo "copy CA from master" || echo "self-signed")")"
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

# Load ppolicy module on replica (required for pwdPolicy objectClass)
# Without this, syncrepl fails with "objectClass: value #0 invalid per syntax"
echo ""
echo "=== Loading ppolicy module ==="
ppolicy_loaded=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -s sub "(olcModuleLoad=ppolicy.la)" dn 2>/dev/null | grep -c "cn=module" || true)
if [[ "$ppolicy_loaded" -eq 0 ]]; then
  ldapmodify -Y EXTERNAL -H ldapi:/// <<'LDIFEOF'
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: ppolicy.la
LDIFEOF
  echo "[INFO] ppolicy module loaded on replica"
else
  echo "[INFO] ppolicy module already loaded"
fi

# Restart after schema + module load
systemctl restart symas-openldap-servers 2>/dev/null || systemctl restart slapd 2>/dev/null || true
sleep 5

# Ensure openssl is available for TLS cert generation
if ! command -v openssl >/dev/null 2>&1; then
  echo "[INFO] Installing openssl for TLS cert generation"
  dnf -y install openssl >/dev/null 2>&1 || true
fi

if [[ "$TLS_MODE" == "no" ]]; then
  echo ""
  echo "=== TLS_MODE=no: Skipping TLS cert configuration ==="
  echo "=== Running hardening (TLS enforcement disabled) ==="
  run "r6-fix-replica-ldapi-acl.sh"
  DISALLOW_ANON_BIND=1 REQUIRE_TLS_SIMPLE_BINDS=0 bash "${REPLICA_DIR}/r7-harden-replica.sh"
else
  run "r5-configure-replica-tls.sh"
  run "r6-fix-replica-ldapi-acl.sh"
  run "r7-harden-replica.sh"
fi
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
echo "  TLS mode: $TLS_MODE"
echo "============================================================"
echo ""
echo "Connect from CLI:"
if [[ "$TLS_MODE" == "no" ]]; then
  echo "  ldapsearch -x -H ldap://$(hostname -I | awk '{print $1}') \\"
  echo "    -D 'cn=admin,${BASE_DN}' -w '\${ADMIN_PW}' \\"
  echo "    -b '${BASE_DN}' -s one '(objectClass=*)' dn"
else
  echo "  LDAPTLS_REQCERT=never ldapsearch -x -ZZ \\"
  echo "    -H ldap://$(hostname -I | awk '{print $1}') \\"
  echo "    -D 'cn=admin,${BASE_DN}' -w '\${ADMIN_PW}' \\"
  echo "    -b '${BASE_DN}' -s one '(objectClass=*)' dn"
fi
echo ""
echo "  To re-run verification:"
echo "  sudo MASTER_IP=${MASTER_IP} ADMIN_PW=\$ADMIN_PW bash replica/r9-verify-replica.sh"
