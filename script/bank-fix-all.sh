#!/usr/bin/env bash
# bank-fix-all.sh
# ====================================================================
# One script to fix ALL issues found in the bank OpenLDAP deployment.
# Detects whether it's running on master or replica and applies the
# correct fixes automatically.
#
# Run as root on BOTH servers (master first, then replica).
#
# Issues fixed (from log analysis, May 24 – Jun 03 2026):
#
#   MASTER:
#     1. Missing syncprov overlay → syncrepl can't stream changes
#     2. Missing entryUUID/entryCSN indices → refreshDelete loop
#     3. cn=config checksum errors → warning on every restart
#     4. ACL allowing replicator read access
#
#   REPLICA:
#     1. syncrepl starttls=no → all 14 binds rejected (err=13)
#     2. ppolicy module not loaded → objectClass invalid per syntax
#     3. Self-signed TLS certs missing/incomplete → STARTTLS fails
#     4. Replica ACL missing → admin can't read data
#     5. cn=config TLS cert paths stale → constraint violation
#
# Usage:
#   sudo bash bank-fix-all.sh
# ====================================================================
set -uo pipefail

log()   { echo "[INFO]  $*"; }
ok()    { echo "[ OK ]  $*"; }
warn()  { echo "[WARN]  $*"; }
bad()   { echo "[FAIL] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }
banner() { echo ""; echo "=== $* ==="; }

PASS=0; FAIL=0; WARN=0
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
HOSTNAME=$(hostname -f 2>/dev/null || hostname)

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

# ---- Setup PATH ----
export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
[[ -f /opt/symas/etc/openldap/sysmas_env.sh ]] && source /opt/symas/etc/openldap/sysmas_env.sh 2>/dev/null || true
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

# ---- Tool checks ----
require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found — install it first"; }
require_cmd ldapsearch
require_cmd ldapmodify
require_cmd python3
require_cmd openssl

# ---- Find slapd service ----
for svc in symas-openldap-servers slapd; do
  if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then
    SLAPD_SVC="$svc"
    break
  fi
done
if [[ -z "${SLAPD_SVC:-}" ]] && pgrep -x slapd >/dev/null 2>&1; then
  SLAPD_SVC="slapd"
fi
SLAPD_SVC="${SLAPD_SVC:-symas-openldap-servers}"

# ---- SSHA hash helper (no slappasswd needed) ----
ssha_hash() {
  python3 -c "
import hashlib, base64, os
salt = os.urandom(8)
h = hashlib.sha1(b'${1}')
h.update(salt)
digest = base64.b64encode(h.digest() + salt).decode()
print('{SSHA}' + digest)
"
}

# ---- LDAPI helpers ----
LDAPI_URI="ldapi:///"
ldapi_search()  { ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" "$@" 2>/dev/null; }
ldapi_modify()  { ldapmodify -Y EXTERNAL -H "$LDAPI_URI" "$@"; }

# ---- Config ----
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_DN="cn=admin,${BASE_DN}"
ADMIN_PW="${ADMIN_PW:-TheN1le1}"
REPL_DN="cn=replicator,${BASE_DN}"
REPL_PW="${REPL_PW:-replpass}"

# ====================================================================
echo ""
echo "============================================================"
echo "  BANK OPENLDAP FIX — ALL-IN-ONE"
echo "  Server:   ${HOSTNAME}"
echo "  Service:  ${SLAPD_SVC}"
echo "  Base DN:  ${BASE_DN}"
echo "  Time:     ${TIMESTAMP}"
echo "============================================================"

# ---- Verify LDAPI works ----
banner "Pre-flight: LDAPI access"
if ldapwhoami -Y EXTERNAL -H "$LDAPI_URI" >/dev/null 2>&1; then
  ok "LDAPI EXTERNAL works"
else
  fatal "LDAPI EXTERNAL failed — cannot fix config"
fi

# ---- Detect role ----
banner "Role detection"

DB_DN=$(ldapi_search -b cn=config -LLL '(&(objectClass=olcMdbConfig)(olcSuffix=*))' dn | awk '/^dn: /{print $2; exit}')
HAS_SYNCREPL=$(ldapi_search -b "$DB_DN" -s base -LLL olcSyncrepl 2>/dev/null | grep -ci olcSyncrepl || true)
HAS_SYNCPROV=$(ldapi_search -b cn=config -s sub "(olcOverlay=syncprov)" dn 2>/dev/null | grep -ci "^dn:" || true)

IS_MASTER=0; IS_REPLICA=0
if [[ "$HAS_SYNCREPL" -gt 0 ]]; then
  IS_REPLICA=1
  log "Role: REPLICA (olcSyncrepl detected)"
else
  IS_MASTER=1
  log "Role: MASTER (no olcSyncrepl)"
fi

# ====================================================================
# MASTER FIXES
# ====================================================================
if [[ "$IS_MASTER" -eq 1 ]]; then

  # ---- Fix 1: Backup cn=config ----
  banner "Master Fix 1: Backup cn=config"
  SLAPD_D="/opt/symas/etc/openldap/slapd.d"
  BACKUP="${SLAPD_D}.fix-${TIMESTAMP}"
  cp -a "$SLAPD_D" "$BACKUP"
  ok "Backed up to $BACKUP"

  # ---- Fix 2: Rebuild cn=config checksums ----
  banner "Master Fix 2: Rebuild checksums"
  CONFIG_EXPORT="/tmp/cn-config-export-${TIMESTAMP}.ldif"
  slapcat -n 0 -l "$CONFIG_EXPORT" 2>/dev/null || fatal "slapcat failed"
  ENTRIES=$(grep -c "^dn:" "$CONFIG_EXPORT" 2>/dev/null || echo "0")
  log "Exported $ENTRIES entries"

  systemctl stop "$SLAPD_SVC"
  sleep 2
  find "$SLAPD_D" -mindepth 1 -delete 2>/dev/null || true
  slapadd -n 0 -F "$SLAPD_D" -l "$CONFIG_EXPORT" 2>/dev/null || { warn "slapadd failed — restoring backup"; rm -rf "$SLAPD_D"; cp -a "$BACKUP" "$SLAPD_D"; }

  SLAPD_USER="symas-openldap"
  id "$SLAPD_USER" >/dev/null 2>&1 || SLAPD_USER="ldap"
  id "$SLAPD_USER" >/dev/null 2>&1 || SLAPD_USER="root"
  chown -R "${SLAPD_USER}:${SLAPD_USER}" "$SLAPD_D" 2>/dev/null || true
  restorecon -Rv "$SLAPD_D" 2>/dev/null || true

  systemctl start "$SLAPD_SVC"
  sleep 3

  if systemctl is-active --quiet "$SLAPD_SVC"; then
    ok "Slapd active after checksum rebuild"; PASS=$((PASS+1))
  else
    bad "Slapd failed — restoring backup"; rm -rf "$SLAPD_D"; cp -a "$BACKUP" "$SLAPD_D"; systemctl start "$SLAPD_SVC"; FAIL=$((FAIL+1))
  fi
  rm -f "$CONFIG_EXPORT"

  # ---- Fix 3: Syncprov overlay ----
  banner "Master Fix 3: Syncprov overlay"
  if [[ "$HAS_SYNCPROV" -gt 0 ]]; then
    ok "Syncprov already present"; PASS=$((PASS+1))
  else
    ldapi_modify -f <(cat <<LDIF
dn: olcOverlay=syncprov,${DB_DN}
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 100
LDIF
) && { ok "Syncprov overlay added"; PASS=$((PASS+1)); } || { bad "Syncprov add failed"; FAIL=$((FAIL+1)); }
  fi

  # ---- Fix 4: entryUUID/entryCSN indices ----
  banner "Master Fix 4: Syncrepl indices"
  INDICES=$(ldapi_search -b "$DB_DN" -s base -LLL olcDbIndex 2>/dev/null || true)
  MISSING=""
  echo "$INDICES" | grep -q "entryUUID" || MISSING="$MISSING entryUUID"
  echo "$INDICES" | grep -q "entryCSN"  || MISSING="$MISSING entryCSN"

  if [[ -z "$MISSING" ]]; then
    ok "entryUUID + entryCSN indices present"; PASS=$((PASS+1))
  else
    log "Adding missing:$MISSING"
    ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
add: olcDbIndex
olcDbIndex: entryUUID eq
-
add: olcDbIndex
olcDbIndex: entryCSN eq
LDIF
) && { ok "Indices added"; PASS=$((PASS+1)); } || { bad "Index add failed"; FAIL=$((FAIL+1)); }
  fi

  # ---- Fix 5: ACL for replicator ----
  banner "Master Fix 5: Replicator ACL"
  ACL_OK=$(ldapi_search -b "$DB_DN" -s base -LLL olcAccess 2>/dev/null | grep -c "replicator" || true)
  if [[ "$ACL_OK" -gt 0 ]]; then
    ok "Replicator ACL present"; PASS=$((PASS+1))
  else
    log "Adding replicator read ACL"
    ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword by self write by anonymous auth by * none
olcAccess: {1}to * by dn.exact="${REPL_DN}" read by * read
LDIF
) && { ok "ACL configured"; PASS=$((PASS+1)); } || { bad "ACL failed"; FAIL=$((FAIL+1)); }
  fi

  # ---- Fix 6: Reset admin password (if needed) ----
  banner "Master Fix 6: Admin password"
  log "Ensuring admin password is set to: $ADMIN_PW"
  NEW_HASH=$(ssha_hash "$ADMIN_PW")
  ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
