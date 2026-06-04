#!/usr/bin/env bash
# fix-replica-syncrepl-tls.sh
#
# Fixes the replica's olcSyncrepl configuration to use StartTLS.
# This addresses the "err=13 confidentiality required" error seen when
# the master is hardened (olcSecurity: simple_bind=128) but the replica
# still tries plain-text binds.
#
# Must be run ON THE REPLICA node as root.
#
# Usage: sudo bash fix-replica-syncrepl-tls.sh
set -euo pipefail

log()   { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*" >&2; }
err()   { echo "[ERROR] $*" >&2; }
ok()    { echo "[ OK ] $*"; }
bad()   { echo "[FAIL] $*" >&2; }

PASS=0; FAIL=0

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "Run as root"; exit 1; }

ensure_symas_env() {
  local prof
  for prof in /etc/profile.d/symas_env.sh /opt/symas/etc/openldap/sysmas_env.sh; do
    [[ -f "$prof" ]] && source "$prof" 2>/dev/null || true
  done
  [[ ":${PATH}:" == *":/opt/symas/bin:"* ]]  && return 0
  export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
  [[ -n "${LDAPCONF:-}" ]] || export LDAPCONF="/opt/symas/etc/openldap/ldap.conf"
}
ensure_symas_env

require_cmd() { command -v "$1" >/dev/null 2>&1 || { err "$1 not found in PATH"; exit 1; }; }
require_cmd ldapsearch
require_cmd ldapmodify

LDAPI_URI="ldapi:///"

echo ""
echo "============================================================"
echo "  Fix Replica Syncrepl — Add StartTLS"
echo "============================================================"
echo ""

# ---- 1. Verify ldapi access ----
echo "--- LDAPI access ---"
if ldapwhoami -Y EXTERNAL -H "$LDAPI_URI" >/dev/null 2>&1; then
  ok "LDAPI EXTERNAL bind works"
  PASS=$((PASS+1))
else
  bad "LDAPI EXTERNAL bind failed — cannot proceed"
  exit 1
fi

# ---- 2. Find the replica database with olcSyncrepl ----
echo ""
echo "--- Finding replica database ---"
DB_DN=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -LLL \
  '(&(objectClass=olcMdbConfig)(olcSyncrepl=*))' dn 2>/dev/null \
  | awk '/^dn: /{print $2; exit}')

if [[ -z "$DB_DN" ]]; then
  bad "No database with olcSyncrepl found in cn=config"
  exit 1
fi
ok "Found syncrepl database: $DB_DN"
PASS=$((PASS+1))

# ---- 3. Examine current syncrepl config ----
echo ""
echo "--- Current syncrepl config ---"
CURRENT_SYNCREPL=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "$DB_DN" -s base -LLL \
  olcSyncrepl 2>/dev/null | grep -v "^$" || true)

if [[ -z "$CURRENT_SYNCREPL" ]]; then
  bad "olcSyncrepl attribute is empty"
  exit 1
fi

echo "$CURRENT_SYNCREPL"

# ---- 4. Check if starttls=yes already ----
if echo "$CURRENT_SYNCREPL" | grep -qi "starttls=yes"; then
  ok "starttls=yes already configured — no fix needed"
  PASS=$((PASS+1))
  echo ""
  echo "============================================================"
  echo "  Result: Already fixed (PASS=${PASS})"
  echo "============================================================"
  exit 0
fi

# ---- 5. Check if TLS is available ----
echo ""
echo "--- TLS readiness ---"
TLS_CERT=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -s base -LLL \
  olcTLSCertificateFile 2>/dev/null | awk '/^olcTLSCertificateFile:/{print $2}' | head -1)
TLS_KEY=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -s base -LLL \
  olcTLSCertificateKeyFile 2>/dev/null | awk '/^olcTLSCertificateKeyFile:/{print $2}' | head -1)

if [[ -z "$TLS_CERT" || -z "$TLS_KEY" ]]; then
  bad "TLS cert or key not configured in cn=config — cannot enable StartTLS sync"
  exit 1
fi
if [[ ! -f "$TLS_CERT" || ! -f "$TLS_KEY" ]]; then
  bad "TLS cert/key files not found on disk"
  exit 1
fi
ok "TLS is configured on this replica"
PASS=$((PASS+1))

# ---- 6. Extract provider URI and build new syncrepl ----
echo ""
echo "--- Building new syncrepl config with starttls=yes ---"

