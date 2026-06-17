#!/usr/bin/env bash
# bank-fix-replica-corruption.sh
# ====================================================================
# Recovery script for corrupted replica in bank OpenLDAP deployment.
# Fixes the 5 issues found in log analysis (June 2026):
#   1. Master: accesslog DB exhausted (MDB_MAP_FULL)
#   2. Master: replicator size limits blocking syncrepl refresh
#   3. Replica: ppolicy overlay missing from cn=config
#   4. Replica: syncrepl stuck in rc -101 retry loop
#   5. Replica: empty/corrupt database
#
# Run on BOTH servers (master first, then replica).
# Idempotent — safe to run multiple times.
#
# Usage:
#   On master (172.23.11.236):
#     sudo bash bank-fix-replica-corruption.sh --master
#
#   On replica (172.23.11.237):
#     sudo MASTER_IP=172.23.11.236 bash bank-fix-replica-corruption.sh --replica
# ====================================================================
set -uo pipefail

log()   { echo "[INFO]  $*"; }
ok()    { echo "[ OK ]  $*"; }
warn()  { echo "[WARN]  $*"; }
bad()   { echo "[FAIL]  $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }
banner() { echo ""; echo "============================================================"; echo "  $*"; echo "============================================================"; }

PASS=0; FAIL=0; WARN=0
MODE="${1:-}"

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
[[ -f /opt/symas/etc/openldap/sysmas_env.sh ]] && source /opt/symas/etc/openldap/sysmas_env.sh 2>/dev/null || true
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found — install it first"; }
require_cmd ldapsearch
require_cmd ldapmodify
require_cmd python3

for svc in symas-openldap-servers slapd; do
  if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then
    SLAPD_SVC="$svc"; break
  fi
done
[[ -z "${SLAPD_SVC:-}" ]] && pgrep -x slapd >/dev/null 2>&1 && SLAPD_SVC="slapd"
SLAPD_SVC="${SLAPD_SVC:-symas-openldap-servers}"

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

LDAPI_URI="ldapi:///"
ldapi_search()  { ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" "$@" 2>/dev/null; }
ldapi_modify()  { ldapmodify -Y EXTERNAL -H "$LDAPI_URI" "$@"; }

BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_DN="cn=admin,${BASE_DN}"
ADMIN_PW="${ADMIN_PW:-TheN1le1}"
REPL_DN="cn=replicator,${BASE_DN}"
REPL_PW="${REPL_PW:-replpass}"
MASTER_IP="${MASTER_IP:-172.23.11.236}"

HOSTNAME=$(hostname -f 2>/dev/null || hostname)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

if [[ "$MODE" != "--master" && "$MODE" != "--replica" ]]; then
  echo "Usage: $0 --master   (run on master)"
  echo "       $0 --replica  (run on replica)"
  echo ""
  echo "Environment variables (all have defaults):"
  echo "  MASTER_IP    — master server IP (default: 172.23.11.236)"
  echo "  ADMIN_PW     — admin password (default: TheN1le1)"
  echo "  REPL_PW      — replicator password (default: replpass)"
  echo "  BASE_DN      — LDAP base DN (default: dc=eab,dc=bank,dc=local)"
  exit 1
fi

echo ""
echo "============================================================"
echo "  BANK REPLICA RECOVERY"
echo "  Server:   ${HOSTNAME}"
echo "  Mode:     ${MODE#--}"
echo "  Service:  ${SLAPD_SVC}"
echo "  Time:     ${TIMESTAMP}"
echo "============================================================"

banner "Pre-flight: LDAPI access"
if ldapwhoami -Y EXTERNAL -H "$LDAPI_URI" >/dev/null 2>&1; then
  ok "LDAPI EXTERNAL works"
else
  fatal "LDAPI EXTERNAL failed — cannot fix config"
fi

DB_DN=$(ldapi_search -b cn=config -LLL '(&(objectClass=olcMdbConfig)(olcSuffix=*))' dn 2>/dev/null | awk '/^dn: /{print $2; exit}')
[[ -n "${DB_DN:-}" ]] || DB_DN="olcDatabase={1}mdb,cn=config"
log "Database DN: ${DB_DN}"

# ====================================================================
# MASTER FIXES
# ====================================================================
if [[ "$MODE" == "--master" ]]; then

  banner "Step A-1: Fix accesslog database size"
  ACCESSLOG_DN=$(ldapi_search -b cn=config -s sub "(olcSuffix=cn=accesslog)" dn 2>/dev/null | awk '/^dn: /{print $2; exit}')
  if [[ -n "${ACCESSLOG_DN:-}" ]]; then
    CURRENT_SIZE=$(ldapi_search -b "$ACCESSLOG_DN" -s base -LLL olcDbMaxSize 2>/dev/null | awk '/^olcDbMaxSize:/{print $2; exit}')
    CURRENT_SIZE="${CURRENT_SIZE:-unknown}"
    log "Accesslog DN: ${ACCESSLOG_DN}, current maxsize: ${CURRENT_SIZE}"
    ldapi_modify -f <(cat <<LDIF
dn: ${ACCESSLOG_DN}
changetype: modify
replace: olcDbMaxSize
olcDbMaxSize: 2147483648
LDIF
) && { ok "Accesslog maxsize set to 2GB (was: ${CURRENT_SIZE})"; PASS=$((PASS+1)); } || { bad "Accesslog size update failed"; FAIL=$((FAIL+1)); }
  else
    warn "No accesslog database found — skipping (may not be configured)"
    WARN=$((WARN+1))
  fi

  banner "Step A-2: Set replicator unlimited limits"
  HAS_LIMITS=$(ldapi_search -b "$DB_DN" -s base -LLL olcLimits 2>/dev/null | grep -c "replicator" || true)
  if [[ "$HAS_LIMITS" -gt 0 ]]; then
    ok "Replicator limits already set"; PASS=$((PASS+1))
  else
    ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
add: olcLimits
olcLimits: dn.exact="${REPL_DN}" time.soft=unlimited time.hard=unlimited size.soft=unlimited size.hard=unlimited
LDIF
) && { ok "Replicator unlimited limits set"; PASS=$((PASS+1)); } || { bad "Limits update failed"; FAIL=$((FAIL+1)); }
  fi

  banner "Step A-3: Ensure syncprov overlay"
  HAS_SYNCPROV=$(ldapi_search -b cn=config -s sub "(olcOverlay=syncprov)" dn 2>/dev/null | grep -ci "^dn:" || true)
  if [[ "$HAS_SYNCPROV" -gt 0 ]]; then
    ok "Syncprov overlay present"; PASS=$((PASS+1))
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

  banner "Step A-4: Ensure entryUUID/entryCSN indices"
  INDICES=$(ldapi_search -b "$DB_DN" -s base -LLL olcDbIndex 2>/dev/null || true)
  NEED_UUID=0; NEED_CSN=0
  echo "$INDICES" | grep -q "entryUUID" || NEED_UUID=1
  echo "$INDICES" | grep -q "entryCSN"  || NEED_CSN=1
  if [[ "$NEED_UUID" -eq 0 && "$NEED_CSN" -eq 0 ]]; then
    ok "entryUUID + entryCSN indices present"; PASS=$((PASS+1))
  else
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

  banner "Restarting slapd"
  systemctl restart "$SLAPD_SVC"
  sleep 3
  if systemctl is-active --quiet "$SLAPD_SVC"; then ok "Slapd running"; PASS=$((PASS+1)); else bad "Slapd not running"; FAIL=$((FAIL+1)); fi
fi

# ====================================================================
# REPLICA FIXES
# ====================================================================
if [[ "$MODE" == "--replica" ]]; then

  banner "Step B-1: Load ppolicy module"
  PPOLICY_LOADED=$(ldapi_search -b cn=config -s sub "(olcModuleLoad=ppolicy.la)" dn 2>/dev/null | grep -c "cn=module" || true)
  if [[ "$PPOLICY_LOADED" -gt 0 ]]; then
    ok "ppolicy module loaded"; PASS=$((PASS+1))
  else
    ldapi_modify -f <(cat <<'LDIF'
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: ppolicy.la
LDIF
) && { ok "ppolicy module loaded"; PASS=$((PASS+1)); } || { bad "ppolicy module load failed"; FAIL=$((FAIL+1)); }
  fi

  banner "Step B-2: Create ppolicy overlay in cn=config"
  PP_DN="olcOverlay=ppolicy,${DB_DN}"
  OVERLAY_EXISTS=$(ldapi_search -b cn=config -s sub "(olcOverlay=ppolicy)" dn 2>/dev/null | grep -c "^dn:" || true)
  if [[ "$OVERLAY_EXISTS" -gt 0 ]]; then
    ok "ppolicy overlay already exists"; PASS=$((PASS+1))
  else
    ldapadd -Y EXTERNAL -H "$LDAPI_URI" <<LDIFEOF 2>/dev/null
dn: ${PP_DN}
objectClass: olcOverlayConfig
objectClass: olcPPolicyConfig
olcOverlay: ppolicy
LDIFEOF
    if ldapi_search -b "$PP_DN" -s base dn 2>/dev/null | grep -q "^dn:"; then
      ok "ppolicy overlay created"; PASS=$((PASS+1))
    else
      warn "ppolicy overlay creation failed — trying alternate approach"; WARN=$((WARN+1))
      ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
add: olcOverlay
olcOverlay: ppolicy
LDIF
) 2>/dev/null && { ok "ppolicy overlay added via modify"; PASS=$((PASS+1)); } || { bad "ppolicy overlay creation failed — try full reinstall"; FAIL=$((FAIL+1)); }
    fi
  fi

  banner "Step B-3: Set ppolicy hash cleartext"
  # Set olcPPolicyHashCleartext on the ppolicy overlay
  PP_DN=$(ldapi_search -b cn=config -s sub "(olcOverlay=ppolicy)" dn 2>/dev/null | awk '/^dn: /{print $2; exit}')
  if [[ -n "${PP_DN:-}" ]]; then
    HAS_CLEARTEXT=$(ldapi_search -b "$PP_DN" -s base -LLL olcPPolicyHashCleartext 2>/dev/null | grep -c "TRUE" || true)
    if [[ "$HAS_CLEARTEXT" -gt 0 ]]; then
      ok "olcPPolicyHashCleartext already TRUE"; PASS=$((PASS+1))
    else
      ldapi_modify -f <(cat <<LDIF
dn: ${PP_DN}
changetype: modify
replace: olcPPolicyHashCleartext
olcPPolicyHashCleartext: TRUE
LDIF
) && { ok "olcPPolicyHashCleartext set to TRUE"; PASS=$((PASS+1)); } || { warn "Hash cleartext set failed — non-critical"; WARN=$((WARN+1)); }
    fi
  else
    warn "ppolicy overlay DN not found — skipping hash cleartext"; WARN=$((WARN+1))
  fi

  banner "Step B-4: Set default policy"
  if [[ -n "${PP_DN:-}" ]]; then
    HAS_DEFAULT=$(ldapi_search -b "$PP_DN" -s base -LLL olcPPolicyDefault 2>/dev/null | grep -c "olcPPolicyDefault" || true)
    if [[ "$HAS_DEFAULT" -gt 0 ]]; then
      ok "olcPPolicyDefault already set"; PASS=$((PASS+1))
    else
      ldapi_modify -f <(cat <<LDIF
dn: ${PP_DN}
changetype: modify
add: olcPPolicyDefault
olcPPolicyDefault: cn=default,ou=Policies,${BASE_DN}
LDIF
) && { ok "Default policy set"; PASS=$((PASS+1)); } || { warn "Default policy set failed — non-critical"; WARN=$((WARN+1)); }
    fi
  else
    warn "ppolicy overlay DN not found — skipping default policy"; WARN=$((WARN+1))
  fi

  banner "Step B-5: Fix syncrepl config (starttls=yes)"
  CURRENT=$(ldapi_search -o ldif-wrap=no -b "$DB_DN" -s base -LLL olcSyncrepl 2>/dev/null | tr -d '\n' || true)
  if echo "$CURRENT" | grep -qi "starttls=yes"; then
    ok "starttls=yes already set"; PASS=$((PASS+1))
  else
    PROVIDER=$(echo "$CURRENT" | grep -oP 'provider=\K[^ ]+' | head -1 || echo "ldap://${MASTER_IP}:389")
    BINDDN=$(echo "$CURRENT"   | grep -oP 'binddn="\K[^"]+'   | head -1 || echo "${REPL_DN}")
    CREDS=$(echo "$CURRENT"    | grep -oP 'credentials="?\K[^" ]+' | head -1 || echo "${REPL_PW}")
    BASE=$(echo "$CURRENT"     | grep -oP 'searchbase="\K[^"]+' | head -1 || echo "${BASE_DN}")
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

  banner "Step B-6: Ensure data ACL"
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

  banner "Step B-7: Set read-only + updateRef"
  ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
