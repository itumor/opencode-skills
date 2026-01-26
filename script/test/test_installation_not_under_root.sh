#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/../23-ensure-installation-not-under-root.sh"

if [[ ! -x "$TARGET_SCRIPT" ]]; then
  echo "[FATAL] Missing target script: $TARGET_SCRIPT" >&2
  exit 1
fi

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

bad_root="${tmp_root}/root"
good_root="${tmp_root}/opt"
mkdir -p "${bad_root}/symas" "${good_root}/symas"

echo "[TEST] Expect failure when install prefix is under disallowed root"
set +e
DISALLOWED_ROOT="$bad_root" SYMAS_PREFIXES="${bad_root}/symas" "$TARGET_SCRIPT"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "[FAIL] Script succeeded but should have failed for disallowed root"
  exit 1
fi
echo "[PASS] Script failed as expected"

echo "[TEST] Expect success when install prefix is outside disallowed root"
rm -rf "${bad_root}/symas"
DISALLOWED_ROOT="$bad_root" SYMAS_PREFIXES="${good_root}/symas" "$TARGET_SCRIPT"
echo "[SUCCESS] Installation location checks passed"
