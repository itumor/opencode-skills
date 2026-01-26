#!/bin/bash
set -euo pipefail

# Ensure Symas tools are on PATH so ldappasswd is found.
if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
  PATH="/opt/symas/bin:${PATH}"
fi

# =========================
# VARIABLES
# =========================
USER_DN="${USER_DN:-uid=test4,ou=Users,dc=eab,dc=bank,dc=local}"
BIND_DN="${BIND_DN:-$USER_DN}"
BIND_PW="${BIND_PW:-}"

WEAK_PASSWORD="${WEAK_PASSWORD:-test2}"
STRONG_PASSWORD="${STRONG_PASSWORD:-Test@1234225!}"

LDAP_URI="${LDAP_URI:-ldap:///}"

echo "======================================"
echo "PPM Password Complexity Verification"
echo "User DN: $USER_DN"
echo "======================================"
echo

# =========================
# AUTH
# =========================
auth_args=(-x -H "$LDAP_URI" -D "$BIND_DN")
if [[ -n "$BIND_PW" ]]; then
    auth_args+=(-w "$BIND_PW")
else
    auth_args+=(-W)
fi

# =========================
# TEST 1: WEAK PASSWORD
# =========================
echo "[TEST 1] Trying WEAK password: '$WEAK_PASSWORD'"
if ldappasswd "${auth_args[@]}" \
    -s "$WEAK_PASSWORD" \
    "$USER_DN" 2>/tmp/weak_test.err; then
    echo "❌ ERROR: Weak password was ACCEPTED (this is BAD)"
else
    echo "✅ PASS: Weak password was REJECTED (expected)"
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
    echo "✅ PASS: Strong password was ACCEPTED (expected)"
else
    echo "❌ ERROR: Strong password was REJECTED (this is BAD)"
    cat /tmp/strong_test.err
fi

echo
echo "======================================"
echo "Verification completed"
echo "======================================"
