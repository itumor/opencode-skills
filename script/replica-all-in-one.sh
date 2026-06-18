#!/usr/bin/env bash
# replica-all-in-one.sh — OpenLDAP Replica: install, configure, harden, verify, test, diagnose
#
# Usage:
#   sudo MASTER_IP=10.0.0.1 ADMIN_PW=secret bash replica-all-in-one.sh
#
# Required env:
#   MASTER_IP   - IP or hostname of master
#   ADMIN_PW    - Admin password (must match master)
#
# Optional env:
#   REPL_PW          - Replicator password (default: replpass)
#   BASE_DN          - Base DN (default: dc=eab,dc=bank,dc=local)
#   SERVER_ID        - Server ID (default: 2)
#   COPY_FROM_MASTER - Use master CA certs (default: 0 = self-signed)
#   STAGED_CA_CERT   - Path to pre-staged CA cert
#   STAGED_CA_KEY    - Path to pre-staged CA key
#
# Override ENV vars:
#   SKIP_INSTALL=1   Skip package install
#   SKIP_TLS=1       Skip TLS cert generation
#   SKIP_HARDEN=1    Skip security hardening
#   SKIP_TUNE=1      Skip performance tuning
#   SKIP_TEST=1      Skip integration tests
#   SKIP_DIAG=1      Skip diagnostic collection
#   FORCE_FIX=1      Run fix step even if verify passed
#   ONLY_VERIFY=1    Only verify + diagnose
#   ONLY_FIX=1       Only fix + verify
#   DRY_RUN=1        Print what would happen
#   TLS_MODE=yes/no  Enable/disable TLS (default: yes)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# ---- Load library ----
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/ldap-ops.sh"
source "${LIB_DIR}/install.sh"
source "${LIB_DIR}/configure.sh"
source "${LIB_DIR}/harden.sh"
source "${LIB_DIR}/tune.sh"
source "${LIB_DIR}/verify.sh"
source "${LIB_DIR}/fix.sh"
source "${LIB_DIR}/diag.sh"

require_root
setup_path

# Validate required vars
: "${MASTER_IP:?MASTER_IP is required (IP or hostname of master node)}"
: "${ADMIN_PW:?ADMIN_PW is required (must match master admin password)}"

export MASTER_IP ADMIN_PW
export REPL_PW="${REPL_PW:-replpass}"
export SERVER_ID="${SERVER_ID:-2}"

# ---- Handle COPY_FROM_MASTER (pre-staged CA certs) ----
if [[ "${COPY_FROM_MASTER:-0}" == "1" && -f "${STAGED_CA_CERT:-/nonexistent}" ]]; then
  mkdir -p "${TLS_DIR}"
  cp "${STAGED_CA_CERT}" "${TLS_DIR}/ca.crt"
  [[ -f "${STAGED_CA_KEY:-/nonexistent}" ]] && cp "${STAGED_CA_KEY}" "${TLS_DIR}/ca.key"
  cp "${TLS_DIR}/ca.crt" "${TLS_DIR}/ldap.crt"
  cp "${TLS_DIR}/ca.key" "${TLS_DIR}/ldap.key" 2>/dev/null || true
  chmod 600 "${TLS_DIR}"/*.key 2>/dev/null || true
  info "CA certs staged from master"
fi

# ---- Special modes ----
if [[ "${ONLY_FIX:-0}" == "1" ]]; then
  banner "OpenLDAP Replica — Fix Mode"
  fix "replica"
  verify
  summary
  exit $(( FAIL > 0 ? 1 : 0 ))
fi

if [[ "${ONLY_VERIFY:-0}" == "1" ]]; then
  banner "OpenLDAP Replica — Verify Mode"
  verify
  diag_status
  summary
  exit $(( FAIL > 0 ? 1 : 0 ))
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  banner "OpenLDAP Replica — DRY RUN"
  warn "DRY_RUN=1 — no changes will be made"
  for step in "install_packages" "load_base_schemas" "load_custom_schema" "load_custom_attributes" \
              "configure_tls" "configure_replication_replica" "configure_ppolicy" \
              "harden" "tune" "start_daemon" "verify" "diag" "fix"; do
    info "Would run: ${step}"
  done
  summary
  exit 0
fi

# ---- Full pipeline ----
banner "OpenLDAP Replica — All-in-One Installer"

# Optional: clean first
if [[ "${CLEAN:-0}" == "1" ]]; then clean_openldap; fi

# Step 1: Install
install_packages
install_openssl
init_cn_config
fix_rootpw_hash
fix_symas_env
start_daemon

# ponytail: run old proven ACL fix
section "Fix LDAPI ACL (cn=config)"
if [[ -f "${SCRIPT_DIR}/8.0-fix_ldapi_acl.sh" ]]; then
  bash "${SCRIPT_DIR}/8.0-fix_ldapi_acl.sh" >/dev/null 2>&1 && ok "LDAPI ACL fixed" || warn "LDAPI ACL fix had issues"
fi

# Step 2: Configure
load_base_schemas
load_custom_schema
load_custom_attributes
if [[ "$TLS_MODE" == "yes" ]]; then configure_tls; else skip "TLS disabled (TLS_MODE=no)"; fi
configure_replication_replica
configure_ppolicy

# Step 3: Harden
if [[ "$TLS_MODE" == "yes" ]]; then
  harden
else
  section "Security Hardening"
  skip "Hardening skipped — TLS_MODE=no"
fi

# Step 4: Tune
tune

# Step 5: Verify
verify

# Step 7: Test
if [[ "${SKIP_TEST:-0}" != "1" ]]; then
  section "Integration Tests"
  for test in test_replica_connections test_replica_readonly; do
    local tp="${SCRIPT_DIR}/replica/test/${test}.sh"
    if [[ -f "$tp" ]]; then
      bash "$tp" && ok "${test}" || bad "${test}"
    else
      skip "${test} (not found)"
    fi
  done
  info "Waiting 15s for initial sync..."
  sleep 15
  local tp="${SCRIPT_DIR}/replica/test/test_replica_sync.sh"
  if [[ -f "$tp" ]]; then
    bash "$tp" && ok "test_replica_sync" || bad "test_replica_sync"
  fi
else
  section "Integration Tests"
  skip "Tests skipped (SKIP_TEST=1)"
fi

# Step 8: Diagnose
diag

# Step 9: Auto-fix (if anything failed)
if [[ "$FAIL" -gt 0 ]] || [[ "${FORCE_FIX:-0}" == "1" ]]; then
  fix "replica"
  section "Re-verify after fixes"
  PASS=0; FAIL=0; WARN=0
  verify
fi

summary
exit $(( FAIL > 0 ? 1 : 0 ))
