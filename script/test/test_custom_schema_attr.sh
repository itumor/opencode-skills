#!/usr/bin/env bash
set -euo pipefail

if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
  PATH="/opt/symas/bin:${PATH}"
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Run as root (required for ldapi:/// SASL/EXTERNAL)" >&2
  exit 1
fi

require_cmd() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[FATAL] $bin not found in PATH" >&2
    exit 1
  fi
}
require_cmd ldapadd
require_cmd ldapsearch

BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
USER_UID="schema-test-$(date +%Y%m%d%H%M%S)"
USER_DN="uid=${USER_UID},ou=Users,${BASE_DN}"

cat > /tmp/test-bank-schema-attr.ldif << EOF
dn: ${USER_DN}
objectClass: inetOrgPerson
objectClass: bankUserExtension
uid: ${USER_UID}
cn: Test User
sn: User
employeeNumber: 12345
userPassword: Password1!
memorableAnswer: answer1
memorableQuestion: What is your favorite color?
userisactive: TRUE
cif: CIF123456
activationdatetime: 20260119120000Z
EOF

if ldapsearch -Y EXTERNAL -H ldapi:/// -b "${USER_DN}" -s base "(objectClass=*)" dn >/dev/null 2>&1; then
  echo "[WARN] ${USER_DN} already exists; skipping add"
  exit 0
fi

ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/test-bank-schema-attr.ldif
