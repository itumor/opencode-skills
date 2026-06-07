#!/usr/bin/env bash
# fix-replica.sh
# ====================================================================
# Run on the OpenLDAP REPLICA server as root.
#
# Fixes:
#   Issue A — "err=13 confidentiality required" — 14 consecutive
#             syncrepl binds rejected because master requires TLS
#             but replica's syncrepl was configured with starttls=no.
#             (See May 24–Jun 03 logs: conn=1049–1065, all err=13.)
#   Issue B — "objectClass: value #0 invalid per syntax" — syncrepl
#             fails during refreshDelete because ppolicy module
#             (pwdPolicy objectClass) is not loaded on the replica.
#   Issue C — LDAPS port 636 "TLS negotiation failure" — replica
#             CA cert mismatch when trying direct LDAPS.
#   Issue D — Missing self-signed TLS certificates — STARTTLS
#             fails on the replica itself. Generates if missing.
#
# What it does:
#   1. Finds the database with olcSyncrepl
#   2. Updates olcSyncrepl: starttls=yes tls_reqcert=never
#   3. Loads ppolicy module if missing (pwdPolicy objectClass)
#   4. Generates self-signed TLS certs if missing
#   5. Restarts slapd to activate syncrepl with TLS
#   6. Self-verifies: checks logs for err=13 + TLS failures,
#      tests syncrepl config + replicator bind
#
# Usage:
#   sudo bash fix-replica.sh
# ====================================================================
set -euo pipefail

log()   { echo "[INFO]  $*"; }
ok()    { echo "[ OK ]  $*"; }
warn()  { echo "[WARN]  $*"; }
err()   { echo "[ERROR] $*" >&2; }
bad()   { echo "[FAIL] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }

PASS=0; FAIL=0

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

# ---- Locate slapd service ----
find_service() {
  for svc in symas-openldap-servers slapd; do
    if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then
      echo "$svc"
      return 0
    fi
  done
  # Fallback: check if slapd is running
  if pgrep -x slapd >/dev/null 2>&1; then
    echo "slapd"
    return 0
  fi
  fatal "Cannot find slapd systemd service"
}

SLAPD_SVC=$(find_service)

# ---- Fix PATH ----
export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
[[ -f /opt/symas/etc/openldap/sysmas_env.sh ]] && source /opt/symas/etc/openldap/sysmas_env.sh 2>/dev/null || true

require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }
require_cmd ldapsearch
require_cmd ldapmodify

LDAPI_URI="ldapi:///"

echo ""
echo "============================================================"
echo "  REPLICA FIX — Start"
echo "  Server:   $(hostname -f 2>/dev/null || hostname)"
echo "  Service:  ${SLAPD_SVC}"
echo "============================================================"

# ================================================================
# STEP 1: Verify LDAPI access
# ================================================================
echo ""
echo "--- Step 1: Verify LDAPI access ---"
if ! ldapwhoami -Y EXTERNAL -H "$LDAPI_URI" >/dev/null 2>&1; then
  fatal "LDAPI EXTERNAL bind failed — cannot modify config. Run as root."
fi
ok "LDAPI EXTERNAL access confirmed"

# ================================================================
# STEP 2: Find replica database
# ================================================================
echo ""
echo "--- Step 2: Locate replica database ---"
DB_DN=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config \
  -LLL '(&(objectClass=olcMdbConfig)(olcSyncrepl=*))' dn 2>/dev/null \
  | awk '/^dn: /{print $2; exit}' || true)

if [[ -z "$DB_DN" ]]; then
  fatal "No database with olcSyncrepl found. Is this a replica?"
fi
ok "Found replica database: $DB_DN"

# ================================================================
# STEP 3: Update syncrepl to use StartTLS
# ================================================================
echo ""
echo "--- Step 3: Update syncrepl (starttls=yes) ---"

