#!/usr/bin/env bash
set -euo pipefail

# Ensure Symas tools are on PATH so ldapadd/ldapmodify/ldapsearch are found.
if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
  PATH="/opt/symas/bin:${PATH}"
fi

LDAPADD="${LDAPADD:-$(command -v ldapadd || true)}"
LDAPMODIFY="${LDAPMODIFY:-$(command -v ldapmodify || true)}"
LDAPSEARCH="${LDAPSEARCH:-$(command -v ldapsearch || true)}"

if [[ -z "$LDAPADD" ]]; then
  echo "[FATAL] ldapadd not found; ensure Symas clients are installed" >&2
  exit 1
fi
if [[ -z "$LDAPMODIFY" ]]; then
  echo "[FATAL] ldapmodify not found; ensure Symas clients are installed" >&2
  exit 1
fi
if [[ -z "$LDAPSEARCH" ]]; then
  echo "[FATAL] ldapsearch not found; ensure Symas clients are installed" >&2
  exit 1
fi

POLICY_DN="${POLICY_DN:-cn=service-account,ou=Policies,dc=eab,dc=bank,dc=local}"
POLICY_CN="${POLICY_CN:-service-account}"
LDAP_URI="${LDAP_URI:-ldap://localhost}"
BIND_DN="${BIND_DN:-cn=admin,dc=eab,dc=bank,dc=local}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLEDB_FILE="${EXAMPLEDB_FILE:-${SCRIPT_DIR}/Exampledb/exampledb.sh}"

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
auth_args+=(-w "$BIND_PW")

if $LDAPSEARCH "${auth_args[@]}" -b "$POLICY_DN" -s base dn >/dev/null 2>&1; then
  existing="$($LDAPSEARCH "${auth_args[@]}" -b "$POLICY_DN" -s base objectClass pwdMaxAge pwdExpireWarning)"

  needs_class=0
  if ! echo "$existing" | grep -qi '^objectClass: pwdPolicy$'; then
    needs_class=1
  fi

  current_max_age="$(echo "$existing" | awk -F': ' '/^pwdMaxAge:/{print $2; exit}')"
  needs_max_age=0
  if [[ "$current_max_age" != "0" ]]; then
    needs_max_age=1
  fi

  current_warning="$(echo "$existing" | awk -F': ' '/^pwdExpireWarning:/{print $2; exit}')"
  needs_warning=0
  if [[ "$current_warning" != "0" ]]; then
    needs_warning=1
  fi

  if [[ $needs_class -eq 0 && $needs_max_age -eq 0 && $needs_warning -eq 0 ]]; then
    echo "[INFO] Service account policy already configured on $POLICY_DN"
    exit 0
  fi

  ldif_file="$(mktemp /tmp/service-account-policy-update.XXXXXX.ldif)"
  {
    echo "dn: $POLICY_DN"
    echo "changetype: modify"
    if [[ $needs_class -eq 1 ]]; then
      echo "add: objectClass"
      echo "objectClass: pwdPolicy"
    fi
    if [[ $needs_class -eq 1 && ( $needs_max_age -eq 1 || $needs_warning -eq 1 ) ]]; then
      echo "-"
    fi
    if [[ $needs_max_age -eq 1 ]]; then
      echo "replace: pwdMaxAge"
      echo "pwdMaxAge: 0"
    fi
    if [[ $needs_max_age -eq 1 && $needs_warning -eq 1 ]]; then
      echo "-"
    fi
    if [[ $needs_warning -eq 1 ]]; then
      echo "replace: pwdExpireWarning"
      echo "pwdExpireWarning: 0"
    fi
  } > "$ldif_file"

  $LDAPMODIFY "${auth_args[@]}" -f "$ldif_file"
  rm -f "$ldif_file"
  echo "[SUCCESS] Updated service account policy on $POLICY_DN"
  exit 0
fi

ldif_file="$(mktemp /tmp/service-account-policy.XXXXXX.ldif)"
cat > "$ldif_file" <<EOF
dn: $POLICY_DN
objectClass: top
objectClass: person
objectClass: pwdPolicy
cn: $POLICY_CN
sn: $POLICY_CN
pwdAttribute: userPassword
pwdMaxAge: 0
pwdExpireWarning: 0
pwdInHistory: 5
pwdCheckQuality: 1
pwdMinLength: 8
pwdMaxFailure: 5
pwdLockout: TRUE
pwdLockoutDuration: 1800
pwdGraceAuthNLimit: 3
pwdFailureCountInterval: 0
pwdMustChange: FALSE
pwdAllowUserChange: TRUE
pwdSafeModify: FALSE
EOF

$LDAPADD "${auth_args[@]}" -f "$ldif_file"
rm -f "$ldif_file"
echo "[SUCCESS] Created service account policy on $POLICY_DN"
