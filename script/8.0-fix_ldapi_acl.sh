#!/usr/bin/env bash
# Fix cn=config ACL for SASL/EXTERNAL manage access and reset olcRootPW.
# - Detect the active ldapi socket and query cn=config ACLs.
# - If manage access for peercred root is not the first rule, stop slapd, patch cn=config, restart, and re-check.
# - Reset the database olcRootPW (default dc=eab,dc=bank,dc=local) to the provided password.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASSWORD="${PASSWORD:-}"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
LDAPI_SOCKET="${LDAPI_SOCKET:-/var/symas/run/ldapi}"

log()  { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*"; }
err()  { echo -e "[FAIL] $*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run as root (sudo -i or sudo ./$(basename "$0"))."
  fi
}

ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  if [[ -f "$prof" ]]; then
    # shellcheck source=/etc/profile.d/symas_env.sh
    source "$prof"
  fi
  [[ ":${PATH}:" == *":/opt/symas/bin:"* ]] || PATH="/opt/symas/bin:${PATH}"
  [[ ":${PATH}:" == *":/opt/symas/sbin:"* ]] || PATH="/opt/symas/sbin:${PATH}"
  export PATH
  if [[ -z "${LDAPCONF:-}" ]]; then
    export LDAPCONF="/opt/symas/etc/openldap/ldap.conf"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }
require_cmd() { have "$1" || err "$1 not found in PATH"; }

detect_unit() {
  local unit=""
  if systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "slapd.service"; then
    unit="slapd"
  elif systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "symas-openldap-servers.service"; then
    unit="symas-openldap-servers"
  else
    if systemctl list-units --type=service --all --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "slapd.service"; then
      unit="slapd"
    elif systemctl list-units --type=service --all --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "symas-openldap-servers.service"; then
      unit="symas-openldap-servers"
    fi
  fi
  echo "$unit"
}

stop_slapd() {
  local unit="$1"
  if [[ -n "$unit" ]]; then
    systemctl stop "$unit"
    return
  fi
  err "Could not find slapd systemd unit; stop it manually and re-run."
}

start_slapd() {
  local unit="$1"
  if [[ -n "$unit" ]]; then
    systemctl start "$unit"
    return
  fi
  err "Could not find slapd systemd unit; start it manually and re-run."
}

encode_ldapi_uri() {
  local sock="$1"
  [[ -S "$sock" ]] || err "Socket $sock not found"
  local enc
  enc=$(printf '%s' "$sock" | sed 's,/,%2F,g')
  echo "ldapi://${enc}"
}