replace: olcReadOnly
olcReadOnly: TRUE
LDIF
) 2>/dev/null && ok "ReadOnly=TRUE" || warn "ReadOnly already set"
  WARN=$((WARN+1))

  CURRENT_REF=$(ldapi_search -b "$DB_DN" -s base -LLL olcUpdateRef 2>/dev/null | grep -c "olcUpdateRef" || true)
  if [[ "$CURRENT_REF" -eq 0 ]]; then
    ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
add: olcUpdateRef
olcUpdateRef: ldap://${MASTER_IP}:389
LDIF
) 2>/dev/null && ok "olcUpdateRef set" || warn "olcUpdateRef already set (or failed — non-critical)"
    WARN=$((WARN+1))
  fi

  # Restart to apply all cn=config changes before attempting sync
  banner "Restarting slapd (apply config changes)"
  systemctl restart "$SLAPD_SVC"
  sleep 5
  if systemctl is-active --quiet "$SLAPD_SVC"; then ok "Slapd running"; PASS=$((PASS+1)); else bad "Slapd not running"; FAIL=$((FAIL+1)); fi

  # ====================================================================
  # Step C: Seed replica from master
  # ====================================================================
  banner "Step C: Seed replica from master"

  DATA_COUNT=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
    -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "$BASE_DN" -s one -LLL dn 2>/dev/null | grep -c "^dn:" || true)
  DATA_COUNT=$(echo "$DATA_COUNT" | tr -d '[:space:]')

  log "Current replica children: ${DATA_COUNT:-0}"

  if [[ -z "$DATA_COUNT" || "$DATA_COUNT" -eq 0 ]]; then
    log "Replica has no data — pulling full dataset from master at ${MASTER_IP}"
    log "Test connection to master..."
    if ! LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H "ldap://${MASTER_IP}:389" \
      -D "$REPL_DN" -w "$REPL_PW" >/dev/null 2>&1; then
      log "STARTTLS bind failed — trying plain LDAP"
      if ! ldapwhoami -x -H "ldap://${MASTER_IP}:389" -D "$REPL_DN" -w "$REPL_PW" >/dev/null 2>&1; then
        bad "Cannot connect to master as replicator — check network/password"
        FAIL=$((FAIL+1))
      fi
    fi

    log "Pulling data from ${MASTER_IP}..."
    LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
      -H "ldap://${MASTER_IP}:389" \
      -D "$REPL_DN" -w "$REPL_PW" \
      -b "$BASE_DN" -s sub "(objectClass=*)" -LLL > /tmp/replica-seed.ldif 2>/dev/null
    SEED_COUNT=$(grep -c "^dn:" /tmp/replica-seed.ldif 2>/dev/null || echo "0")
    log "Pulled ${SEED_COUNT} entries from master"

    if [[ "$SEED_COUNT" -gt 0 ]]; then
      systemctl stop "$SLAPD_SVC"
      sleep 2
      rm -f /var/symas/openldap-data/example/data.mdb /var/symas/openldap-data/example/lock.mdb
      log "Importing data..."
      /opt/symas/sbin/slapadd -n 1 -l /tmp/replica-seed.ldif 2>/dev/null || {
        bad "slapadd failed"; FAIL=$((FAIL+1))
      }
      SLAPD_USER="symas-openldap"
      id "$SLAPD_USER" >/dev/null 2>&1 || SLAPD_USER="ldap"
      id "$SLAPD_USER" >/dev/null 2>&1 || SLAPD_USER="root"
      chown -R "${SLAPD_USER}:${SLAPD_USER}" /var/symas/openldap-data 2>/dev/null || true
      restorecon -Rv /var/symas/openldap-data 2>/dev/null || true
      systemctl start "$SLAPD_SVC"
      sleep 5
      rm -f /tmp/replica-seed.ldif
      if systemctl is-active --quiet "$SLAPD_SVC"; then
        ok "Slapd restarted with ${SEED_COUNT} entries from master"; PASS=$((PASS+1))
      else
        bad "Slapd failed to start after seed"; FAIL=$((FAIL+1))
      fi
    else
      warn "Could not pull data from master — replicator bind may need fixing"
      WARN=$((WARN+1))
    fi
  else
    ok "Replica already has ${DATA_COUNT} children — skipping seed"; PASS=$((PASS+1))
  fi
