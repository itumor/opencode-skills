#!/usr/bin/env bash
set -euo pipefail

# One entrypoint to run script tests.
# - Always runs smoke tests (no LDAP required)
# - Optionally runs LDAP integration tests (requires RHEL/Symas/OpenLDAP configured)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Running smoke tests ==="
bash "${SCRIPT_DIR}/test_smoke_all_scripts.sh"
echo
bash "${SCRIPT_DIR}/test_smoke_repo_scripts.sh"

echo
if [[ "${RUN_LDAP_INTEGRATION_TESTS:-0}" != "1" ]]; then
  echo "=== Skipping LDAP integration tests (set RUN_LDAP_INTEGRATION_TESTS=1 to enable) ==="
  exit 0
fi

echo "=== Running LDAP integration tests ==="

tests=(
  "test_password_checker.sh"
  "test_password_complexity.sh"
  "test_mw_service_user.sh"
  "test_service_account_password_policy_never_expire.sh"
  "test_create_user_using_mw_user.sh"
  "test_installation_not_under_root.sh"
  "test_tuning.sh"
  "test_configure_ssl_tls.sh"
  "test_custom_schema_attr.sh"
  "test_accesslog_audit.sh"
  "test_bindings.sh"
)

for t in "${tests[@]}"; do
  path="${SCRIPT_DIR}/${t}"
  if [[ ! -f "$path" ]]; then
    echo "[WARN] Missing test: ${path}"
    continue
  fi
  echo
  echo "=== ${t} ==="
  bash "$path"
done

echo
echo "=== All tests completed ==="
