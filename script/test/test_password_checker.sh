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
LDAP_URI="${LDAP_URI:-ldap:///}"
BIND_DN="${BIND_DN:-cn=admin,dc=eab,dc=bank,dc=local}"
BIND_PW="${BIND_PW:-}"

auth_args=(-x -H "$LDAP_URI" -D "$BIND_DN")
if [[ -n "$BIND_PW" ]]; then
  auth_args+=(-w "$BIND_PW")
else
  auth_args+=(-W)
fi

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
