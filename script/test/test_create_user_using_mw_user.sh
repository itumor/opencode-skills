#!/usr/bin/env bash
set -euo pipefail

# Ensure Symas tools are on PATH so ldapsearch/ldapwhoami are found.
if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
  PATH="/opt/symas/bin:${PATH}"
fi

LDAPSEARCH="${LDAPSEARCH:-$(command -v ldapsearch || true)}"
LDAPWHOAMI="${LDAPWHOAMI:-$(command -v ldapwhoami || true)}"

if [[ -z "$LDAPSEARCH" ]]; then
  echo "[FATAL] ldapsearch not found; ensure Symas clients are installed" >&2
  exit 1
fi
if [[ -z "$LDAPWHOAMI" ]]; then
  echo "[FATAL] ldapwhoami not found; ensure Symas clients are installed" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CREATE_SCRIPT="${SCRIPT_DIR}/19-create-user-using-mw-user.sh"

if [[ ! -x "$CREATE_SCRIPT" ]]; then
  echo "[FATAL] Script not found or not executable: ${CREATE_SCRIPT}" >&2
  exit 1
fi

LDAP_URI="${LDAP_URI:-ldap:///}"
MW_BIND_DN="${MW_BIND_DN:-uid=mw,ou=ServiceAccounts,ou=Systems,dc=eab,dc=bank,dc=local}"
MW_BIND_PW="${MW_BIND_PW:-}"
USER_BASE_DN="${USER_BASE_DN:-ou=Users,dc=eab,dc=bank,dc=local}"

if [[ -z "$MW_BIND_PW" ]]; then
  echo "[FATAL] MW_BIND_PW is required for non-interactive test runs." >&2
  exit 1
fi

timestamp="$(date +%Y%m%d%H%M%S)"
USER_UID="mwtest${timestamp}"

MW_BIND_DN="$MW_BIND_DN" \
MW_BIND_PW="$MW_BIND_PW" \
LDAP_URI="$LDAP_URI" \
USER_BASE_DN="$USER_BASE_DN" \
USER_UID="$USER_UID" \
USER_CN="MW Test ${timestamp}" \
USER_SN="Test${timestamp}" \
USER_GIVENNAME="MW" \
USER_PASSWORD="Test@123" \
"$CREATE_SCRIPT"

VERIFY_BIND_DN="${ADMIN_BIND_DN:-$MW_BIND_DN}"
VERIFY_BIND_PW="${ADMIN_BIND_PW:-$MW_BIND_PW}"

verify_args=(-x -H "$LDAP_URI" -D "$VERIFY_BIND_DN" -w "$VERIFY_BIND_PW")
if ! "$LDAPWHOAMI" "${verify_args[@]}" >/dev/null 2>&1; then
  echo "[FATAL] Verify bind failed for ${VERIFY_BIND_DN}" >&2
  exit 1
fi

result="$("$LDAPSEARCH" "${verify_args[@]}" -LLL -b "$USER_BASE_DN" "(uid=${USER_UID})" dn 2>/dev/null || true)"
if echo "$result" | grep -qi '^dn: '; then
  echo "[PASS] User ${USER_UID} created under ${USER_BASE_DN}"
  exit 0
fi

echo "[FAIL] User ${USER_UID} not found under ${USER_BASE_DN}" >&2
exit 1