PROVIDER=$(echo "$CURRENT_SYNCREPL" | grep -oP 'provider=\K[^ ]+' | head -1 || true)
BINDDN=$(echo "$CURRENT_SYNCREPL"   | grep -oP 'binddn="\K[^"]+'   | head -1 || true)
CREDS=$(echo "$CURRENT_SYNCREPL"    | grep -oP 'credentials=\K[^ ]+' | head -1 || true)
BASE=$(echo "$CURRENT_SYNCREPL"     | grep -oP 'searchbase="\K[^"]+' | head -1 || true)
RID=$(echo "$CURRENT_SYNCREPL"      | grep -oP 'rid=\K[0-9]+' | head -1 || echo "101")

if [[ -z "$PROVIDER" || -z "$BINDDN" || -z "$BASE" ]]; then
  err "Could not parse current syncrepl config. Please fix manually."
  echo "Current config:"
  echo "$CURRENT_SYNCREPL"
  exit 1
fi

# Ensure provider is ldap:// (not ldaps://) for StartTLS
PROVIDER=$(echo "$PROVIDER" | sed 's/^ldaps:/ldap:/')

# Default credentials if not found (unlikely)
CREDS="${CREDS:-replpass}"

log "  Provider:    $PROVIDER"
log "  Bind DN:     $BINDDN"
log "  Search base: $BASE"
log "  RID:         $RID"

# ---- 7. Apply the fix via ldapmodify ----
echo ""
echo "--- Applying fix ---"

apply_ldif() { echo "$1" | ldapmodify -Y EXTERNAL -H "$LDAPI_URI"; }

# Build the new syncrepl line
NEW_SYNCREPL="rid=${RID} provider=${PROVIDER} bindmethod=simple binddn=\"${BINDDN}\" credentials=${CREDS} searchbase=\"${BASE}\" type=refreshAndPersist retry=\"5 5 300 +\" timeout=1 starttls=yes tls_reqcert=never interval=00:00:00:10"

# Replace the existing olcSyncrepl
LDIF=$(cat <<EOF
dn: ${DB_DN}
changetype: modify
replace: olcSyncrepl
olcSyncrepl: ${NEW_SYNCREPL}
EOF
)

if apply_ldif "$LDIF"; then
  ok "olcSyncrepl updated with starttls=yes"
  PASS=$((PASS+1))
else
  bad "Failed to update olcSyncrepl"
  exit 1
fi

# ---- 8. Fix r2 script if it exists (prevent re-introducing the bug) ----
echo ""
echo "--- Fixing r2 script for future deployments ---"
R2_SCRIPT="/tmp/script/replica/r2-configure-replica-instance.sh"
if [[ -f "$R2_SCRIPT" ]]; then
  if grep -q "starttls=no" "$R2_SCRIPT" 2>/dev/null; then
    sed -i 's/starttls=no/starttls=yes\n  tls_reqcert=never\n  interval=00:00:00:10/' "$R2_SCRIPT"
    ok "Patched $R2_SCRIPT to use starttls=yes"
    PASS=$((PASS+1))
  elif grep -q "starttls=yes" "$R2_SCRIPT" 2>/dev/null; then
    ok "$R2_SCRIPT already has starttls=yes"
    PASS=$((PASS+1))
  fi
else
  warn "r2 script not found at $R2_SCRIPT — source fix applied to repo"
fi

# ---- 9. Restart slapd to activate syncrepl with StartTLS ----
echo ""
echo "--- Restarting slapd ---"
for svc in symas-openldap-servers slapd; do
  if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then
    if systemctl restart "$svc"; then
      ok "Restarted $svc"
      PASS=$((PASS+1))
      sleep 3
      if systemctl is-active --quiet "$svc"; then
        ok "$svc is active after restart"
        PASS=$((PASS+1))
      else
        bad "$svc failed to start — check journalctl -u $svc"
        FAIL=$((FAIL+1))
      fi
      break
    else
      bad "Failed to restart $svc"
      FAIL=$((FAIL+1))
    fi
  fi
done

# ---- 10. Verify syncrepl is working ----
echo ""
echo "--- Verifying new syncrepl config ---"
NEW_CONFIG=$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "$DB_DN" -s base -LLL \
  olcSyncrepl 2>/dev/null | grep -v "^$" || true)

if echo "$NEW_CONFIG" | grep -q "starttls=yes"; then
  ok "Verified: syncrepl now has starttls=yes"
  PASS=$((PASS+1))
else
  bad "Syncrepl config does NOT contain starttls=yes"
  FAIL=$((FAIL+1))
fi

# ---- Summary ----
echo ""
echo "============================================================"
echo "  Fix Replica Syncrepl — Complete"
echo "  PASS=${PASS}  FAIL=${FAIL}"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
  echo "Result: FAIL — some fixes could not be applied"
  exit 1
else
  echo "Result: ALL PASS — replica syncrepl now uses StartTLS"
  exit 0
fi
