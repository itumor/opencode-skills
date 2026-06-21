#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Must be run as root"
  exit 1
fi

TLS_MODE="${TLS_MODE:-yes}"

run() {
  local script_name="$1"
  local path="$SCRIPT_DIR/$script_name"

  if [[ ! -f "$path" ]]; then
    echo "[FATAL] Missing script: $path"
    exit 1
  fi

  echo
  echo "=== Running $script_name ==="
  bash "$path" || echo "[WARN] $script_name had errors - continuing"
}

run "1-install-symas-openldap.sh"
run "3-install-example.sh"
run "4-Start-the-daemon.sh"
run "5-fix_all_symas_warns.sh"
run "6-fix_remaining_symas_warns.sh"
run "11-fix_version_warns.sh"
run "7-verify_symas_openldap.sh"
run "8.0-fix_ldapi_acl.sh"
run "8-create_top_ous.sh"
run "26-configure-bindings.sh"
run "9-password_policy.sh"
run "9.0-password_policy_load_module.sh"
run "10-ppolicy-container.sh"
run "10.0-password_policy_make_default.sh"
run "12-Create_custom_schema.sh"
run "13-Create_custom_schema_attr.sh"
echo; echo "=== Running bank-add-orclisenabled.sh ==="
bash "$SCRIPT_DIR/bank-add-orclisenabled.sh" --force
run "7-verify_symas_openldap.sh"
run "16-add-strong-password-quality-checker-PPM.sh"
run "bank-apply-password-policy.sh"
run "28-fix-ppolicy-seconds.sh"
run "bank-add-ppolicy-hash-cleartext.sh"
run "17-create_mw_user.sh"
run "27-configure-mw-acl.sh"
run "18-service-account-password-policy-never-expire.sh"
run "19-create-user-using-mw-user.sh"
run "20-migration.sh"

echo; echo "=== Running bank-fix-exampledb-acl.sh ==="
bash "$SCRIPT_DIR/bank-fix-exampledb-acl.sh"

if [[ "$TLS_MODE" == "yes" ]]; then
  run "24-configure-ssl-tls.sh"
  run "21-hardening.sh"
else
  echo
  echo "=== TLS_MODE=no: Skipping TLS cert configuration ==="
  echo "=== Running hardening (TLS hardening disabled unless OPENLDAP_HARDEN=yes) ==="
  run "21-hardening.sh"
fi

run "22-tuning.sh"
run "23-ensure-installation-not-under-root.sh"
run "25-configure-accesslog-audit.sh"

# Comprehensive performance tuning (lab-validated on 600K users)
echo
echo "=== Running comprehensive performance tuning ==="
PERF_TUNE="${SCRIPT_DIR}/perf/bank-tune-master.sh"
if [[ -f "$PERF_TUNE" ]]; then
  bash "$PERF_TUNE" || echo "[WARN] Performance tuning had errors - check logs"
else
  echo "[INFO] bank-tune-master.sh not found - skipping comprehensive tuning"
fi

echo
echo "=== Running tests ==="

run_test() {
  local test_name="$1"
  local test_path="$SCRIPT_DIR/test/$test_name"

  if [[ ! -f "$test_path" ]]; then
    echo "[WARN] Missing test: $test_path"
    return 0
  fi

  echo
  echo "=== Running $test_name ==="
  bash "$test_path" || echo "[WARN] $test_name had errors - continuing"
}

run_test "test_password_checker.sh"
run_test "test_password_complexity.sh"
run_test "test_mw_service_user.sh"
run_test "test_service_account_password_policy_never_expire.sh"
run_test "test_create_user_using_mw_user.sh"
run_test "test_installation_not_under_root.sh"
run_test "test_tuning.sh"
run_test "test_configure_ssl_tls.sh"
run_test "test_custom_schema_attr.sh"
run_test "test_accesslog_audit.sh"
run_test "test_bindings.sh"

echo
echo "=== Running OpenLDAP fix + validation ==="
FIX_DIR="${SCRIPT_DIR}/../scripts/openldap-fix"
if [[ -f "${FIX_DIR}/bank-one-click-fix.sh" ]]; then
  bash "${FIX_DIR}/bank-one-click-fix.sh" || echo "[WARN] Fix script had non-critical warnings"
else
  echo "[WARN] bank-one-click-fix.sh not found at ${FIX_DIR} — skipping post-install fix"
fi

echo
echo "=== All scripts and tests completed ==="
