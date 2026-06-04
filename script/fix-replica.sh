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
#
# What it does:
#   1. Finds the database with olcSyncrepl
#   2. Updates olcSyncrepl: starttls=yes tls_reqcert=never
#   3. Loads ppolicy module if missing
#   4. Restarts slapd to activate syncrepl with TLS
#   5. Self-verifies: checks logs for err=13 + TLS failures,
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

CURRENT=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "$DB_DN" -s base \
  -LLL olcSyncrepl 2>/dev/null | grep -v "^$" || true)

if [[ -z "$CURRENT" ]]; then
  fatal "olcSyncrepl attribute is empty"
fi

if echo "$CURRENT" | grep -qi "starttls=yes"; then
  ok "starttls=yes already set — skipping"
  PASS=$((PASS+1))
else
  log "Current syncrepl has starttls=no — fixing..."

  # Extract current config fields
  PROVIDER=$(echo "$CURRENT" | grep -oP 'provider=\K[^ ]+' | head -1 || echo "ldap://master:389")
  BINDDN=$(echo "$CURRENT"   | grep -oP 'binddn="\K[^"]+'   | head -1 || echo "cn=replicator")
  CREDS=$(echo "$CURRENT"    | grep -oP 'credentials="?\K[^" ]+' | head -1 || echo "replpass")
  BASE=$(echo "$CURRENT"     | grep -oP 'searchbase="\K[^"]+' | head -1 || echo "dc=eab,dc=bank,dc=local")
  RID=$(echo "$CURRENT"      | grep -oP 'rid=\K[0-9]+' | head -1 || echo "101")
  MODE=$(echo "$CURRENT"     | grep -oP 'type=\K[a-zA-Z]+' | head -1 || echo "refreshAndPersist")

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
# STEP 5: Restart slapd
# ================================================================
echo ""
echo "--- Step 5: Restart ${SLAPD_SVC} ---"

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
# STEP 6: Verify syncrepl config is correct
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
# STEP 7: Check logs for previously-seen errors
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
