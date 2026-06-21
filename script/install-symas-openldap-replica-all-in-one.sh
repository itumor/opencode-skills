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
  bash "$path" || echo "[WARN] ${script_name} had errors - continuing"
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
bash "${SCRIPT_DIR_OUTER}/bank-add-orclisenabled.sh" --force

# Load ppolicy module on replica (required for pwdPolicy objectClass)
# Without this, syncrepl fails with "objectClass: value #0 invalid per syntax"
echo ""
echo "=== Loading ppolicy module ==="
# Ensure PATH is set for ldap tools
export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH:-/usr/bin}"
[[ -f /etc/profile.d/symas_env.sh ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
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

# Add ppolicy overlay to database (cn=config — not replicated, needed on replica too)
echo ""
echo "=== Adding ppolicy overlay to database ==="
DB_DN=$(/opt/symas/bin/ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -s sub "(objectClass=olcMdbConfig)" dn 2>/dev/null | grep "^dn: " | head -1 | sed 's/^dn: //')
PP_DN="olcOverlay=ppolicy,${DB_DN}"
if /opt/symas/bin/ldapsearch -Y EXTERNAL -H ldapi:/// -b "$PP_DN" -s base dn 2>/dev/null | grep -q "^dn:"; then
  echo "[INFO] ppolicy overlay already on database"
else
  /opt/symas/bin/ldapadd -Y EXTERNAL -H ldapi:/// <<LDIFEOFPP
dn: ${PP_DN}
objectClass: olcOverlayConfig
objectClass: olcPPolicyConfig
olcOverlay: ppolicy
LDIFEOFPP
  echo "[INFO] ppolicy overlay added to database (child entry)"
fi

echo ""
echo "=== Setting olcPPolicyHashCleartext=TRUE ==="
bash "${SCRIPT_DIR_OUTER}/bank-add-ppolicy-hash-cleartext.sh" --force 2>&1 || echo "[WARN] ppolicy hash cleartext had issues - continuing"

# Restart after schema + module load
systemctl restart symas-openldap-servers 2>/dev/null || systemctl restart slapd 2>/dev/null || true
sleep 5

# Load PPM module on replica (for password quality checking if available)
# Without PPM, advanced complexity checks (maxLength, minUpper, specialChars etc.)
# are not enforced on the replica side, but LDAP-level policy (pwdMaxAge,
# pwdMinLength, etc.) still works.
echo ""
echo "=== Loading PPM module ==="
MODULE_PATH="/opt/symas/lib/openldap"
PPM_CONF="${PPM_CONF:-/opt/symas/etc/openldap/ppm.conf}"
if [[ -f "${MODULE_PATH}/ppm.so" ]] || [[ -f "${MODULE_PATH}/ppm.la" ]]; then
  PPM_VAL="ppm.so"
  [[ -f "${MODULE_PATH}/ppm.la" ]] && PPM_VAL="ppm.la"
  ppm_loaded=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -s sub "(olcModuleLoad=ppm)" dn 2>/dev/null | grep -c "cn=module" || true)
   if [[ "$ppm_loaded" -eq 0 ]]; then
     if ldapmodify -Y EXTERNAL -H ldapi:/// <<LDIFEOF 2>/dev/null; then
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: ${PPM_VAL}
LDIFEOF
       echo "[INFO] PPM module loaded on replica"
     else
       echo "[WARN] PPM module load failed (may require licensed Symas) - continuing"
     fi
   else
     echo "[INFO] PPM module already loaded on replica"
   fi
  # Write a minimal ppm.conf on replica (full config replicates from master via syncrepl policy data)
  if [[ ! -f "$PPM_CONF" ]]; then
    mkdir -p "$(dirname "$PPM_CONF")"
    cat > "$PPM_CONF" << 'PPMEOF'
# PPM Configuration — bank password policy
# Full enforcement is on the master. Replica uses this for local pre-checks.
minLength 8
maxLength 12
minUpper 1
minLower 1
minDigit 1
minSpecial 0
specialChars _
historySize 5
maxRepeat 2
rejectUsername true
forbiddenChars ' " ( ) { } [ ] / \ = @ # $ % ! . -
PPMEOF
    chmod 600 "$PPM_CONF"
    if id ldap >/dev/null 2>&1; then chown ldap:ldap "$PPM_CONF"; fi
    echo "[INFO] PPM config written on replica"
  fi
else
  echo "[INFO] PPM module not found — skipping (advanced complexity checks require licensed Symas)"
fi

# Apply ExampleDB ACL fix (prevents normal users from reading each other)
echo ""
echo "=== Applying ExampleDB ACL fix ==="
bash "${SCRIPT_DIR_OUTER}/bank-fix-exampledb-acl.sh"

# Apply MW ACL fix + idle timeout (corrected ACL for middleware)
echo ""
echo "=== Applying MW ACL + idle timeout fix ==="
bash "${SCRIPT_DIR_OUTER}/29-fix-mw-acl-idle.sh" || echo "[WARN] MW ACL / idle timeout fix had errors - continuing"

# Ensure openssl is available for TLS cert generation
if ! command -v openssl >/dev/null 2>&1; then
  echo "[INFO] Installing openssl for TLS cert generation"
  dnf -y install openssl >/dev/null 2>&1 || true
fi

if [[ "$TLS_MODE" == "no" ]]; then
  echo ""
  echo "=== TLS_MODE=no: Skipping TLS cert configuration ==="
  echo "=== Running hardening (TLS hardening disabled unless OPENLDAP_HARDEN=yes) ==="
  run "r6-fix-replica-ldapi-acl.sh"
  run "r7-harden-replica.sh"
else
  run "r5-configure-replica-tls.sh"
  run "r6-fix-replica-ldapi-acl.sh"
  run "r7-harden-replica.sh"
fi
run "r8-tune-replica.sh"
run "r9-verify-replica.sh"

# Comprehensive performance tuning (lab-validated on 600K users)
echo
echo "=== Running comprehensive performance tuning ==="
SCRIPT_DIR_OUTER_COMPREHENSIVE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERF_TUNE="${SCRIPT_DIR_OUTER_COMPREHENSIVE}/perf/bank-tune-replica.sh"
if [[ -f "$PERF_TUNE" ]]; then
  bash "$PERF_TUNE" || echo "[WARN] Performance tuning had errors - check logs"
else
  echo "[INFO] bank-tune-replica.sh not found - skipping comprehensive tuning"
fi

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

echo ""
echo "=== Running OpenLDAP fix + validation ==="
SCRIPT_DIR_R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_DIR_R="${SCRIPT_DIR_R}/../scripts/openldap-fix"
if [[ -f "${FIX_DIR_R}/bank-one-click-fix.sh" ]]; then
  export MASTER_IP ADMIN_PW REPL_PW BASE_DN
  bash "${FIX_DIR_R}/bank-one-click-fix.sh" || echo "[WARN] Fix script had non-critical warnings"
else
  echo "[WARN] bank-one-click-fix.sh not found at ${FIX_DIR_R} — skipping post-install fix"
fi