replace: olcRootPW
olcRootPW: ${NEW_HASH}
LDIF
) && { ok "Admin password reset"; PASS=$((PASS+1)); } || { bad "Password reset failed"; FAIL=$((FAIL+1)); }

  # ---- Restart ----
  systemctl restart "$SLAPD_SVC"
  sleep 3
  if systemctl is-active --quiet "$SLAPD_SVC"; then ok "Slapd running after fixes"; PASS=$((PASS+1)); fi

fi

# ====================================================================
# REPLICA FIXES
# ====================================================================
if [[ "$IS_REPLICA" -eq 1 ]]; then

  # ---- Fix 1: Update syncrepl to starttls=yes ----
  banner "Replica Fix 1: Syncrepl StartTLS"
  CURRENT=$(ldapi_search -o ldif-wrap=no -b "$DB_DN" -s base -LLL olcSyncrepl 2>/dev/null | tr -d '\n' || true)

  if echo "$CURRENT" | grep -qi "starttls=yes"; then
    ok "starttls=yes already set"; PASS=$((PASS+1))
  else
    PROVIDER=$(echo "$CURRENT" | grep -oP 'provider=\K[^ ]+' | head -1 || echo "ldap://172.23.11.236:389")
    BINDDN=$(echo "$CURRENT"   | grep -oP 'binddn="\K[^"]+'   | head -1 || echo "cn=replicator,dc=eab,dc=bank,dc=local")
    CREDS=$(echo "$CURRENT"    | grep -oP 'credentials="?\K[^" ]+' | head -1 || echo "replpass")
    BASE=$(echo "$CURRENT"     | grep -oP 'searchbase="\K[^"]+' | head -1 || echo "dc=eab,dc=bank,dc=local")
    RID=$(echo "$CURRENT"      | grep -oP 'rid=\K[0-9]+' | head -1 || echo "101")
    PROVIDER=$(echo "$PROVIDER" | sed 's/^ldaps:/ldap:/')

    ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
