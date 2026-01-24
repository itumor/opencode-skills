#!/usr/bin/env bash
set -euo pipefail

ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  if [[ -f "$prof" ]]; then
    # shellcheck source=/etc/profile.d/symas_env.sh
    source "$prof"
  fi

  if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
    export PATH="/opt/symas/bin:${PATH}"
  fi
  if [[ ":${PATH}:" != *":/opt/symas/sbin:"* ]]; then
    export PATH="/opt/symas/sbin:${PATH}"
  fi

  if [[ -z "${LDAPCONF:-}" ]]; then
    export LDAPCONF="/opt/symas/etc/openldap/ldap.conf"
  fi
}

ensure_symas_env

if ! command -v ldapadd >/dev/null 2>&1; then
  echo "ldapadd not found in PATH. Ensure Symas OpenLDAP client tools are installed and PATH is set." >&2
  exit 1
fi

#create Users,Admins,Groups,Systems
cat > /tmp/create-top-ous.ldif << 'EOF'
dn: ou=Users,dc=eab,dc=bank,dc=local
objectClass: top
objectClass: organizationalUnit
ou: Users

dn: ou=Admins,dc=eab,dc=bank,dc=local
objectClass: top
objectClass: organizationalUnit
ou: Admins

dn: ou=Groups,dc=eab,dc=bank,dc=local
objectClass: top
objectClass: organizationalUnit
ou: Groups

dn: ou=Systems,dc=eab,dc=bank,dc=local
objectClass: top
objectClass: organizationalUnit
ou: Systems
EOF

ldapadd -x   -D "cn=admin,dc=eab,dc=bank,dc=local"   -W   -H ldap://localhost   -f /tmp/create-top-ous.ldif
