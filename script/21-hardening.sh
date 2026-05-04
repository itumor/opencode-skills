#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  fatal "Run as root"
fi

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

require_cmd() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1 || fatal "$bin not found in PATH"
}

encode_ldapi_uri() {
  local sock="$1"
  local enc
  enc=$(printf '%s' "$sock" | sed 's,/,%2F,g')
  echo "ldapi://${enc}"
}

ensure_symas_env
require_cmd ldapsearch
require_cmd ldapmodify

BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
LDAPI_URI="${LDAPI_URI:-}"
LDAPI_SOCKET="${LDAPI_SOCKET:-}"

DISALLOW_ANON_BIND="${DISALLOW_ANON_BIND:-1}"
# Allow Terraform/Ansible-style var name as alias.
if [[ -z "${REQUIRE_TLS_SIMPLE_BINDS:-}" && -n "${OPENLDAP_REQUIRE_TLS_SIMPLE_BINDS:-}" ]]; then
  REQUIRE_TLS_SIMPLE_BINDS="${OPENLDAP_REQUIRE_TLS_SIMPLE_BINDS}"
fi
REQUIRE_TLS_SIMPLE_BINDS="${REQUIRE_TLS_SIMPLE_BINDS:-1}"
SIMPLE_BIND_SSF="${SIMPLE_BIND_SSF:-128}"
SET_TLS_PARAMS="${SET_TLS_PARAMS:-1}"
TLS_PROTOCOL_MIN="${TLS_PROTOCOL_MIN:-3.3}"
TLS_CIPHER_SUITE="${TLS_CIPHER_SUITE:-HIGH:!aNULL:!eNULL:!MD5:!RC4:!3DES:!DES:!NULL}"
FORCE_TLS="${FORCE_TLS:-0}"
PASSWORD_HASH="${PASSWORD_HASH:-}"
ENFORCE_FS_PERMS="${ENFORCE_FS_PERMS:-1}"
SLAPD_USER="${SLAPD_USER:-}"
SLAPD_GROUP="${SLAPD_GROUP:-}"

if [[ -z "$LDAPI_URI" ]]; then
  if [[ -n "$LDAPI_SOCKET" ]]; then
    LDAPI_URI="$(encode_ldapi_uri "$LDAPI_SOCKET")"
  else
    LDAPI_URI="ldapi:///"
  fi
fi

ldapsearch_base() {
  local dn="$1"
  local attr="${2:-}"
  if [[ -n "$attr" ]]; then
    ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" -b "$dn" -s base -LLL "$attr"
  else
    ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" -b "$dn" -s base -LLL
  fi
}

ldapsearch_attr() {
  local dn="$1"
  local attr="$2"
  ldapsearch_base "$dn" "$attr" 2>/dev/null | awk -F': ' -v a="$attr" '$1==a {print $2}'
}

check_cn_config() {
  if ! ldapsearch_base "cn=config" "dn" >/dev/null 2>&1; then
    fatal "Cannot access cn=config via ${LDAPI_URI}. Set LDAPI_URI or LDAPI_SOCKET and re-run."
  fi
}

apply_ldif() {
  local ldif="$1"
  echo "$ldif" | ldapmodify -Y EXTERNAL -H "$LDAPI_URI"
}

check_cn_config

tls_cert="$(ldapsearch_attr "cn=config" "olcTLSCertificateFile" | head -n 1 || true)"
tls_key="$(ldapsearch_attr "cn=config" "olcTLSCertificateKeyFile" | head -n 1 || true)"
tls_ready=0
if [[ -n "$tls_cert" && -n "$tls_key" ]]; then
  if [[ -f "$tls_cert" && -f "$tls_key" ]]; then
    tls_ready=1
  else
    warn "TLS cert/key set in cn=config but files not found on disk"
  fi
else
  warn "TLS cert/key not set in cn=config"
fi

if [[ "$DISALLOW_ANON_BIND" -eq 1 ]]; then
  if ldapsearch_attr "cn=config" "olcDisallows" | grep -qx "bind_anon"; then
    log "Anonymous bind already disallowed"
  else
    apply_ldif "$(cat <<EOF
dn: cn=config
changetype: modify
add: olcDisallows
olcDisallows: bind_anon
EOF
)"
    log "Disallowed anonymous binds"
  fi
else
  log "Skipping anonymous bind hardening (DISALLOW_ANON_BIND=0)"
fi

if [[ "$REQUIRE_TLS_SIMPLE_BINDS" -eq 1 ]]; then
  if [[ "$tls_ready" -eq 0 && "$FORCE_TLS" -ne 1 ]]; then
    warn "TLS not configured; skipping simple bind TLS enforcement (set FORCE_TLS=1 to override)"
  else
    existing_security=()
    while IFS= read -r line; do
      existing_security+=("$line")
    done < <(ldapsearch_attr "cn=config" "olcSecurity" || true)

    existing_simple_val=""
    existing_simple_ssf=""
    for val in "${existing_security[@]}"; do
      if [[ "$val" =~ simple_bind=([0-9]+) ]]; then
        existing_simple_val="$val"
        existing_simple_ssf="${BASH_REMATCH[1]}"
        break
      fi
    done

    if [[ -z "$existing_simple_ssf" ]]; then
      apply_ldif "$(cat <<EOF
dn: cn=config
changetype: modify
add: olcSecurity
olcSecurity: simple_bind=${SIMPLE_BIND_SSF}
EOF
)"
      log "Required TLS for simple binds (simple_bind=${SIMPLE_BIND_SSF})"
    elif [[ "$existing_simple_ssf" -lt "$SIMPLE_BIND_SSF" ]]; then
      apply_ldif "$(cat <<EOF
