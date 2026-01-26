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

run "1-install-symas-openldap.sh"
run "2-Override-System-Limits.sh"
run "3-install-example.sh"
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
run "12-Create_custom_schema.sh"
run "13-Create_custom_schema_attr"
run "7-verify_symas_openldap.sh"

echo
echo "=== All scripts completed ==="
