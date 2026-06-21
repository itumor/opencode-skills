#!/usr/bin/env bash
# 29-fix-mw-acl-idle.sh
# ====================================================================
# Fixes MW (middleware) service account ACL and idle connection timeout.
#
# What this does:
#   1. Corrects MW ACL — write access to ou=Users + userPassword
#      (replaces old "read write" invalid syntax with valid "write")
#   2. Sets olcIdleTimeout=0 on cn=config — never kill idle connections
#      Falls back to 86400 (24h) if 0 is rejected by this Symas build.
#   3. Enables olcMonitoring=TRUE on cn=monitor for connection tracking.
#   4. Verifies all changes took effect.
#
# Run as root on master AND replica:
#   sudo bash 29-fix-mw-acl-idle.sh
# ====================================================================
set -euo pipefail

log()   { echo "[INFO]  $*"; }
ok()    { echo "[ OK ]  $*"; }
warn()  { echo "[WARN]  $*"; }
bad()   { echo "[FAIL]  $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }
banner() { echo ""; echo "=== $* ==="; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }

PASS=0; FAIL=0; WARN=0

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root (required for ldapi:/// SASL/EXTERNAL)"

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
[[ -f /opt/symas/etc/openldap/sysmas_env.sh ]] && source /opt/symas/etc/openldap/sysmas_env.sh 2>/dev/null || true

require_cmd ldapsearch
require_cmd ldapmodify

BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_DN="cn=admin,${BASE_DN}"
MW_DN="uid=mw,ou=ServiceAccounts,ou=Systems,${BASE_DN}"
REPL_DN="cn=replicator,${BASE_DN}"

LDAPI_URI="${LDAPI_URI:-ldapi:///}"
ldapi_search()  { ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -o ldif-wrap=no "$@" 2>/dev/null; }
ldapi_modify()  { ldapmodify -Y EXTERNAL -H "$LDAPI_URI" "$@"; }

echo ""
echo "============================================================"
echo "  MW ACL + Idle Timeout Fix"
echo "  Server: $(hostname -f 2>/dev/null || hostname)"
echo "  Base DN: ${BASE_DN}"
echo "============================================================"

# ---- Pre-flight: LDAPI access ----
banner "Pre-flight: LDAPI access"
if ldapwhoami -Y EXTERNAL -H "$LDAPI_URI" >/dev/null 2>&1; then
    ok "LDAPI EXTERNAL works"
else
    fatal "LDAPI EXTERNAL failed — cannot modify config"
fi

# ---- Detect database DN ----
banner "Database detection"
DB_DN=$(ldapi_search -b cn=config -s sub '(&(objectClass=olcMdbConfig)(olcSuffix=*))' dn | awk '/^dn: /{print $2; exit}')
[[ -n "$DB_DN" ]] || fatal "Could not locate MDB database DN"
log "Database DN: ${DB_DN}"

# Detect role (master vs replica)
HAS_SYNCREPL=$(ldapi_search -b "$DB_DN" -s base -LLL olcSyncrepl 2>/dev/null | grep -ci olcSyncrepl || true)
if [[ "$HAS_SYNCREPL" -gt 0 ]]; then
    log "Role: REPLICA"
else
    log "Role: MASTER"
fi

# ====================================================================
# FIX 1: Correct MW ACL
# ====================================================================
banner "Fix 1: MW ACL — write to ou=Users + userPassword"

ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword by dn.exact="${ADMIN_DN}" write by sockurl.exact="ldapi:///" write by dn.exact="${MW_DN}" write by self write by anonymous auth by * none
olcAccess: {1}to * by dn.exact="${ADMIN_DN}" write by sockurl.exact="ldapi:///" write by * continue
olcAccess: {2}to * by dn.exact="${REPL_DN}" read by * break
olcAccess: {3}to dn.subtree="ou=Users,${BASE_DN}" by dn.exact="${MW_DN}" write by * break
olcAccess: {4}to * by self read by dn.exact="${MW_DN}" read by * none
LDIF
) && { ok "MW ACL configured"; PASS=$((PASS+1)); } || { bad "MW ACL failed"; FAIL=$((FAIL+1)); }

# ====================================================================
# FIX 2: Idle timeout = 0 (never kill)
# ====================================================================
banner "Fix 2: Idle timeout = 0"

if ldapi_modify -f <(cat <<'LDIF'
dn: cn=config
changetype: modify
replace: olcIdleTimeout
olcIdleTimeout: 0
LDIF
) 2>/dev/null; then
    ok "olcIdleTimeout: 0"; PASS=$((PASS+1))
else
    warn "olcIdleTimeout: 0 rejected (error 80) — trying 86400 (24h)"
    if ldapi_modify -f <(cat <<'LDIF'
dn: cn=config
changetype: modify
replace: olcIdleTimeout
olcIdleTimeout: 86400
LDIF
) 2>/dev/null; then
        ok "olcIdleTimeout: 86400 (24h)"; PASS=$((PASS+1))
    else
        warn "olcIdleTimeout not supported in this Symas build — idle connections managed by OS TCP keepalive"
        WARN=$((WARN+1))
    fi
fi

# ====================================================================
# FIX 3: Enable cn=Monitor
# ====================================================================
banner "Fix 3: Enable monitoring (cn=Monitor)"

if ldapi_modify -f <(cat <<'LDIF'
dn: olcDatabase=monitor,cn=config
changetype: modify
replace: olcMonitoring
olcMonitoring: TRUE
LDIF
) 2>/dev/null; then
    ok "olcMonitoring: TRUE"; PASS=$((PASS+1))
else
    warn "olcMonitoring toggle failed — monitor database may not exist"
    WARN=$((WARN+1))
fi

# ====================================================================
# VERIFY
# ====================================================================
banner "Verification"

# Check ACL
log "--- ACL ---"
ACL_MW_COUNT=$(ldapi_search -b "$DB_DN" -s base -LLL olcAccess 2>/dev/null | grep -cF "${MW_DN}" || true)
if [[ "$ACL_MW_COUNT" -ge 2 ]]; then
    ok "MW in ACL (${ACL_MW_COUNT} rules — userPassword + Users subtree)"; PASS=$((PASS+2))
elif [[ "$ACL_MW_COUNT" -eq 1 ]]; then
    warn "MW in ACL only ${ACL_MW_COUNT}x (expected 2 — userPassword + Users subtree)"
    WARN=$((WARN+1))
else
    bad "MW missing from ACL"; FAIL=$((FAIL+2))
fi

# Check idle timeout
log "--- Idle timeout ---"
IDLE_VAL=$(ldapi_search -b "cn=config" -s base -LLL olcIdleTimeout 2>/dev/null | awk -F': ' '/^olcIdleTimeout:/ {print $2}')
if [[ -n "$IDLE_VAL" ]]; then
    ok "olcIdleTimeout: ${IDLE_VAL}"; PASS=$((PASS+1))
else
    warn "olcIdleTimeout not set (default 0 = never)"; WARN=$((WARN+1))
fi

# Check monitoring
log "--- Monitoring ---"
MON_VAL=$(ldapi_search -b "olcDatabase=monitor,cn=config" -s base -LLL olcMonitoring 2>/dev/null | awk -F': ' '/^olcMonitoring:/ {print $2}')
if [[ "$MON_VAL" == "TRUE" ]]; then
    ok "olcMonitoring: TRUE"; PASS=$((PASS+1))
else
    warn "olcMonitoring: ${MON_VAL:-not set}"; WARN=$((WARN+1))
fi

# ====================================================================
# SUMMARY
# ====================================================================
banner "Summary"
echo "  Passes:  $PASS"
echo "  Fails:   $FAIL"
echo "  Warnings: $WARN"

if [[ "$FAIL" -gt 0 ]]; then
    echo ""
    echo "[FAIL] Some checks failed. Review output above."
    exit 1
else
    echo ""
    echo "[SUCCESS] MW ACL + idle timeout fix applied."
    exit 0
fi
