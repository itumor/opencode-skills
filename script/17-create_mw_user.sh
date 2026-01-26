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

require_cmd() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "$bin not found in PATH. Ensure Symas OpenLDAP client tools are installed and PATH is set." >&2
    exit 1
  fi
}

require_cmd ldapadd
require_cmd ldapsearch
require_cmd ldapwhoami

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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

if [[ -z "$BIND_PW" ]]; then
  echo "Unable to read the example DB password from $EXAMPLEDB_FILE. Set BIND_PW to continue." >&2
  exit 1
fi

SERVICE_OU="${SERVICE_OU:-ou=ServiceAccounts,${BASE_DN}}"
MW_UID="${MW_UID:-mw}"
MW_DN="uid=${MW_UID},${SERVICE_OU}"

if [[ -z "${MW_PASSWORD:-}" ]]; then
  read -r -s -p "Enter password for ${MW_UID}: " MW_PASSWORD
  echo
else
  MW_PASSWORD="$MW_PASSWORD"
fi

if [[ -z "$MW_PASSWORD" ]]; then
  echo "MW_PASSWORD is empty; aborting." >&2
  exit 1
fi

bind_ok() {
  ldapwhoami -x -D "$BIND_DN" -w "$BIND_PW" -H "$LDAP_URI" >/dev/null 2>&1
}

entry_exists() {
  local dn="$1"
  ldapsearch -x -D "$BIND_DN" -w "$BIND_PW" -H "$LDAP_URI" -b "$dn" -s base "(objectClass=*)" dn >/dev/null 2>&1
}

if ! bind_ok; then
  echo "Bind failed for ${BIND_DN}. Verify credentials (BIND_DN/BIND_PW)." >&2
  exit 1
fi

if ! entry_exists "$SERVICE_OU"; then
  ldapadd -x -D "$BIND_DN" -w "$BIND_PW" -H "$LDAP_URI" <<EOF_LDIF
dn: ${SERVICE_OU}
objectClass: top
objectClass: organizationalUnit
ou: ServiceAccounts
description: Service accounts
EOF_LDIF
fi

if entry_exists "$MW_DN"; then
  echo "${MW_DN} already exists; nothing to do."
  exit 0
fi

ldapadd -x -D "$BIND_DN" -w "$BIND_PW" -H "$LDAP_URI" <<EOF_LDIF
dn: ${MW_DN}
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: ${MW_UID}
cn: ${MW_UID}
sn: ${MW_UID}
userPassword: ${MW_PASSWORD}
description: MW service account
EOF_LDIF

echo "Created ${MW_DN}"
