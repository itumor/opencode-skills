#!/usr/bin/env bash
set -euo pipefail

ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  if [[ -f "$prof" ]]; then
    # shellcheck source=/etc/profile.d/symas_env.sh
    source "$prof"
  fi

  if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
    export PATH="/opt/symas/bin:${PATH}"
  fi
}

ensure_symas_env

require_cmd() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "$bin not found in PATH. Ensure Symas OpenLDAP client tools are installed and PATH is set." >&2
    exit 1
  fi
}

require_cmd ldapsearch

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
EXAMPLEDB_FILE="${ROOT_DIR}/Exampledb/exampledb.sh"

read_exampledb_password() {
  local file="$1"
  local pw=""
  if [[ -f "$file" ]]; then
    pw="$(awk '
      /^[[:space:]]*#/ {next}
      $1 == "rootpw" {print $2; exit}
      $1 == "olcRootPW:" {print $2; exit}
      $1 == "olcRootPw:" {print $2; exit}
    ' "$file")"
  fi
  [[ -n "$pw" ]] || return 1
  echo "$pw"
}

BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
BIND_DN="${BIND_DN:-cn=admin,${BASE_DN}}"
LDAP_URI="${LDAP_URI:-ldap://localhost}"
BIND_PW="${BIND_PW:-$(read_exampledb_password "$EXAMPLEDB_FILE" || true)}"

SERVICE_OU="${SERVICE_OU:-ou=ServiceAccounts,${BASE_DN}}"
MW_UID="${MW_UID:-mw}"
MW_DN="uid=${MW_UID},${SERVICE_OU}"

AUTH_ARGS=( -x -D "$BIND_DN" )
if [[ -n "$BIND_PW" ]]; then
  AUTH_ARGS+=( -w "$BIND_PW" )
else
  AUTH_ARGS+=( -W )
fi

echo "======================================"
echo "Test 17 - MW Service Account User"
echo "DN: $MW_DN"
echo "======================================"

if ldapsearch "${AUTH_ARGS[@]}" -H "$LDAP_URI" -b "$MW_DN" -s base "(objectClass=*)" dn >/tmp/test_mw_user.out 2>/tmp/test_mw_user.err; then
  echo "PASS: ${MW_DN} exists"
else
  echo "FAIL: ${MW_DN} not found"
  cat /tmp/test_mw_user.err
  exit 1
fi