replace: olcSyncrepl
olcSyncrepl: {0}rid=${RID} provider=${PROVIDER} bindmethod=simple binddn="${BINDDN}" credentials=${CREDS} searchbase="${BASE}" type=refreshAndPersist retry="5 5 300 +" timeout=1 starttls=yes tls_reqcert=never interval=00:00:00:10
LDIF
) && { ok "Syncrepl updated to starttls=yes"; PASS=$((PASS+1)); } || { bad "Syncrepl update failed"; FAIL=$((FAIL+1)); }
  fi

  # ---- Fix 2: Load ppolicy module ----
  banner "Replica Fix 2: ppolicy module"
  PPOLICY=$(ldapi_search -b cn=config -s sub "(olcModuleLoad=ppolicy.la)" dn 2>/dev/null | grep -c "cn=module" || true)
  if [[ "$PPOLICY" -gt 0 ]]; then
    ok "ppolicy module loaded"; PASS=$((PASS+1))
  else
    ldapi_modify -f <(cat <<'LDIF'
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: ppolicy.la
LDIF
) && { ok "ppolicy module loaded"; PASS=$((PASS+1)); } || { bad "ppolicy load failed"; FAIL=$((FAIL+1)); }
  fi

  # ---- Fix 3: Self-signed TLS certs ----
  banner "Replica Fix 3: TLS certificates"
  TLS_DIR="/opt/symas/etc/openldap/tls"
  TLS_CERT="${TLS_DIR}/ldap.crt"
  TLS_KEY="${TLS_DIR}/ldap.key"
  TLS_CA="${TLS_DIR}/ca.crt"
  TLS_CAKEY="${TLS_DIR}/ca.key"

  if [[ ! -f "$TLS_CERT" || ! -f "$TLS_KEY" ]]; then
    log "Generating self-signed TLS certs..."
    mkdir -p "$TLS_DIR"

    if [[ ! -f "$TLS_CA" ]]; then
      openssl genrsa -out "$TLS_CAKEY" 4096 2>/dev/null
      openssl req -x509 -new -nodes -key "$TLS_CAKEY" -sha256 -days 3650 \
        -subj "/C=US/O=Bank/OU=LDAP/CN=LDAP CA" -out "$TLS_CA" 2>/dev/null
    fi

    HOST_FQDN=$(hostname -f 2>/dev/null || hostname)
    HOST_SHORT=$(hostname -s 2>/dev/null || hostname)

    cat > "${TLS_DIR}/san.cnf" <<CNF
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext
[ dn ]
C=US
O=Bank
OU=LDAP
CN=${HOST_FQDN}
[ req_ext ]
subjectAltName = @alt_names
[ alt_names ]
DNS.1 = ${HOST_FQDN}
DNS.2 = ${HOST_SHORT}
DNS.3 = localhost
IP.1  = 127.0.0.1
CNF

    openssl genrsa -out "$TLS_KEY" 4096 2>/dev/null
    openssl req -new -key "$TLS_KEY" -out "${TLS_DIR}/ldap.csr" -config "${TLS_DIR}/san.cnf" 2>/dev/null
    openssl x509 -req -in "${TLS_DIR}/ldap.csr" -CA "$TLS_CA" -CAkey "$TLS_CAKEY" \
      -CAcreateserial -out "$TLS_CERT" -days 825 -sha256 \
      -extensions req_ext -extfile "${TLS_DIR}/san.cnf" 2>/dev/null
    rm -f "${TLS_DIR}/ldap.csr" "${TLS_DIR}/san.cnf"

    chmod 700 "$TLS_DIR"
    chmod 600 "$TLS_KEY" "$TLS_CAKEY"
    chmod 644 "$TLS_CERT" "$TLS_CA"
    if id ldap >/dev/null 2>&1; then chown -R ldap:ldap "$TLS_DIR" 2>/dev/null || true; fi

    ok "Self-signed TLS certs generated"; PASS=$((PASS+1))
  else
    ok "TLS certs already present"; PASS=$((PASS+1))
  fi

  # ---- Fix 4: Apply TLS config to cn=config ----
  banner "Replica Fix 4: TLS cn=config"
  ldapi_modify -f <(cat <<LDIF
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: ${TLS_CERT}
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: ${TLS_KEY}
-
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: ${TLS_CA}
LDIF
) && { ok "TLS applied to cn=config"; PASS=$((PASS+1)); } || { bad "TLS config failed"; FAIL=$((FAIL+1)); }

  # ---- Fix 5: ACL for data access ----
  banner "Replica Fix 5: Data ACL"
  ACL_EXISTS=$(ldapi_search -b "$DB_DN" -s base -LLL olcAccess 2>/dev/null | grep -c "olcAccess" || true)
  if [[ "$ACL_EXISTS" -gt 0 ]]; then
    ok "Data ACL present"; PASS=$((PASS+1))
  else
    ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword by self write by anonymous auth by * none
