#!/usr/bin/env bash
# steps/fix-ppolicy.sh — Fix missing ppolicy overlay/module
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/ldap-ops.sh"
source "${SCRIPT_DIR}/lib/fix.sh"
require_root; setup_path
banner "Fix: Password Policy"
fix_ppolicy
summary
