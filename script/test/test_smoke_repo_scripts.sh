#!/usr/bin/env bash
set -euo pipefail

# Repo-wide smoke tests for shell scripts.
# Intentionally environment-agnostic: only performs syntax checks and static reference checks.

PASS=0
FAIL=0
WARN=0

ok() { echo "[ OK ] $*"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN + 1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

list_scripts() {
  # Only .sh scripts, excluding common generated/dependency dirs.
  # shellcheck disable=SC2016
  find "${REPO_ROOT}" \
    -type d \( -name .git -o -name node_modules -o -name vendor -o -name .terraform -o -name .venv \) -prune -o \
    -type f -name '*.sh' -print \
    | sed "s|^${REPO_ROOT}/||" \
    | sort
}

syntax_check() {
  local rel="$1"
  local abs="${REPO_ROOT}/${rel}"

  local first
  first="$(head -n 1 "$abs" 2>/dev/null || true)"

  local shell="bash"
  if [[ "$first" == '#!/bin/sh' || "$first" == '#!/usr/bin/sh' || "$first" == '#!/usr/bin/env sh' ]]; then
    shell="sh"
  fi

  if "${shell}" -n "$abs" >/dev/null 2>&1; then
    ok "${shell} -n ${rel}"
  else
    bad "${shell} -n ${rel}"
    "${shell}" -n "$abs" 2>&1 | head -n 1 | sed 's/^/      /'
  fi

  # Soft signal: scripts without shebang are harder to run correctly.
  if [[ "$first" != '#!'* ]]; then
    warn "Missing shebang: ${rel}"
  fi
}

check_orchestrator_refs() {
  local rel="$1"
  local abs="${REPO_ROOT}/${rel}"

  # Only check files that look like they use the `run "..."` helper.
  if ! grep -Eq '^[[:space:]]*run[[:space:]]*"' "$abs" 2>/dev/null; then
    return 0
  fi

  local base_dir
  base_dir="$(cd "$(dirname "$abs")" && pwd)"

  local missing=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue

    local candidate=""
    if [[ "$name" == /* ]]; then
      candidate="$name"
    elif [[ -f "${base_dir}/${name}" ]]; then
      candidate="${base_dir}/${name}"
    elif [[ -f "${REPO_ROOT}/${name}" ]]; then
      candidate="${REPO_ROOT}/${name}"
    fi

    if [[ -z "$candidate" || ! -f "$candidate" ]]; then
      bad "${rel} references missing script: ${name}"
      missing=1
    else
      ok "${rel} references existing script: ${name}"
    fi
  done < <(
    sed -n 's/^[[:space:]]*run[[:space:]]*"\([^"]\+\)".*$/\1/p' "$abs"
  )

  if [[ "$missing" -eq 0 ]]; then
    ok "${rel}: all referenced scripts exist"
  fi
}

echo "=== Repo smoke: syntax check all .sh scripts (bash/sh -n) ==="
while IFS= read -r rel; do
  syntax_check "$rel"
done < <(list_scripts)

echo
echo "=== Repo smoke: orchestrator references (run \"...\") ==="
while IFS= read -r rel; do
  check_orchestrator_refs "$rel"
done < <(list_scripts)

echo
echo "[INFO] PASS=${PASS} WARN=${WARN} FAIL=${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
