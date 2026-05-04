#!/usr/bin/env bash
set -euo pipefail

# Smoke tests for this repo's scripts.
# This is intentionally environment-agnostic (macOS/Linux) and does not require root.
#
# What it checks:
# - Every .sh script parses (`bash -n`)
# - Orchestrator scripts only reference scripts that exist on disk

PASS=0
FAIL=0
WARN=0

ok() { echo "[ OK ] $*"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN + 1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

list_scripts() {
  # shellcheck disable=SC2016
  find "${ROOT_DIR}" -type f \( -path "${ROOT_DIR}/test/*" -prune \) -o -name '*.sh' -print \
    | sed "s|^${ROOT_DIR}/||" \
    | sort
}

syntax_check() {
  local rel="$1"
  local abs="${ROOT_DIR}/${rel}"
  if bash -n "$abs" >/dev/null 2>&1; then
    ok "bash -n ${rel}"
  else
    bad "bash -n ${rel}"
    # Show the first error line to make fixing quick.
    bash -n "$abs" 2>&1 | head -n 1 | sed 's/^/      /'
  fi
}

check_orchestrator_refs() {
  local rel="$1"
  local abs="${ROOT_DIR}/${rel}"
  if [[ ! -f "$abs" ]]; then
    warn "Orchestrator not found: ${rel}"
    return 0
  fi

  local missing=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ ! -f "${ROOT_DIR}/${name}" ]]; then
      bad "${rel} references missing script: ${name}"
      missing=1
    else
      ok "${rel} references existing script: ${name}"
    fi
  done < <(
    # Extract: run "X.sh"
    sed -n 's/^[[:space:]]*run[[:space:]]*"\([^"]\+\)".*$/\1/p' "$abs"
  )

  if [[ "$missing" -eq 0 ]]; then
    ok "${rel}: all referenced scripts exist"
  fi
}

echo "=== Smoke: syntax check all scripts (bash -n) ==="
while IFS= read -r rel; do
  syntax_check "$rel"
done < <(list_scripts)

echo
echo "=== Smoke: orchestrator references ==="
check_orchestrator_refs "install-symas-openldap-all-in-one.sh"

echo
echo "[INFO] PASS=${PASS} WARN=${WARN} FAIL=${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