detect_ldapi_socket() {
  local candidate=""
  if [[ -n "$LDAPI_SOCKET" ]]; then
    echo "$LDAPI_SOCKET"
    return 0
  fi

  # Try to extract an explicit ldapi socket from slapd's -h argument (often encoded).
  # Example: -h "ldap:/// ldapi://%2Fvar%2Frun%2Fslapd%2Fldapi"
  candidate=$(
    ps -ef 2>/dev/null | awk '
      /slapd/ && !/awk/ && !/grep/ {
        for (i=1;i<=NF;i++) {
          if ($i=="-h") {
            h=$(i+1)
            # If -h is quoted, ps typically preserves it as one field; if not, it may split.
            # We only need the first token that contains ldapi://.
            if (h ~ /ldapi:\/\//) { print h; exit }
          }
          if ($i ~ /^ldapi:\/\//) { print $i; exit }
        }
      }
    ' | tr -d '"'
  )
  if [[ -n "$candidate" ]]; then
    # Prefer explicit socket path if present in the URI.
    if [[ "$candidate" =~ ^ldapi://%2F ]]; then
      # Decode minimal %2F back to / for filesystem existence checks.
      candidate=$(printf '%s' "$candidate" | sed 's/^ldapi:\/\///' | sed 's/%2F/\//g')
      if [[ -S "$candidate" ]]; then
        echo "$candidate"
        return 0
      fi
    fi
    if [[ "$candidate" =~ ^ldapi:/// ]]; then
      # Ambiguous compile-time default; keep searching for the actual socket on disk.
      candidate=""
    fi
  fi

  if have ss; then
    candidate=$(ss -xl 2>/dev/null | awk '/ldapi|slapd/ && $NF ~ /^\// {print $NF; exit}')
  fi
  if [[ -z "$candidate" ]]; then
    local defaults=(
      "/var/run/slapd/ldapi"
      "/run/slapd/ldapi"
      "/run/openldap/ldapi"
      "/var/run/openldap/ldapi"
      "/var/run/ldap/ldapi"
      "/opt/symas/var/run/ldapi"
      "/var/lib/ldap/run/ldapi"
    )
    for d in "${defaults[@]}"; do
      if [[ -S "$d" ]]; then
        candidate="$d"
        break
      fi
    done
  fi
  if [[ -z "$candidate" ]] && have find; then
    # Last resort: search common runtime dirs for a unix socket named ldapi*.
    candidate=$(
      find /run /var/run /opt/symas/var/run -maxdepth 3 -type s -name 'ldapi*' 2>/dev/null | head -n 1 || true
    )
  fi
  [[ -n "$candidate" ]] || err "Could not detect ldapi socket. Set LDAPI_SOCKET=/path/to/ldapi (e.g. /var/run/slapd/ldapi) and re-run."
  echo "$candidate"
}

first_acl_is_manage() {
  local uri="$1"
  local first
  # Disable LDIF line wrapping so the ACL appears on a single line for matching.
  first=$(ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$uri" -b 'cn=config' -LLL '(olcDatabase=config)' olcAccess 2>/dev/null | awk '/^olcAccess:/ {print; exit}')
  [[ -n "$first" ]] || return 1
  [[ "$first" =~ dn\.exact=gidNumber=0\+uidNumber=0,cn=peercred,cn=external,cn=auth[[:space:]]+manage ]] && return 0
  return 1
}

detect_config_db_file() {
  local cfg="$1"
  local dir="${cfg}/cn=config"
  local file=""
  [[ -d "$dir" ]] || err "Missing cn=config directory under ${cfg}"

  # Symas/OpenLDAP may write either olcDatabase={0}config.ldif or
  # olcDatabase=config.ldif depending on how cn=config was initialized.
  file=$(find "$dir" -maxdepth 1 -type f -name 'olcDatabase*config.ldif' 2>/dev/null | sort | head -n 1 || true)
  if [[ -z "$file" ]]; then
    file=$(grep -RIl '^olcDatabase: .*config$' "$dir" 2>/dev/null | sort | head -n 1 || true)
  fi
  [[ -n "$file" ]] || err "Could not find config database LDIF under ${dir}"
  echo "$file"
}

rewrite_acl_file() {
  local file="$1"
  [[ -f "$file" ]] || err "Missing $file"
  local tmp
  tmp=$(mktemp)
  awk '
    function print_manage() {
      if (!inserted) {
        print "olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * none"
        inserted=1
      }
    }
    BEGIN {inserted=0; idx=0}
    /^olcAccess:/ {
      line=$0
      sub(/^olcAccess:[[:space:]]*{[0-9]+}[[:space:]]*/,"",line)
      sub(/^olcAccess:[[:space:]]*/,"",line)
      if (line ~ /^to[[:space:]]+\\*[[:space:]]+by[[:space:]]+dn\\.exact=gidNumber=0\\+uidNumber=0,cn=peercred,cn=external,cn=auth[[:space:]]+manage[[:space:]]+by[[:space:]]+\\*[[:space:]]+none$/) {
        next
      }
      if (!inserted) { print_manage() }
      idx++
      print "olcAccess: {" idx "}" line
      next
    }
    {print}
    END {
      if (!inserted) { print_manage() }
    }
  ' "$file" > "$tmp"
  cp -p "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
  mv "$tmp" "$file"
}

refresh_config_checksums() {
  local cfg="$1"
  if have slaptest; then
    log "Refreshing slapd.d checksums with slaptest"
    slaptest -u -F "$cfg" >/dev/null
  fi
}

fix_config_permissions() {
  local cfg="$1"
  if [[ -d "$cfg" ]]; then
    log "Ensuring permissions on ${cfg}"
    chown -R root:root "$cfg" 2>/dev/null || true
    chmod 700 "$cfg" 2>/dev/null || true
    find "$cfg" -type f -exec chmod 600 {} \; 2>/dev/null || true
    if have restorecon; then
      restorecon -Rv "$cfg" >/dev/null 2>&1 || true
    fi
  fi
}

detect_config_dir() {
  local from_ps
  from_ps=$(ps -ef | awk '/slapd/ && !/awk/ && !/grep/ {for (i=1;i<=NF;i++) if ($i=="-F") {print $(i+1); exit}}')
  if [[ -n "$from_ps" && -d "$from_ps" ]]; then
    echo "$from_ps"
    return
  fi
  local defaults=(
    "/opt/symas/etc/openldap/slapd.d"
    "/etc/openldap/slapd.d"
    "/var/lib/ldap/slapd.d"
  )
  for d in "${defaults[@]}"; do
    if [[ -d "$d" ]]; then
      echo "$d"
      return
    fi
  done
  err "Cannot find slapd.d directory (looked for -F in ps and common defaults)."
}

detect_example_password() {
  local candidates=(
    "/opt/symas/share/symas/exampledb.sh"
    "${SCRIPT_DIR}/Exampledb/exampledb.sh"
  )
  local pw file
  for file in "${candidates[@]}"; do
    if [[ -f "$file" ]]; then
      pw=$(awk 'tolower($1) ~ /^(rootpw|olcrootpw)$/ {print $2; exit}' "$file")
      if [[ -n "$pw" ]]; then
        echo "$pw"
        return 0
      fi
    fi
  done
  return 1
}

suffix_exists() {
  local uri="$1" suffix="$2"
  [[ -n "$suffix" ]] || return 1
  ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$uri" -b "cn=config" -LLL "(olcSuffix=${suffix})" dn 2>/dev/null | grep -q '^dn: '
}

detect_first_suffix() {
  local uri="$1"
  ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$uri" -b "cn=config" -LLL "(olcSuffix=*)" olcSuffix 2>/dev/null | awk '/^olcSuffix:/ {print $2; exit}'
}

set_rootpw() {
  local uri="$1" suffix="$2" pw="$3"
  local db_dn hash
  db_dn=$(ldapsearch -Y EXTERNAL -H "$uri" -b "cn=config" "(olcSuffix=${suffix})" -LLL dn olcRootDN 2>/dev/null | awk '/^dn: / {print substr($0,5); exit}')
  [[ -n "$db_dn" ]] || err "Could not locate cn=config entry for olcSuffix=${suffix}"
  hash=$(slappasswd -s "$pw")
  log "Setting olcRootPW on ${db_dn} to new value"
  ldapmodify -Y EXTERNAL -H "$uri" <<EOF
dn: ${db_dn}
changetype: modify
replace: olcRootPW
olcRootPW: ${hash}
EOF
}

verify_bind() {
  local uri="$1" suffix="$2" pw="$3"
  local dn
  dn=$(ldapsearch -Y EXTERNAL -H "$uri" -b "cn=config" "(olcSuffix=${suffix})" -LLL olcRootDN 2>/dev/null | awk '/^olcRootDN:/ {print $2; exit}')
  if [[ -z "$dn" ]]; then
    dn="cn=admin,${suffix}"
  fi
  log "Verifying simple bind as ${dn}"
  ldapwhoami -x -D "$dn" -w "$pw" -H ldap://localhost || warn "Bind test failed; verify DN/password manually."
}

main() {
  require_root
  ensure_symas_env
  require_cmd ldapwhoami
  require_cmd ldapsearch
  require_cmd ldapmodify
  require_cmd slappasswd

  local sock uri unit cfg cfg_file suffix detected_suffix pwd
  sock=$(detect_ldapi_socket)
  uri=$(encode_ldapi_uri "$sock")
  log "Using ldapi socket: ${sock}"

  log "Checking SASL/EXTERNAL identity"
  ldapwhoami -Y EXTERNAL -H "$uri"

  pwd="$PASSWORD"
  if [[ -z "$pwd" ]]; then
    if pwd=$(detect_example_password); then
      log "Detected password from exampledb.sh"
    else
      warn "Could not detect password from exampledb.sh; falling back to default TheN1le1"
      pwd="TheN1le1"
    fi
  fi
  PASSWORD="$pwd"

  if first_acl_is_manage "$uri"; then
    log "Manage ACL for peercred root is already first in olcDatabase={0}config."
  else
    log "Manage ACL missing or ordered later; patching cn=config offline."
    unit=$(detect_unit)
    log "Stopping slapd service: ${unit:-<unknown>}"
    stop_slapd "$unit"
    cfg=$(detect_config_dir)
    cfg_file=$(detect_config_db_file "$cfg")
    rewrite_acl_file "$cfg_file"
    fix_config_permissions "$cfg"
    refresh_config_checksums "$cfg"
    log "Starting slapd service: ${unit:-<unknown>}"
    start_slapd "$unit"
    sleep 2
    first_acl_is_manage "$uri" || err "ACL patch failed; inspect ${cfg_file}"
    log "ACL patch verified."
  fi

  suffix="$BASE_DN"
  if ! suffix_exists "$uri" "$suffix"; then
    detected_suffix=$(detect_first_suffix "$uri")
    [[ -n "$detected_suffix" ]] || err "Could not find any olcSuffix entries in cn=config; set BASE_DN explicitly."
    warn "olcSuffix=${suffix} not found; using detected suffix ${detected_suffix}"
    suffix="$detected_suffix"
  fi

  set_rootpw "$uri" "$suffix" "$PASSWORD"
  verify_bind "$uri" "$suffix" "$PASSWORD"
}

main "$@"
