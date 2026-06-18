#!/usr/bin/env bash
# steps/collect-logs.sh — Collect slapd logs + config for support
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/ldap-ops.sh"
source "${SCRIPT_DIR}/lib/diag.sh"
require_root; setup_path
banner "Collect Logs"
diag_logs
summary
