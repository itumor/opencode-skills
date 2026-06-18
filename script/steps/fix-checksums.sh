#!/usr/bin/env bash
# steps/fix-checksums.sh — Fix cn=config checksum errors
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/fix.sh"
require_root; setup_path
banner "Fix: Config Checksums"
fix_checksums "$(detect_role)"
summary
