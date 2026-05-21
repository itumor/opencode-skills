#!/usr/bin/env bash
# r7-harden-replica.sh
#
# Applies security hardening to replica node.
# Mirrors 21-hardening.sh from master with one key difference:
#   - Does NOT disable olcUpdateRef — replica must be able to refer
#     write ops back to master
#   - Anonymous bind still disabled
#   - TLS still required for simple binds
#   - Filesystem permissions hardened
#
# Usage: sudo bash r7-harden-replica.sh
set -euo pipefail

log()   { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  [[ -f "$prof" ]] && source "$prof" 2>/dev/null || true
  [[ ":${PATH}:" == *":/opt/symas/bin:"* ]]  || export PATH="/opt/symas/bin:${PATH}"
  [[ ":${PATH}:" == *":/opt/symas/sbin:"* ]] || export PATH="/opt/symas/sbin:${PATH}"
  [[ -n "${LDAPCONF:-}" ]] || export LDAPCONF="/opt/symas/etc/openldap/ldap.conf"
}
ensure_symas_env

require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }
require_cmd ldapsearch
require_cmd ldapmodify

LDAPI_URI="${LDAPI_URI:-ldapi:///}"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
SIMPLE_BIND_SSF="${SIMPLE_BIND_SSF:-128}"
TLS_PROTOCOL_MIN="${TLS_PROTOCOL_MIN:-3.3}"
TLS_CIPHER_SUITE="${TLS_CIPHER_SUITE:-HIGH:!aNULL:!eNULL:!MD5:!RC4:!3DES:!DES:!NULL}"

apply_ldif() { echo "$1" | ldapmodify -Y EXTERNAL -H "$LDAPI_URI"; }

ldapsearch_attr() {
  ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" \
    -b "$1" -s base -LLL "$2" 2>/dev/null \
    | awk -F': ' -v a="$2" '$1==a {print $2}'
}

# Verify cn=config accessible
ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -s base -LLL dn >/dev/null 2>&1 \
  || fatal "Cannot access cn=config via ${LDAPI_URI}"

tls_cert="$(ldapsearch_attr cn=config olcTLSCertificateFile | head -1 || true)"
tls_key="$(ldapsearch_attr cn=config olcTLSCertificateKeyFile | head -1 || true)"
tls_ready=0
[[ -n "$tls_cert" && -n "$tls_key" && -f "$tls_cert" && -f "$tls_key" ]] && tls_ready=1
[[ "$tls_ready" -eq 0 ]] && warn "TLS not configured — TLS-dependent hardening skipped"

# Disable anonymous bind
if ldapsearch_attr cn=config olcDisallows | grep -qx "bind_anon"; then
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

# Require TLS for simple binds
if [[ "$tls_ready" -eq 1 ]]; then
  existing_ssf="$(ldapsearch_attr cn=config olcSecurity | awk -F'simple_bind=' '{print $2}' | head -1 || true)"
  if [[ -z "$existing_ssf" ]]; then
    apply_ldif "$(cat <<EOF
dn: cn=config
changetype: modify
add: olcSecurity
olcSecurity: simple_bind=${SIMPLE_BIND_SSF}
EOF
)"
    log "Required TLS for simple binds (simple_bind=${SIMPLE_BIND_SSF})"
  else
    log "simple_bind SSF already set to ${existing_ssf}"
  fi
fi

# TLS protocol min
if [[ "$tls_ready" -eq 1 ]]; then
  current_min="$(ldapsearch_attr cn=config olcTLSProtocolMin | head -1 || true)"
  if [[ "$current_min" != "$TLS_PROTOCOL_MIN" ]]; then
    op="replace"; [[ -z "$current_min" ]] && op="add"
    apply_ldif "$(cat <<EOF
dn: cn=config
changetype: modify
${op}: olcTLSProtocolMin
olcTLSProtocolMin: ${TLS_PROTOCOL_MIN}
EOF
)"
    log "Set TLS protocol min to ${TLS_PROTOCOL_MIN}"
  else
    log "TLS protocol min already ${TLS_PROTOCOL_MIN}"
  fi

  # TLS cipher suite
  current_cipher="$(ldapsearch_attr cn=config olcTLSCipherSuite | head -1 || true)"
  if [[ "$current_cipher" != "$TLS_CIPHER_SUITE" ]]; then
    op="replace"; [[ -z "$current_cipher" ]] && op="add"
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

# Filesystem permissions
SLAPD_USER="$(ps -eo user,comm | awk '$2=="slapd"{print $1; exit}')"
[[ -z "$SLAPD_USER" ]] && SLAPD_USER="symas-openldap"
CONFIG_DIR="/opt/symas/etc/openldap/slapd.d"
DB_DIR="/var/symas/openldap-data/example"

if [[ -d "$CONFIG_DIR" ]]; then
  chown -R "${SLAPD_USER}:${SLAPD_USER}" "$CONFIG_DIR" 2>/dev/null || true
  find "$CONFIG_DIR" -type d -exec chmod 700 {} + 2>/dev/null || true
  find "$CONFIG_DIR" -type f -exec chmod 600 {} + 2>/dev/null || true
  log "Hardened permissions on ${CONFIG_DIR}"
fi
if [[ -d "$DB_DIR" ]]; then
  chown -R "${SLAPD_USER}:${SLAPD_USER}" "$DB_DIR" 2>/dev/null || true
  find "$DB_DIR" -type d -exec chmod 700 {} + 2>/dev/null || true
  find "$DB_DIR" -type f -exec chmod 600 {} + 2>/dev/null || true
  log "Hardened permissions on ${DB_DIR}"
fi

log "Replica hardening complete"
