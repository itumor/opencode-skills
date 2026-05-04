#!/bin/bash
set -euo pipefail

# Ensure Symas tools are on PATH so ldappasswd is found.
if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
  PATH="/opt/symas/bin:${PATH}"
fi

# =========================
# VARIABLES
# =========================
USER_DN="${USER_DN:-uid=mwuser1,ou=Users,dc=eab,dc=bank,dc=local}"
BIND_DN="${BIND_DN:-$USER_DN}"
# Default aligns with script/19-create-user-using-mw-user.sh
BIND_PW="${BIND_PW:-${USER_PASSWORD:-ChangeMe123!}}"

WEAK_PASSWORD="${WEAK_PASSWORD:-test2}"
STRONG_PASSWORD="${STRONG_PASSWORD:-Test@1234225!}"

LDAP_URI="${LDAP_URI:-ldap://localhost}"
LDAP_STARTTLS="${LDAP_STARTTLS:-1}"
LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

echo "======================================"
echo "PPM Password Complexity Verification"
echo "User DN: $USER_DN"
echo "======================================"
echo

require_cmd() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "$bin not found in PATH. Ensure Symas OpenLDAP client tools are installed and PATH is set." >&2
    exit 1
  fi
}

require_cmd ldapsearch
require_cmd ldappasswd

if [[ -z "$BIND_PW" ]]; then
  echo "BIND_PW is empty; set BIND_PW (or USER_PASSWORD) to run non-interactively." >&2
  exit 1
fi

# Skip if PPM integration is not active.
if ! ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -LLL '(olcOverlay=ppolicy)' olcPPolicyCheckModule 2>/dev/null | awk -F': ' '/^olcPPolicyCheckModule:/{print $2; exit}' | grep -qx 'ppm'; then
  echo "[SKIP] PPM is not enabled (olcPPolicyCheckModule != ppm)."
  exit 0
fi

# =========================
# AUTH
# =========================
auth_args=(-x -H "$LDAP_URI" -D "$BIND_DN")
if [[ "$LDAP_STARTTLS" == "1" ]]; then
    auth_args+=(-ZZ)
    export LDAPTLS_REQCERT
fi
auth_args+=(-w "$BIND_PW")

# =========================
# TEST 1: WEAK PASSWORD
# =========================
echo "[TEST 1] Trying WEAK password: '$WEAK_PASSWORD'"
if ldappasswd "${auth_args[@]}" \
    -s "$WEAK_PASSWORD" \
    "$USER_DN" 2>/tmp/weak_test.err; then
    echo "FAIL: Weak password was ACCEPTED (unexpected)"
else
    echo "PASS: Weak password was REJECTED (expected)"
    cat /tmp/weak_test.err
fi

echo
echo "--------------------------------------"
echo

# =========================
# TEST 2: STRONG PASSWORD
# =========================
echo "[TEST 2] Trying STRONG password: '$STRONG_PASSWORD'"
if ldappasswd "${auth_args[@]}" \
    -s "$STRONG_PASSWORD" \
    "$USER_DN" 2>/tmp/strong_test.err; then
    echo "PASS: Strong password was ACCEPTED (expected)"
else
    echo "FAIL: Strong password was REJECTED (unexpected)"
    cat /tmp/strong_test.err
fi

echo
echo "======================================"
echo "Verification completed"
echo "======================================"
