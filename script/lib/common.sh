#!/usr/bin/env bash
# lib/common.sh — shared logging, section headers, PASS/FAIL/WARN counters
# Source this first in every script.
# ponytail: single file for all shared output concerns

set -euo pipefail

# ---- Colors (disable with --no-color or NO_COLOR=1) ----
if [[ -t 1 ]] && [[ "${NO_COLOR:-0}" != "1" ]]; then
  C_PASS='\033[0;32m' C_FAIL='\033[0;31m' C_WARN='\033[0;33m'
  C_SKIP='\033[0;36m' C_INFO='\033[0;37m' C_BOLD='\033[1m'
  C_RESET='\033[0m'
else
  C_PASS='' C_FAIL='' C_WARN='' C_SKIP='' C_INFO='' C_BOLD='' C_RESET=''
fi

# ---- Global counters ----
PASS=0; FAIL=0; WARN=0; SKIP=0
START_TIME=${SECONDS:-0}

# ponytail: single function per verb, avoids printf format traps
ok()   { echo -e "${C_PASS}[PASS]${C_RESET} $*"; PASS=$((PASS+1)); }
bad()  { echo -e "${C_FAIL}[FAIL]${C_RESET} $*" >&2; FAIL=$((FAIL+1)); }
warn() { echo -e "${C_WARN}[WARN]${C_RESET} $*" >&2; WARN=$((WARN+1)); }
skip() { echo -e "${C_SKIP}[SKIP]${C_RESET} $*"; SKIP=$((SKIP+1)); }
info() { echo -e "${C_INFO}[INFO]${C_RESET} $*"; }
log()  { echo -e "${C_INFO}[INFO]${C_RESET} $*"; }
fatal(){ echo -e "${C_FAIL}[FATAL]${C_RESET} $*" >&2; exit 1; }

section() {
  local title="$1"
  echo ""
  echo -e "${C_BOLD}=== ${title} ===${C_RESET}"
}

summary() {
  local duration=$(( ${SECONDS:-0} - START_TIME ))
  local mm=$((duration / 60))
  local ss=$((duration % 60))
  echo ""
  echo -e "${C_BOLD}========================================${C_RESET}"
  echo -e " SUMMARY: ${C_PASS}PASS=${PASS}${C_RESET} ${C_FAIL}FAIL=${FAIL}${C_RESET} ${C_WARN}WARN=${WARN}${C_RESET} ${C_SKIP}SKIP=${SKIP}${C_RESET}"
  if [[ "$FAIL" -eq 0 ]]; then
    echo -e " RESULT: ${C_PASS}OK${C_RESET} ($([[ $WARN -gt 0 ]] && echo "${WARN} warning(s), " || true)${mm}m ${ss}s)"
  else
    echo -e " RESULT: ${C_FAIL}FAILED${C_RESET} (${FAIL} failure(s), ${mm}m ${ss}s)"
  fi
  echo -e "${C_BOLD}========================================${C_RESET}"
}

banner() {
  echo ""
  echo -e "${C_BOLD}========================================${C_RESET}"
  echo -e " ${1}"
  echo -e " Host: $(hostname -f 2>/dev/null || hostname) | $(date '+%Y-%m-%d %H:%M:%S')"
  echo -e " Base DN: ${BASE_DN:-dc=eab,dc=bank,dc=local} | TLS: ${TLS_MODE:-yes}"
  echo -e "${C_BOLD}========================================${C_RESET}"
}

# ---- Safe PATH setup (works around sudo clearing PATH) ----
setup_path() {
  export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH:-/usr/bin}"
  [[ -f /etc/profile.d/symas_env.sh ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
  [[ -f /opt/symas/etc/openldap/sysmas_env.sh ]] && source /opt/symas/etc/openldap/sysmas_env.sh 2>/dev/null || true
  export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }
require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Must run as root"; }

# ---- Find slapd service (systemctl or pgrep fallback) ----
find_service() {
  for svc in symas-openldap-servers slapd; do
    if systemctl list-unit-files 2>/dev/null | grep -qF "$svc"; then
      echo "$svc" && return 0
    fi
  done
  if pgrep -x slapd >/dev/null 2>&1; then echo "slapd" && return 0; fi
  # ponytail: fallback — if nothing found, try symas-openldap-servers anyway
  echo "symas-openldap-servers"
}

# ---- Defaults (overridable via env) ----
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_PW="${ADMIN_PW:-admin}"
REPL_PW="${REPL_PW:-replpass}"
ADMIN_DN="cn=admin,${BASE_DN}"
REPL_DN="cn=replicator,${BASE_DN}"
TLS_MODE="${TLS_MODE:-yes}"
LDAPI_URI="ldapi:///"
TLS_DIR="${TLS_DIR:-/opt/symas/etc/openldap/tls}"