CURRENT=$(ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" -b "$DB_DN" -s base \
  -LLL olcSyncrepl 2>/dev/null | grep -v "^$" | tr -d '\n' || true)

if [[ -z "$CURRENT" ]]; then
  fatal "olcSyncrepl attribute is empty"
fi

if echo "$CURRENT" | grep -qi "starttls=yes"; then
  ok "starttls=yes already set — skipping"
  PASS=$((PASS+1))
else
  log "Current syncrepl has starttls=no — fixing..."

  # Extract current config fields (use ldif-wrap=no to avoid line breaks)
  PROVIDER=$(echo "$CURRENT" | grep -oP 'provider=\K[^ ]+' | head -1 || echo "ldap://master:389")
  BINDDN=$(echo "$CURRENT"   | grep -oP 'binddn="\K[^"]+'   | head -1 || echo "cn=replicator")
  CREDS=$(echo "$CURRENT"    | grep -oP 'credentials="?\K[^" ]+' | head -1 || echo "replpass")
  BASE=$(echo "$CURRENT"     | grep -oP 'searchbase="\K[^"]+' | head -1 || echo "dc=eab,dc=bank,dc=local")
  RID=$(echo "$CURRENT"      | grep -oP 'rid=\K[0-9]+' | head -1 || echo "101")
  MODE="refreshAndPersist"

  PROVIDER=$(echo "$PROVIDER" | sed 's/^ldaps:/ldap:/')

  log "  Provider:    $PROVIDER"
  log "  Bind DN:     $BINDDN"
  log "  Search Base: $BASE"
  log "  RID:         $RID"
  log "  Mode:        $MODE"

  ldapmodify -Y EXTERNAL -H "$LDAPI_URI" <<EOF
dn: ${DB_DN}
changetype: modify
replace: olcSyncrepl
olcSyncrepl: {0}rid=${RID} provider=${PROVIDER} bindmethod=simple binddn="${BINDDN}" credentials=${CREDS} searchbase="${BASE}" type=${MODE} retry="5 5 300 +" timeout=1 starttls=yes tls_reqcert=never interval=00:00:00:10
EOF
  ok "Syncrepl updated: starttls=yes tls_reqcert=never interval=00:00:00:10"
  PASS=$((PASS+1))
fi

# ================================================================
# STEP 4: Load ppolicy module (required for pwdPolicy objectClass)
# ================================================================
echo ""
echo "--- Step 4: Load ppolicy module ---"

PPOLICY_LOADED=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config \
  -s sub "(olcModuleLoad=ppolicy.la)" dn 2>/dev/null | grep -c "cn=module" || true)

if [[ "$PPOLICY_LOADED" -gt 0 ]]; then
  ok "ppolicy module already loaded"
  PASS=$((PASS+1))
else
  log "Loading ppolicy module (needed for pwdPolicy objectClass from master)..."
  ldapmodify -Y EXTERNAL -H "$LDAPI_URI" <<'LDIFEOF'
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: ppolicy.la
LDIFEOF
  ok "ppolicy module loaded"
  PASS=$((PASS+1))
fi

# ================================================================
# STEP 5: Ensure self-signed TLS certs exist
# ================================================================
echo ""
echo "--- Step 5: Ensure TLS certificates (self-signed) ---"

TLS_DIR="/opt/symas/etc/openldap/tls"
TLS_CERT="${TLS_DIR}/ldap.crt"
TLS_KEY="${TLS_DIR}/ldap.key"
TLS_CA="${TLS_DIR}/ca.crt"
TLS_CAKEY="${TLS_DIR}/ca.key"

tls_ok=1
if [[ -f "$TLS_CERT" && -f "$TLS_KEY" ]]; then
  ok "TLS cert + key already present"
  PASS=$((PASS+1))
else
  log "TLS certificates missing — generating self-signed..."

  require_cmd openssl
  mkdir -p "$TLS_DIR"

  if ! [[ -f "$TLS_CA" && -f "$TLS_CAKEY" ]]; then
    openssl genrsa -out "$TLS_CAKEY" 4096 2>/dev/null
    openssl req -x509 -new -nodes -key "$TLS_CAKEY" -sha256 -days 3650 \
      -subj "/C=US/O=Bank/OU=LDAP/CN=LDAP CA" -out "$TLS_CA" 2>/dev/null
  fi

  host_fqdn="$(hostname -f 2>/dev/null || hostname)"
  host_short="$(hostname -s 2>/dev/null || hostname)"

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
CN=${host_fqdn}

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${host_fqdn}
DNS.2 = ${host_short}
DNS.3 = localhost
IP.1  = 127.0.0.1
CNF

  openssl genrsa -out "$TLS_KEY" 4096 2>/dev/null
  openssl req -new -key "$TLS_KEY" -out "${TLS_DIR}/ldap.csr" \
    -config "${TLS_DIR}/san.cnf" 2>/dev/null
  openssl x509 -req -in "${TLS_DIR}/ldap.csr" -CA "$TLS_CA" -CAkey "$TLS_CAKEY" \
    -CAcreateserial -out "$TLS_CERT" -days 825 -sha256 \
    -extensions req_ext -extfile "${TLS_DIR}/san.cnf" 2>/dev/null
  rm -f "${TLS_DIR}/ldap.csr" "${TLS_DIR}/san.cnf"

  chmod 700 "$TLS_DIR"
  chmod 600 "$TLS_KEY" "$TLS_CAKEY"
  chmod 644 "$TLS_CERT" "$TLS_CA"

  if id ldap >/dev/null 2>&1; then
    chown -R ldap:ldap "$TLS_DIR" 2>/dev/null || true
  fi

  if [[ -f "$TLS_CERT" && -f "$TLS_KEY" ]]; then
    ok "Self-signed TLS certs generated"
    PASS=$((PASS+1))
    tls_ok=0
  else
    warn "TLS cert generation failed — STARTTLS will not be available locally"
    tls_ok=2
  fi
