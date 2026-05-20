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
LDAP_URI="${LDAP_URI:-ldap://localhost}"
ADMIN_DN="${ADMIN_DN:-cn=admin,${BASE_DN}}"
ADMIN_PW="${ADMIN_PW:-}"
LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"
USER_UID="schema-test-$(date +%Y%m%d%H%M%S)"
USER_DN="uid=${USER_UID},ou=Users,${BASE_DN}"

detect_example_password() {
  local file pw
  for file in /opt/symas/share/symas/exampledb.sh "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Exampledb/exampledb.sh"; do
    if [[ -f "$file" ]]; then
      pw=$(awk 'tolower($1) ~ /^(rootpw|olcrootpw:)$/ {print $2; exit}' "$file")
      if [[ -n "$pw" ]]; then
        echo "$pw"
        return 0
      fi
    fi
  done
  return 1
}

if [[ -z "$ADMIN_PW" ]]; then
  ADMIN_PW="$(detect_example_password || true)"
fi
[[ -n "$ADMIN_PW" ]] || { echo "[FATAL] ADMIN_PW not set and could not detect example password" >&2; exit 1; }
export LDAPTLS_REQCERT

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

if ldapsearch -x -ZZ -H "$LDAP_URI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "${USER_DN}" -s base "(objectClass=*)" dn >/dev/null 2>&1; then
  echo "[WARN] ${USER_DN} already exists; skipping add"
else
  ldapadd -x -ZZ -H "$LDAP_URI" -D "$ADMIN_DN" -w "$ADMIN_PW" -f /tmp/test-bank-schema-attr.ldif
fi

# Verify the entry exists and custom attrs are readable
result=$(ldapsearch -x -ZZ -H "$LDAP_URI" -D "$ADMIN_DN" -w "$ADMIN_PW" \
  -b "ou=Users,${BASE_DN}" "(uid=${USER_UID})" userisactive memorableanswer cif 2>/dev/null)

if echo "$result" | grep -q "userisactive: TRUE"; then
  echo "[PASS] Custom attribute userisactive readable"
else
  echo "[FAIL] Custom attribute userisactive not found on ${USER_DN}" >&2
  exit 1
fi

if echo "$result" | grep -q "memorableanswer:"; then
  echo "[PASS] Custom attribute memorableanswer readable"
else
  echo "[FAIL] Custom attribute memorableanswer not found on ${USER_DN}" >&2
  exit 1
fi

if echo "$result" | grep -q "cif:"; then
  echo "[PASS] Custom attribute cif readable"
else
  echo "[FAIL] Custom attribute cif not found on ${USER_DN}" >&2
  exit 1
fi

# Cleanup test entry
ldapdelete -x -ZZ -H "$LDAP_URI" -D "$ADMIN_DN" -w "$ADMIN_PW" "${USER_DN}" >/dev/null 2>&1 || true

echo "[SUCCESS] Custom schema attribute verification completed"
