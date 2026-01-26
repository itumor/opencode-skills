#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0
WARN=0

ok()   { echo "[ OK ] $*"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN+1)); }

DISALLOWED_ROOT="${DISALLOWED_ROOT:-/root}"
SYMAS_PREFIXES="${SYMAS_PREFIXES:-/opt/symas /var/symas}"

if [[ "$DISALLOWED_ROOT" == "/root" && "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Run as root to verify installation paths under /root."
  exit 1
fi

resolve_path() {
  local path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path"
  else
    readlink -f "$path"
  fi
}

path_under() {
  local path="$1"
  local root="$2"
  [[ "$path" == "$root" || "$path" == "$root/"* ]]
}

check_prefix() {
  local prefix="$1"
  if [[ -e "$prefix" ]]; then
    local resolved
    resolved="$(resolve_path "$prefix")"
    if path_under "$resolved" "$DISALLOWED_ROOT_RESOLVED"; then
      bad "Installation prefix $prefix resolves under disallowed root ($DISALLOWED_ROOT_RESOLVED): $resolved"
    else
      ok "Installation prefix $prefix resolves outside $DISALLOWED_ROOT_RESOLVED ($resolved)"
    fi
  else
    warn "Prefix not found: $prefix"
  fi
}

check_path() {
  local path="$1"
  if [[ -e "$path" ]]; then
    local resolved
    resolved="$(resolve_path "$path")"
    if path_under "$resolved" "$DISALLOWED_ROOT_RESOLVED"; then
      bad "Detected path under disallowed root ($DISALLOWED_ROOT_RESOLVED): $resolved"
    else
      ok "Path resolves outside $DISALLOWED_ROOT_RESOLVED ($resolved)"
    fi
  fi
}

DISALLOWED_ROOT_RESOLVED="$(resolve_path "$DISALLOWED_ROOT")"
echo "[INFO] Disallowed install root: $DISALLOWED_ROOT_RESOLVED"

check_path "$DISALLOWED_ROOT/symas"
check_path "$DISALLOWED_ROOT/opt/symas"

for prefix in $SYMAS_PREFIXES; do
  check_prefix "$prefix"
done

if command -v rpm >/dev/null 2>&1; then
  for pkg in symas-openldap-servers symas-openldap-clients symas-openldap; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
      ok "Package installed: $pkg"
      while IFS= read -r path; do
        if path_under "$path" "$DISALLOWED_ROOT_RESOLVED"; then
          bad "Package $pkg installs under disallowed root: $path"
        fi
      done < <(rpm -ql "$pkg" 2>/dev/null || true)
    fi
  done
else
  warn "rpm not available; skipping package file checks"
fi

if command -v slapd >/dev/null 2>&1; then
  slapd_path="$(resolve_path "$(command -v slapd)")"
  if path_under "$slapd_path" "$DISALLOWED_ROOT_RESOLVED"; then
    bad "slapd binary under disallowed root: $slapd_path"
  else
    ok "slapd binary outside disallowed root: $slapd_path"
  fi
else
  warn "slapd not found in PATH; skipping binary location check"
fi

echo "[INFO] PASS=$PASS WARN=$WARN FAIL=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
