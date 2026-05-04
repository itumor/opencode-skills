#!/usr/bin/env bash
set -euo pipefail

# Ensure Symas tools are on PATH so ldapsearch is found.
if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
  PATH="/opt/symas/bin:${PATH}"
fi

LDAPSEARCH="${LDAPSEARCH:-$(command -v ldapsearch || true)}"
if [[ -z "$LDAPSEARCH" ]]; then
  echo "[FATAL] ldapsearch not found; ensure Symas clients are installed" >&2
  exit 1
fi

POLICY_DN="${POLICY_DN:-cn=default,ou=Policies,dc=eab,dc=bank,dc=local}"
LDAP_URI="${LDAP_URI:-ldap://localhost}"
LDAP_STARTTLS="${LDAP_STARTTLS:-1}"
LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"
BIND_DN="${BIND_DN:-cn=admin,dc=eab,dc=bank,dc=local}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXAMPLEDB_FILE="${EXAMPLEDB_FILE:-${ROOT_DIR}/Exampledb/exampledb.sh}"

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

BIND_PW="${BIND_PW:-$(read_exampledb_password "$EXAMPLEDB_FILE" || true)}"
if [[ -z "$BIND_PW" ]]; then
  echo "[FATAL] BIND_PW is empty and could not be auto-detected from ${EXAMPLEDB_FILE}. Set BIND_PW to run non-interactively." >&2
  exit 1
fi

auth_args=(-x -H "$LDAP_URI" -D "$BIND_DN")
if [[ "$LDAP_STARTTLS" == "1" ]]; then
  auth_args+=(-ZZ)
  export LDAPTLS_REQCERT
fi
auth_args+=(-w "$BIND_PW")

echo "[INFO] Checking password checker configuration on $POLICY_DN"
result="$($LDAPSEARCH "${auth_args[@]}" -b "$POLICY_DN" -s base objectClass pwdCheckQuality)"

if echo "$result" | grep -qi '^objectClass: pwdPolicyChecker$'; then
  echo "[PASS] objectClass pwdPolicyChecker present"
else
  echo "[FAIL] objectClass pwdPolicyChecker missing" >&2
  exit 1
fi

quality="$(echo "$result" | awk -F': ' '/^pwdCheckQuality:/{print $2; exit}')"
if [[ "$quality" == "1" || "$quality" == "2" ]]; then
  echo "[PASS] pwdCheckQuality set to $quality"
else
  echo "[FAIL] pwdCheckQuality not set (expected 1 or 2)" >&2
  exit 1
fi

echo "[SUCCESS] Password checker verification completed"
