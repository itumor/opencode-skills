#!/usr/bin/env bash
# master-all-in-one.sh — OpenLDAP Master: install, configure, harden, verify, test, diagnose
#
# Usage:
#   sudo bash master-all-in-one.sh
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
#   DRY_RUN=1        Print what would happen, don't execute
#   TLS_MODE=yes/no  Enable/disable TLS (default: yes)
#   VERBOSE=1        Show detailed command output
#   QUIET=1          Only show section headers + FAIL/WARN
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

# ---- Special modes ----
if [[ "${ONLY_FIX:-0}" == "1" ]]; then
  banner "OpenLDAP Master — Fix Mode"
  fix "master"
  fix_accesslog_size "master"
  verify
  summary
  exit $(( FAIL > 0 ? 1 : 0 ))
fi

if [[ "${ONLY_VERIFY:-0}" == "1" ]]; then
  banner "OpenLDAP Master — Verify Mode"
  verify
  diag_status
  summary
  exit $(( FAIL > 0 ? 1 : 0 ))
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  banner "OpenLDAP Master — DRY RUN"
  warn "DRY_RUN=1 — no changes will be made"
  for step in "install_packages" "load_base_schemas" "load_custom_schema" "load_custom_attributes" \
              "configure_tls" "create_ous" "configure_replication_master" "configure_ppolicy" \
              "configure_accesslog" "harden" "tune" "start_daemon" "verify" "diag" "fix"; do
    info "Would run: ${step}"
  done
  summary
  exit 0
fi

# ---- Full pipeline ----
banner "OpenLDAP Master — All-in-One Installer"

# Optional: clean first
if [[ "${CLEAN:-0}" == "1" ]]; then clean_openldap; fi

# Step 1: Install
install_packages
install_openssl
init_cn_config
fix_rootpw_hash
fix_symas_env
start_daemon

# ponytail: run old proven ACL fix (handles config DB manage access for ldapi)
section "Fix LDAPI ACL (cn=config)"
if [[ -f "${SCRIPT_DIR}/8.0-fix_ldapi_acl.sh" ]]; then
  bash "${SCRIPT_DIR}/8.0-fix_ldapi_acl.sh" >/dev/null 2>&1 && ok "LDAPI ACL fixed" || warn "LDAPI ACL fix had issues"
fi

# Step 2: Configure
load_base_schemas
load_custom_schema
load_custom_attributes
if [[ "$TLS_MODE" == "yes" ]]; then configure_tls; else skip "TLS disabled (TLS_MODE=no)"; fi
create_ous
configure_replication_master
configure_ppolicy
configure_accesslog

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
  for test in test_password_checker test_password_complexity test_mw_service_user \
              test_service_account_password_policy_never_expire test_create_user_using_mw_user \
              test_configure_ssl_tls test_custom_schema_attr test_accesslog_audit test_bindings; do
    local tp="${SCRIPT_DIR}/test/${test}.sh"
    if [[ -f "$tp" ]]; then
      bash "$tp" && ok "${test}" || bad "${test}"
    else
      skip "${test} (not found)"
    fi
  done
else
  section "Integration Tests"
  skip "Tests skipped (SKIP_TEST=1)"
fi

# Step 8: Diagnose
diag

# Step 9: Auto-fix (if anything failed)
if [[ "$FAIL" -gt 0 ]] || [[ "${FORCE_FIX:-0}" == "1" ]]; then
  fix "master"
  fix_accesslog_size "master"
  section "Re-verify after fixes"
  PASS=0; FAIL=0; WARN=0
  verify
fi

summary
exit $(( FAIL > 0 ? 1 : 0 ))
