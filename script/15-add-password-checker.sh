#!/usr/bin/env bash
set -euo pipefail

# Ensure Symas tools are on PATH so ldapmodify/ldapsearch are found.
if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
  PATH="/opt/symas/bin:${PATH}"
fi

LDAPMODIFY="${LDAPMODIFY:-$(command -v ldapmodify || true)}"
LDAPSEARCH="${LDAPSEARCH:-$(command -v ldapsearch || true)}"

if [[ -z "$LDAPMODIFY" ]]; then
  echo "[FATAL] ldapmodify not found; ensure Symas clients are installed" >&2
  exit 1
fi
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

existing="$($LDAPSEARCH "${auth_args[@]}" -b "$POLICY_DN" -s base objectClass pwdCheckQuality)"

needs_class=0
if ! echo "$existing" | grep -qi '^objectClass: pwdPolicyChecker$'; then
  needs_class=1
fi

current_quality="$(echo "$existing" | awk -F': ' '/^pwdCheckQuality:/{print $2; exit}')"
needs_quality=0
if [[ "$current_quality" != "1" && "$current_quality" != "2" ]]; then
  needs_quality=1
fi

if [[ $needs_class -eq 0 && $needs_quality -eq 0 ]]; then
  echo "[INFO] Password checker already configured on $POLICY_DN"
  exit 0
fi

ldif_file="$(mktemp /tmp/add-password-checker.XXXXXX.ldif)"

{
  echo "dn: $POLICY_DN"
  echo "changetype: modify"
  if [[ $needs_class -eq 1 ]]; then
    echo "add: objectClass"
    echo "objectClass: pwdPolicyChecker"
  fi
  if [[ $needs_class -eq 1 && $needs_quality -eq 1 ]]; then
    echo "-"
  fi
  if [[ $needs_quality -eq 1 ]]; then
    echo "replace: pwdCheckQuality"
    echo "pwdCheckQuality: 1"
  fi
} > "$ldif_file"

$LDAPMODIFY "${auth_args[@]}" -f "$ldif_file"
rm -f "$ldif_file"

echo "[SUCCESS] Password checker enabled on $POLICY_DN"
