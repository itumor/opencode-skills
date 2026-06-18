#!/usr/bin/env bash
# steps/health-check.sh — Quick health check (auto-detects master vs replica)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/ldap-ops.sh"
source "${SCRIPT_DIR}/lib/verify.sh"
setup_path
banner "Health Check"
verify
diag_status
summary