dn: cn=config
changetype: modify
delete: olcSecurity
olcSecurity: ${existing_simple_val}
-
add: olcSecurity
olcSecurity: simple_bind=${SIMPLE_BIND_SSF}
EOF
)"
      log "Updated simple_bind SSF to ${SIMPLE_BIND_SSF}"
    else
      log "simple_bind SSF already >= ${SIMPLE_BIND_SSF}"
    fi
  fi
else
  log "Skipping TLS requirement for simple binds (REQUIRE_TLS_SIMPLE_BINDS=0)"
fi

if [[ "$SET_TLS_PARAMS" -eq 1 ]]; then
  if [[ "$tls_ready" -eq 0 && "$FORCE_TLS" -ne 1 ]]; then
    warn "TLS not configured; skipping TLS protocol/cipher hardening (set FORCE_TLS=1 to override)"
  else
    current_min="$(ldapsearch_attr "cn=config" "olcTLSProtocolMin" | head -n 1 || true)"
    if [[ "$current_min" == "$TLS_PROTOCOL_MIN" ]]; then
      log "TLS protocol min already ${TLS_PROTOCOL_MIN}"
    else
      op="replace"
      [[ -z "$current_min" ]] && op="add"
      apply_ldif "$(cat <<EOF
dn: cn=config
changetype: modify
${op}: olcTLSProtocolMin
olcTLSProtocolMin: ${TLS_PROTOCOL_MIN}
EOF
)"
      log "Set TLS protocol min to ${TLS_PROTOCOL_MIN}"
    fi

    current_cipher="$(ldapsearch_attr "cn=config" "olcTLSCipherSuite" | head -n 1 || true)"
    if [[ "$current_cipher" == "$TLS_CIPHER_SUITE" ]]; then
      log "TLS cipher suite already set"
    else
      op="replace"
      [[ -z "$current_cipher" ]] && op="add"
      apply_ldif "$(cat <<EOF
dn: cn=config
changetype: modify
${op}: olcTLSCipherSuite
olcTLSCipherSuite: ${TLS_CIPHER_SUITE}
EOF
)"
      log "Set TLS cipher suite"
    fi
  fi
else
  log "Skipping TLS protocol/cipher hardening (SET_TLS_PARAMS=0)"
fi

if [[ -n "$PASSWORD_HASH" ]]; then
  current_hash="$(ldapsearch_attr "cn=config" "olcPasswordHash" | head -n 1 || true)"
  if [[ "$current_hash" == "$PASSWORD_HASH" ]]; then
    log "olcPasswordHash already set"
  else
    op="replace"
    [[ -z "$current_hash" ]] && op="add"
    apply_ldif "$(cat <<EOF
dn: cn=config
changetype: modify
${op}: olcPasswordHash
olcPasswordHash: ${PASSWORD_HASH}
EOF
)"
    log "Set olcPasswordHash to ${PASSWORD_HASH}"
  fi
fi

if [[ "$ENFORCE_FS_PERMS" -eq 1 ]]; then
  if [[ -z "$SLAPD_USER" ]]; then
    SLAPD_USER="$(ps -eo user,comm | awk '$2=="slapd"{print $1; exit}')"
  fi
  if [[ -z "$SLAPD_USER" ]]; then
    for u in symas-openldap openldap ldap; do
      if id -u "$u" >/dev/null 2>&1; then
        SLAPD_USER="$u"
        break
      fi
    done
  fi
  if [[ -z "$SLAPD_USER" ]]; then
    warn "Could not determine slapd user; skipping filesystem permissions"
  else
    if [[ -z "$SLAPD_GROUP" ]]; then
      SLAPD_GROUP="$SLAPD_USER"
    fi

    config_dir="/opt/symas/etc/openldap/slapd.d"
    db_dn="$(ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -LLL "(&(objectClass=olcMdbConfig)(olcSuffix=${BASE_DN}))" dn | awk '/^dn: /{print $2; exit}')"
    if [[ -z "$db_dn" ]]; then
      db_dn="$(ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -LLL "(objectClass=olcMdbConfig)" dn | awk '/^dn: /{print $2; exit}')"
    fi
    db_dir=""
    if [[ -n "$db_dn" ]]; then
      db_dir="$(ldapsearch_attr "$db_dn" "olcDbDirectory" | head -n 1 || true)"
    fi
    if [[ -z "$db_dir" && -d /opt/symas/var/openldap-data ]]; then
      db_dir="/opt/symas/var/openldap-data"
    fi

    if [[ -d "$config_dir" ]]; then
      chown -R "${SLAPD_USER}:${SLAPD_GROUP}" "$config_dir"
      find "$config_dir" -type d -exec chmod 700 {} +
      find "$config_dir" -type f -exec chmod 600 {} +
      log "Hardened permissions on ${config_dir}"
    else
      warn "Config dir not found: ${config_dir}"
    fi

    if [[ -n "$db_dir" && -d "$db_dir" ]]; then
      chown -R "${SLAPD_USER}:${SLAPD_GROUP}" "$db_dir"
      find "$db_dir" -type d -exec chmod 700 {} +
      find "$db_dir" -type f -exec chmod 600 {} +
      log "Hardened permissions on ${db_dir}"
    else
      warn "Database dir not found; skipping data permissions"
    fi
  fi
else
  log "Skipping filesystem permission hardening (ENFORCE_FS_PERMS=0)"
fi

log "Hardening complete"