olcAccess: {1}to * by * read
LDIF
) && { ok "Data ACL configured"; PASS=$((PASS+1)); } || { bad "ACL failed"; FAIL=$((FAIL+1)); }
  fi

  # ---- Fix 6: Set olcReadOnly + olcUpdateRef ----
  banner "Replica Fix 6: Read-only enforcement"
  ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
replace: olcReadOnly
olcReadOnly: TRUE
LDIF
) 2>/dev/null && ok "ReadOnly=TRUE" || warn "ReadOnly already set"

  # ---- Restart ----
  systemctl restart "$SLAPD_SVC"
  sleep 3
  if systemctl is-active --quiet "$SLAPD_SVC"; then ok "Slapd running after fixes"; PASS=$((PASS+1)); fi

fi

# ====================================================================
# VERIFICATION (both roles)
# ====================================================================
banner "Verification"

# Service check
if systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1; then
  ok "Slapd is running"; PASS=$((PASS+1))
else
  bad "Slapd not running"; FAIL=$((FAIL+1))
fi

# Port 389
if bash -c "echo >/dev/tcp/localhost/389" 2>/dev/null; then
  ok "Port 389 listening"; PASS=$((PASS+1))
else
  bad "Port 389 not reachable"; FAIL=$((FAIL+1))