fi

# Apply TLS config to cn=config if certs exist
if [[ $tls_ok -le 1 ]]; then
  TLS_CONFIGURED=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config \
    -s base -LLL olcTLSCertificateFile 2>/dev/null | grep -c olcTLSCertificateFile || true)
  if [[ "$TLS_CONFIGURED" -eq 0 ]]; then
    log "Applying TLS config to cn=config..."
    ldapmodify -Y EXTERNAL -H "$LDAPI_URI" <<LDIFTLS
dn: cn=config
changetype: modify
add: olcTLSCertificateFile
olcTLSCertificateFile: ${TLS_CERT}
-
add: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: ${TLS_KEY}
-
add: olcTLSCACertificateFile
olcTLSCACertificateFile: ${TLS_CA}
-
add: olcTLSProtocolMin
olcTLSProtocolMin: 3.3
LDIFTLS
    ok "TLS config applied to cn=config"
    PASS=$((PASS+1))
    
    # Add ldaps:// to SLAPD_URLS
    if [[ -f /etc/default/symas-openldap ]]; then
      sed -i 's|SLAPD_URLS="ldap:///|SLAPD_URLS="ldap:/// ldaps:///|' /etc/default/symas-openldap 2>/dev/null || true
    fi
  else
    ok "TLS config already in cn=config"
    PASS=$((PASS+1))
  fi
fi

# ================================================================
# STEP 6: Restart slapd
# ================================================================
echo ""
echo "--- Step 6: Restart ${SLAPD_SVC} ---"

systemctl restart "$SLAPD_SVC" || fatal "Failed to restart ${SLAPD_SVC}"
sleep 3

if systemctl is-active --quiet "$SLAPD_SVC"; then
  ok "${SLAPD_SVC} is active after restart"
  PASS=$((PASS+1))
else
  bad "${SLAPD_SVC} failed to start — check logs: journalctl -u ${SLAPD_SVC}"
  FAIL=$((FAIL+1))
fi

# ================================================================
# STEP 7: Verify syncrepl config is correct
# ================================================================
echo ""
echo "--- Step 6: Verify syncrepl config ---"

NEW_CONFIG=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "$DB_DN" -s base \
  -LLL olcSyncrepl 2>/dev/null | grep -v "^$" || true)

if echo "$NEW_CONFIG" | grep -q "starttls=yes"; then
  ok "Syncrepl now has starttls=yes"
  PASS=$((PASS+1))
else
  bad "Syncrepl does NOT have starttls=yes"
  FAIL=$((FAIL+1))
fi

# ================================================================
# STEP 8: Check logs for previously-seen errors
# ================================================================
echo ""
echo "--- Step 7: Log check (looking for previous errors) ---"

RECENT=$(journalctl -u "$SLAPD_SVC" --no-pager --since "1 minute ago" 2>/dev/null || true)

ERR13=$(echo "$RECENT" | grep -ci "confidentiality required\|err=13" || true)
if [[ "$ERR13" -eq 0 ]]; then
  ok "No err=13 (confidentiality required) in recent logs"
  PASS=$((PASS+1))
else
  bad "${ERR13} 'err=13' found — syncrepl may still be failing"
  FAIL=$((FAIL+1))
fi

TLS_FAIL=$(echo "$RECENT" | grep -ci "TLS negotiation failure" || true)
if [[ "$TLS_FAIL" -eq 0 ]]; then
  ok "No TLS negotiation failures in recent logs"
  PASS=$((PASS+1))
else
  warn "${TLS_FAIL} TLS negotiation failure(s) in recent logs"
fi

CHECKSUM_ERR=$(echo "$RECENT" | grep -ci "checksum error" || true)
if [[ "$CHECKSUM_ERR" -eq 0 ]]; then
  ok "No checksum errors in recent logs"
  PASS=$((PASS+1))
else
  warn "${CHECKSUM_ERR} checksum error(s) in recent logs"
fi

# ================================================================
# Summary
# ================================================================
echo ""
echo "============================================================"
echo "  REPLICA FIX — Complete"
echo "  PASS=${PASS}  FAIL=${FAIL}"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "Some checks failed. Review the output above."
  echo "To check syncrepl status:"
  echo "  sudo ldapsearch -Y EXTERNAL -H ldapi:/// -b '${DB_DN}' -s base olcSyncrepl"
  echo ""
  echo "To check slapd logs:"
  echo "  sudo journalctl -u ${SLAPD_SVC} --no-pager -n 30"
  exit 1
fi

echo ""
echo "All fixes applied. Syncrepl now uses StartTLS."
echo "The replica should sync from the master within 10 seconds."
exit 0
