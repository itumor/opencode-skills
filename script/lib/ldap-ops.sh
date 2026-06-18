#!/usr/bin/env bash
# lib/ldap-ops.sh — LDAP wrapper functions
# Sources: lib/common.sh
# ponytail: one function per operation pattern, handles TLS/ldapi/error-checking

ldapi_whoami() {
  ldapwhoami -Y EXTERNAL -H "${LDAPI_URI:-ldapi:///}" "$@" 2>/dev/null
}

# ldapi search — returns raw ldapsearch output, consumer parses
ldapi_search() {
  local base="$1"; shift
  ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "${LDAPI_URI:-ldapi:///}" -b "$base" "$@" 2>/dev/null
}

# ldapi modify — stdin or file
ldapi_modify() {
  if [[ $# -gt 0 ]]; then
    ldapmodify -Y EXTERNAL -H "${LDAPI_URI:-ldapi:///}" "$@"
  else
    ldapmodify -Y EXTERNAL -H "${LDAPI_URI:-ldapi:///}"
  fi
}

# Search via StartTLS with admin bind
admin_search() {
  local base="$1"; shift
  LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}" ldapsearch -o ldif-wrap=no -x -ZZ \
    -H "ldap://localhost" -D "${ADMIN_DN}" -w "${ADMIN_PW}" -b "$base" "$@" 2>/dev/null
}

# Bind test via StartTLS with any DN
admin_bind() {
  LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}" ldapwhoami -x -ZZ \
    -H "ldap://localhost" -D "${ADMIN_DN}" -w "${ADMIN_PW}" >/dev/null 2>&1
}

repl_bind() {
  LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}" ldapwhoami -x -ZZ \
    -H "ldap://localhost" -D "${REPL_DN}" -w "${REPL_PW}" >/dev/null 2>&1
}

# ldapi add — stdin or file
ldapi_add() {
  if [[ $# -gt 0 ]]; then
    ldapadd -Y EXTERNAL -H "${LDAPI_URI:-ldapi:///}" "$@"
  else
    ldapadd -Y EXTERNAL -H "${LDAPI_URI:-ldapi:///}"
  fi
}

# Get single attr value from ldapi search
ldapi_get_attr() {
  local base="$1" attr="$2"
  ldapi_search "$base" -s base -LLL "$attr" 2>/dev/null | awk -F': ' -v a="$attr" '$1==a {print $2; exit}'
}

# Get DN of first mdb database with suffix
db_dn() {
  ldapi_search "cn=config" -LLL '(&(objectClass=olcMdbConfig)(olcSuffix=*))' dn 2>/dev/null \
    | awk '/^dn: /{print $2; exit}'
}

# Check if overlay exists on database
has_overlay() {
  local overlay="$1"
  local count
  count=$(ldapi_search "cn=config" -s sub "(olcOverlay=${overlay})" dn 2>/dev/null | grep -ci "^dn:" || true)
  count=$(echo "$count" | tr -d '[:space:]')
  [[ -n "$count" && "$count" -gt 0 ]]
}

# Set TLS cert paths in cn=config
set_tls_config() {
  local cert="$1" key="$2" ca="$3" proto="${4:-3.3}"
  ldapi_modify <<LDIFTLS
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: ${cert}
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: ${key}
-
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: ${ca}
-
replace: olcTLSProtocolMin
olcTLSProtocolMin: ${proto}
LDIFTLS
}

# Check port listening
port_listening() {
  local port="$1"
  bash -c "echo >/dev/tcp/localhost/${port}" 2>/dev/null
}

# Count entries under base
entry_count() {
  local count
  count=$(admin_search "${BASE_DN}" -s sub "(objectClass=*)" dn 2>/dev/null | grep -c "^dn:" || true)
  echo "$count" | tr -d '[:space:]'
}

# Get contextCSN
get_context_csn() {
  admin_search "${BASE_DN}" -s base contextCSN 2>/dev/null \
    | awk '/^contextCSN:/{print $2; exit}'
}

# Auto-detect master vs replica
detect_role() {
  local db=$(db_dn)
  if ldapi_search "$db" -s base -LLL olcSyncrepl 2>/dev/null | grep -q "."; then
    echo "replica"
  else
    echo "master"
  fi
}
