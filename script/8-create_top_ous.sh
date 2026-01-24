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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLEDB_FILE="${SCRIPT_DIR}/Exampledb/exampledb.sh"
SLAPD_CONF="/opt/symas/etc/openldap/slapd.conf"
CONFIG_D="/opt/symas/etc/openldap/slapd.d"

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

BIND_DN="cn=admin,dc=eab,dc=bank,dc=local"
BASE_DN="dc=eab,dc=bank,dc=local"
LDAP_URI="ldap://localhost"
BIND_PW="$(read_exampledb_password "$EXAMPLEDB_FILE" || true)"

if [[ -z "${BIND_PW}" ]]; then
  echo "Unable to read the example DB password from $EXAMPLEDB_FILE." >&2
  exit 1
fi

bind_ok() {
  ldapwhoami -x -D "$BIND_DN" -w "$BIND_PW" -H "$LDAP_URI" >/dev/null 2>&1
}

read_config_rootdn() {
  local out rc
  set +e
  out="$(ldapsearch -Y EXTERNAL -H ldapi:/// -b "cn=config" "(olcSuffix=${BASE_DN})" olcRootDN 2>/dev/null)"
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || return 1
  echo "$out" | awk '/^olcRootDN:/ {print $2; exit}'
}

read_slapd_rootdn() {
  local conf="$1"
  [[ -f "$conf" ]] || return 1
  awk '
    /^[[:space:]]*#/ {next}
    tolower($1)=="rootdn" {
      gsub(/"/, "", $2)
      print $2
      exit
    }
  ' "$conf"
}

detect_bind_dn() {
  local dn=""
  dn="$(read_config_rootdn || true)"
  if [[ -n "$dn" ]]; then
    echo "$dn"
    return 0
  fi
  dn="$(read_slapd_rootdn "$SLAPD_CONF" || true)"
  if [[ -n "$dn" ]]; then
    echo "$dn"
    return 0
  fi
  return 1
}

CONFIG_BIND_DN="$(detect_bind_dn || true)"
if [[ -n "$CONFIG_BIND_DN" ]]; then
  BIND_DN="$CONFIG_BIND_DN"
fi

restart_slapd() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "slapd.service"; then
      systemctl restart slapd
      return 0
    fi
    if systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "symas-openldap-servers.service"; then
      systemctl restart symas-openldap-servers
      return 0
    fi
  fi
  return 1
}

stop_slapd() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "slapd.service"; then
      systemctl stop slapd
      return 0
    fi
    if systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "symas-openldap-servers.service"; then
      systemctl stop symas-openldap-servers
      return 0
    fi
  fi
  return 1
}

ensure_config_access() {
  local cfg_ldif="${CONFIG_D}/cn=config/olcDatabase={0}config.ldif"
  local tmp=""
  if [[ ! -f "$cfg_ldif" ]]; then
    return 1
  fi
  tmp="$(mktemp)"
  awk '
    BEGIN{replaced=0}
    /^olcAccess:/ {
      print "olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * none"
      replaced=1
      next
    }
    {print}
    END{exit replaced?0:1}
  ' "$cfg_ldif" > "$tmp" || { rm -f "$tmp"; return 1; }
  cp -p "$cfg_ldif" "${cfg_ldif}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$tmp" "$cfg_ldif"
  rm -f "$tmp"
  return 0
}

update_slapd_conf_rootpw() {
  local conf="$1"
  local tmp=""
  [[ -f "$conf" ]] || return 1
  tmp="$(mktemp)"
  awk -v pw="$BIND_PW" '
    BEGIN{updated=0}
    /^[[:space:]]*#/ {print; next}
    tolower($1)=="rootpw" {print "rootpw      " pw; updated=1; next}
    {print}
    END{exit updated?0:1}
  ' "$conf" > "$tmp" || { rm -f "$tmp"; return 1; }
  cp -p "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$tmp" "$conf"
  rm -f "$tmp"
}

reset_admin_password() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Bind failed and password reset requires root. Re-run with sudo." >&2
    exit 1
  fi
  require_cmd ldapmodify

  local db_dn=""
  local out rc
  set +e
  out="$(ldapsearch -Y EXTERNAL -H ldapi:/// -b "cn=config" "(olcSuffix=${BASE_DN})" dn 2>/dev/null)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    db_dn="$(echo "$out" | awk '/^dn: / {print substr($0, 5); exit}')"
  fi

  if [[ -n "$db_dn" ]]; then
    if ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: ${db_dn}
changetype: modify
replace: olcRootPW
olcRootPW: ${BIND_PW}
EOF
    then
      return 0
    fi

    local cfg_ldif="${CONFIG_D}/cn=config/olcDatabase={0}config.ldif"
    local stopped=0
    if [[ -f "$cfg_ldif" ]]; then
      if stop_slapd; then
        stopped=1
      fi
    fi
    if ensure_config_access; then
      if ! restart_slapd; then
        echo "Updated cn=config ACL but could not restart slapd automatically. Restart it manually." >&2
      fi
      if ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: ${db_dn}
changetype: modify
replace: olcRootPW
olcRootPW: ${BIND_PW}
EOF
      then
        return 0
      fi
    else
      if [[ "$stopped" -eq 1 ]]; then
        restart_slapd || true
      fi
    fi
  fi

  if update_slapd_conf_rootpw "$SLAPD_CONF"; then
    if ! restart_slapd; then
      echo "Updated ${SLAPD_CONF} but could not restart slapd automatically. Restart it manually." >&2
    fi
    return 0
  fi

  echo "Could not locate cn=config entry for ${BASE_DN} and failed to update ${SLAPD_CONF}." >&2
  exit 1
}

if ! bind_ok; then
  echo "Bind failed for ${BIND_DN}; resetting to the example DB password." >&2
  reset_admin_password
fi

if ! bind_ok; then
  echo "Bind still failing after reset; verify ${BIND_DN} and password." >&2
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

ldapadd -x -D "${BIND_DN}" -w "${BIND_PW}" -H "${LDAP_URI}" -f /tmp/create-top-ous.ldif
