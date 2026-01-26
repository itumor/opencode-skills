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

POLICY_DN="${POLICY_DN:-cn=service-account,ou=Policies,dc=eab,dc=bank,dc=local}"
LDAP_URI="${LDAP_URI:-ldap:///}"
BIND_DN="${BIND_DN:-cn=admin,dc=eab,dc=bank,dc=local}"
BIND_PW="${BIND_PW:-}"

auth_args=(-x -H "$LDAP_URI" -D "$BIND_DN")
if [[ -n "$BIND_PW" ]]; then
  auth_args+=(-w "$BIND_PW")
else
  auth_args+=(-W)
fi

echo "[INFO] Checking service account policy on $POLICY_DN"
result="$($LDAPSEARCH "${auth_args[@]}" -b "$POLICY_DN" -s base objectClass pwdMaxAge)"

if echo "$result" | grep -qi '^objectClass: pwdPolicy$'; then
  echo "[PASS] objectClass pwdPolicy present"
else
  echo "[FAIL] objectClass pwdPolicy missing" >&2
  exit 1
fi

max_age="$(echo "$result" | awk -F': ' '/^pwdMaxAge:/{print $2; exit}')"
if [[ "$max_age" == "0" ]]; then
  echo "[PASS] pwdMaxAge set to 0 (never expire)"
else
  echo "[FAIL] pwdMaxAge is not 0 (found: ${max_age:-empty})" >&2
  exit 1
fi

echo "[SUCCESS] Service account policy verification completed"