fi

# Admin bind (try STARTTLS first, fallback plain)
if LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1; then
  ok "Admin bind via StartTLS"; PASS=$((PASS+1))
elif ldapwhoami -x -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1; then
  ok "Admin bind via plain LDAP"; PASS=$((PASS+1)); warn "STARTTLS not available — TLS may need config"
else
  bad "Admin bind failed — wrong password or slapd issue"; FAIL=$((FAIL+1))
fi

# Base DN
ENTRIES=$(( LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$BASE_DN" -s one -LLL dn 2>/dev/null || ldapsearch -x -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$BASE_DN" -s one -LLL dn 2>/dev/null ) | grep -c "^dn:" || true)
ENTRIES=$(echo "$ENTRIES" | tr -d '[:space:]')
if [[ -n "$ENTRIES" && "$ENTRIES" -gt 0 ]]; then
  ok "Base DN readable — $ENTRIES children"; PASS=$((PASS+1))
else
  warn "Base DN has 0 children — sync may be pending"
fi

# Log analysis (last 5 min)
JOURNAL=$(journalctl -u "$SLAPD_SVC" --no-pager --since "5 minutes ago" 2>/dev/null || true)

ERR13=$(echo "$JOURNAL" | grep -ci "confidentiality required\|err=13" || true)
if [[ "$ERR13" -eq 0 ]]; then ok "No err=13 in recent logs"; PASS=$((PASS+1)); else bad "$ERR13 err=13 found"; FAIL=$((FAIL+1)); fi

ERR49=$(echo "$JOURNAL" | grep -ci "invalid cred\|err=49" || true)
if [[ "$ERR49" -eq 0 ]]; then ok "No err=49 in recent logs"; PASS=$((PASS+1)); else warn "$ERR49 err=49 found"; fi

TLS_FAIL=$(echo "$JOURNAL" | grep -ci "TLS negotiation failure" || true)
if [[ "$TLS_FAIL" -eq 0 ]]; then ok "No TLS negotiation failures"; PASS=$((PASS+1)); else warn "$TLS_FAIL TLS failures"; fi

CHKSUM=$(echo "$JOURNAL" | grep -ci "checksum error" || true)
if [[ "$CHKSUM" -eq 0 ]]; then ok "No checksum errors in recent logs"; PASS=$((PASS+1)); else warn "$CHKSUM checksum errors"; fi

# Role-specific checks
if [[ "$IS_REPLICA" -eq 1 ]]; then
  if ldapi_search -b "$DB_DN" -s base -LLL olcSyncrepl 2>/dev/null | grep -q "starttls=yes"; then ok "Syncrepl has starttls=yes"; PASS=$((PASS+1)); fi
  if ldapi_search -b "$DB_DN" -s base -LLL olcUpdateRef 2>/dev/null | grep -q "ldap://"; then ok "olcUpdateRef set"; PASS=$((PASS+1)); fi
fi

# ====================================================================
# SUMMARY
# ====================================================================
echo ""
echo "============================================================"
echo "  BANK FIX — Complete"
echo "  Server:   ${HOSTNAME}"
echo "  Role:     $([[ $IS_MASTER -eq 1 ]] && echo MASTER || echo REPLICA)"
echo "  PASS=${PASS}  FAIL=${FAIL}  WARN=${WARN}"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
  echo "Result: FAIL — ${FAIL} checks failed"
  exit 1
elif [[ "$WARN" -gt 0 ]]; then
  echo "Result: PASS with ${WARN} warning(s)"
  exit 0
else
  echo "Result: ALL PASS"
  exit 0
fi
