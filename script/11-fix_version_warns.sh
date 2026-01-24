#!/usr/bin/env bash
set -euo pipefail

echo "=== Fixing Symas version WARNs ==="

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Run as root"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/7-verify_symas_openldap.sh"

if [[ ! -f "$VERIFY" ]]; then
  echo "[FATAL] Missing verification script: $VERIFY"
  exit 1
fi

if grep -q ' -VV 2>/dev/null' "$VERIFY"; then
  sed -i 's/ -VV 2>\/dev\/null/ -VV 2>\&1/g' "$VERIFY"
fi

if grep -q ' -V 2>/dev/null' "$VERIFY"; then
  sed -i 's/ -V 2>\/dev\/null/ -V 2>\&1/g' "$VERIFY"
fi

echo "[OK] Verification version checks now capture stderr"
echo "Run:"
echo "  ./7-verify_symas_openldap.sh"