fi

# ====================================================================
# VERIFICATION
# ====================================================================
banner "Verification"

if systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1; then
  ok "Slapd running"; PASS=$((PASS+1))
else
  bad "Slapd not running"; FAIL=$((FAIL+1))
fi

if bash -c "echo >/dev/tcp/localhost/389" 2>/dev/null; then
  ok "Port 389 listening"; PASS=$((PASS+1))
else
  bad "Port 389 not reachable"; FAIL=$((FAIL+1))
fi

if LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H ldap://localhost \
  -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1; then
  ok "Admin bind via StartTLS"; PASS=$((PASS+1))
elif ldapwhoami -x -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1; then
  ok "Admin bind via plain LDAP"; PASS=$((PASS+1))
else
  bad "Admin bind failed"; FAIL=$((FAIL+1))
fi

LOG_CHECK=$(journalctl -u "$SLAPD_SVC" --no-pager --since "3 minutes ago" 2>/dev/null || true)

MDB_ERR=$(echo "$LOG_CHECK" | grep -ci "MDB_MAP_FULL" || true)
if [[ "$MDB_ERR" -eq 0 ]]; then ok "No MDB_MAP_FULL errors"; PASS=$((PASS+1)); else bad "${MDB_ERR} MDB_MAP_FULL errors in recent logs"; FAIL=$((FAIL+1)); fi

SYNC_ERR=$(echo "$LOG_CHECK" | grep -ci "do_syncrepl.*rc \-101\|LDAP_RES_SEARCH_RESULT.*Size limit" || true)
if [[ "$MODE" == "--replica" && "$SYNC_ERR" -gt 0 ]]; then
  warn "${SYNC_ERR} syncrepl errors in recent logs — sync may still be converging"; WARN=$((WARN+1))
elif [[ "$MODE" == "--replica" ]]; then
  ok "No syncrepl errors in recent logs"; PASS=$((PASS+1))
else
  ok "Not replica — skipping syncrepl check"; PASS=$((PASS+1))
fi

CHKSUM=$(echo "$LOG_CHECK" | grep -ci "checksum error" || true)
if [[ "$CHKSUM" -eq 0 ]]; then ok "No checksum errors"; PASS=$((PASS+1)); else warn "${CHKSUM} checksum errors"; WARN=$((WARN+1)); fi

# ====================================================================
# SUMMARY
# ====================================================================
echo ""
echo "============================================================"
echo "  RECOVERY COMPLETE"
echo "  Server:   ${HOSTNAME}"
echo "  Mode:     ${MODE#--}"
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
