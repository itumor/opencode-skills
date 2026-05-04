#!/usr/bin/env bash
set -euo pipefail

# Ensure Symas tools are on PATH so ldapadd/ldapsearch/ldapwhoami are found.
if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
  PATH="/opt/symas/bin:${PATH}"
fi

DRY_RUN="${DRY_RUN:-0}"

LDAPADD="${LDAPADD:-$(command -v ldapadd || true)}"
LDAPSEARCH="${LDAPSEARCH:-$(command -v ldapsearch || true)}"
LDAPWHOAMI="${LDAPWHOAMI:-$(command -v ldapwhoami || true)}"

if [[ "$DRY_RUN" != "1" ]]; then
  if [[ -z "$LDAPADD" ]]; then
    echo "[FATAL] ldapadd not found; ensure Symas clients are installed" >&2
    exit 1
  fi
  if [[ -z "$LDAPSEARCH" ]]; then
    echo "[FATAL] ldapsearch not found; ensure Symas clients are installed" >&2
    exit 1
  fi
  if [[ -z "$LDAPWHOAMI" ]]; then
    echo "[FATAL] ldapwhoami not found; ensure Symas clients are installed" >&2
    exit 1
  fi
fi

LDAP_URI="${LDAP_URI:-ldap://localhost}"
USE_STARTTLS="${USE_STARTTLS:-0}"
LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"
MW_BIND_DN="${MW_BIND_DN:-uid=mw,ou=ServiceAccounts,ou=Systems,dc=eab,dc=bank,dc=local}"
MW_BIND_PW="${MW_BIND_PW:-ChangeMe123!}"

USER_BASE_DN="${USER_BASE_DN:-ou=Users,dc=eab,dc=bank,dc=local}"
USER_UID="${USER_UID:-mwuser1}"
USER_CN="${USER_CN:-$USER_UID}"
USER_SN="${USER_SN:-User}"
USER_GIVENNAME="${USER_GIVENNAME:-MW}"
USER_MAIL="${USER_MAIL:-}"
USER_PASSWORD_HASH="${USER_PASSWORD_HASH:-}"
USER_PASSWORD="${USER_PASSWORD:-ChangeMe123!}"
ALLOW_EXISTING="${ALLOW_EXISTING:-0}"
INCLUDE_BANK_EXTENSION="${INCLUDE_BANK_EXTENSION:-0}"
USER_IS_ACTIVE="${USER_IS_ACTIVE:-TRUE}"
USER_CIF="${USER_CIF:-}"
USER_ACTIVATION_DATETIME="${USER_ACTIVATION_DATETIME:-}"
USER_MEMORABLE_QUESTION="${USER_MEMORABLE_QUESTION:-}"
USER_MEMORABLE_ANSWER="${USER_MEMORABLE_ANSWER:-}"

if [[ -z "$USER_MAIL" ]]; then
  USER_MAIL="${USER_UID}@eab.bank.local"
fi

auth_args=(-x -H "$LDAP_URI" -D "$MW_BIND_DN")
if [[ -z "$MW_BIND_PW" ]]; then
  echo "[FATAL] MW_BIND_PW is empty. Set MW_BIND_PW (default expected: ChangeMe123!)." >&2
  exit 1
fi
if [[ "$USE_STARTTLS" == "1" ]]; then
  auth_args+=(-ZZ)
  export LDAPTLS_REQCERT
fi
auth_args+=(-w "$MW_BIND_PW")

if [[ "$DRY_RUN" != "1" ]]; then
  if ! "$LDAPWHOAMI" "${auth_args[@]}" >/dev/null 2>&1; then
    echo "[FATAL] Bind failed for ${MW_BIND_DN}. Check MW_BIND_DN/MW_BIND_PW." >&2
    exit 1
  fi

  existing="$("$LDAPSEARCH" "${auth_args[@]}" -LLL -b "$USER_BASE_DN" "(uid=${USER_UID})" dn 2>/dev/null || true)"
  if echo "$existing" | grep -qi '^dn: '; then
    if [[ "$ALLOW_EXISTING" == "1" ]]; then
      echo "[INFO] User ${USER_UID} already exists under ${USER_BASE_DN}"
      exit 0
    fi
    echo "[FATAL] User ${USER_UID} already exists under ${USER_BASE_DN}" >&2
    exit 1
  fi
fi

USER_DN="uid=${USER_UID},${USER_BASE_DN}"
ldif_file="$(mktemp /tmp/create-mw-user.XXXXXX.ldif)"

{
  echo "dn: ${USER_DN}"
  echo "objectClass: top"
  echo "objectClass: inetOrgPerson"
  if [[ "$INCLUDE_BANK_EXTENSION" == "1" ]]; then
    echo "objectClass: bankUserExtension"
  fi
  echo "uid: ${USER_UID}"
  echo "cn: ${USER_CN}"
  echo "sn: ${USER_SN}"
  echo "givenName: ${USER_GIVENNAME}"
  echo "mail: ${USER_MAIL}"
  if [[ -n "$USER_PASSWORD_HASH" ]]; then
    echo "userPassword: ${USER_PASSWORD_HASH}"
  else
    echo "userPassword: ${USER_PASSWORD}"
  fi
  if [[ "$INCLUDE_BANK_EXTENSION" == "1" ]]; then
    echo "userisactive: ${USER_IS_ACTIVE}"
    if [[ -n "$USER_CIF" ]]; then
      echo "cif: ${USER_CIF}"
    fi
    if [[ -n "$USER_ACTIVATION_DATETIME" ]]; then
      echo "activationdatetime: ${USER_ACTIVATION_DATETIME}"
    fi
    if [[ -n "$USER_MEMORABLE_QUESTION" ]]; then
      echo "memorableQuestion: ${USER_MEMORABLE_QUESTION}"
    fi
    if [[ -n "$USER_MEMORABLE_ANSWER" ]]; then
      echo "memorableAnswer: ${USER_MEMORABLE_ANSWER}"
    fi
  fi
} > "$ldif_file"

if [[ "$DRY_RUN" == "1" ]]; then
  cat "$ldif_file"
  rm -f "$ldif_file"
  exit 0
fi

"$LDAPADD" "${auth_args[@]}" -f "$ldif_file"
rm -f "$ldif_file"

echo "[SUCCESS] Created ${USER_DN} using ${MW_BIND_DN}"
