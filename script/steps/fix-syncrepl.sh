#!/usr/bin/env bash
# steps/fix-syncrepl.sh — Fix replica syncrepl to use StartTLS
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/ldap-ops.sh"
source "${SCRIPT_DIR}/lib/fix.sh"
require_root; setup_path
banner "Fix: Syncrepl TLS"
fix_syncrepl_tls "$(detect_role)"
summary
