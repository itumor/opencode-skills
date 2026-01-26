#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Must be run as root"
  exit 1
fi

run() {
  local script_name="$1"
  local path="$SCRIPT_DIR/$script_name"

  if [[ ! -f "$path" ]]; then
    echo "[FATAL] Missing script: $path"
    exit 1
  fi

  echo
  echo "=== Running $script_name ==="
  bash "$path"
}

run_interactive() {
  local script_name="$1"
  local input="$2"
  local path="$SCRIPT_DIR/$script_name"

  if [[ ! -f "$path" ]]; then
    echo "[FATAL] Missing script: $path"
    exit 1
  fi

  echo
  echo "=== Running $script_name ==="
  echo "$input" | bash "$path"
}

run "1-install-symas-openldap.sh"
run "2-Override-System-Limits.sh"
run_interactive "3-install-example.sh" "2
YES"
run "4-Start-the-daemon.sh"
run "5-fix_all_symas_warns.sh"
run "6-fix_remaining_symas_warns.sh"
run "11-fix_version_warns.sh"
run "7-verify_symas_openldap.sh"
run "8.0-fix_ldapi_acl.sh"
run "8-create_top_ous.sh"
run "9-password_policy.sh"
run "9.0-password_policy_load_module.sh"
run "9.2-load_lst_bind.sh"
run "10-ppolicy-container.sh"
run "10.0-password_policy_make_default.sh"
run "10.1-load_lst_bind.sh"
run "10.2-load_configure_PPM.sh"
run "10.3-confiure_decode_PPM_conf.sh"
run "12-Create_custom_schema.sh"
run "13-Create_custom_schema_attr"
run "7-verify_symas_openldap.sh"
run "15-add-password-checker.sh"
run "16-add-strong-password-quality-checker-PPM.sh"
run "17-create_mw_user.sh"
run "18-service-account-password-policy-never-expire.sh"
run "19-create-user-using-mw-user.sh"
run "20-migration.sh"
run "21-hardening.sh"
run "22-tuning.sh"
run "23-ensure-installation-not-under-root.sh"
run "24-configure-ssl-tls.sh"

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
  bash "$test_path"
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

echo
echo "=== All scripts and tests completed ==="
