#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Must be run as root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLEDB_FILE="${SCRIPT_DIR}/Exampledb/exampledb.sh"

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

if [[ -z "${BIND_PW}" ]]; then
  echo "[FATAL] No bind password available. Set BIND_PW or ensure ${EXAMPLEDB_FILE} contains rootpw." >&2
  exit 1
fi

LDAPADD="${LDAPADD:-/opt/symas/bin/ldapadd}"
if [[ ! -x "$LDAPADD" ]]; then
  echo "[FATAL] ldapadd not found at ${LDAPADD}; ensure Symas OpenLDAP is installed" >&2
  exit 1
fi

cat > /tmp/ppolicy-container.ldif << EOF

dn: ou=Policies,${BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: Policies
description: Password Policies


dn: cn=default,ou=Policies,${BASE_DN}
objectClass: pwdPolicy
objectClass: person
objectClass: top
cn: default
sn: default
pwdAttribute: userPassword
pwdMaxAge: 7776000
pwdExpireWarning: 604800
pwdInHistory: 5
pwdCheckQuality: 1
pwdMinLength: 8
pwdMaxFailure: 5
pwdLockout: TRUE
pwdLockoutDuration: 1800
pwdGraceAuthNLimit: 1000
pwdFailureCountInterval: 0
pwdMustChange: FALSE
pwdAllowUserChange: TRUE
pwdSafeModify: FALSE

EOF

"$LDAPADD" -x -D "$BIND_DN" -w "$BIND_PW" -H "$LDAP_URI" -f /tmp/ppolicy-container.ldif
