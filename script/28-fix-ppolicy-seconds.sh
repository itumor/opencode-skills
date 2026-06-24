#!/usr/bin/env bash
# 28-fix-ppolicy-seconds.sh
#
# OpenLDAP ppolicy requires pwdMaxAge and pwdExpireWarning in SECONDS.
# If the policy was accidentally configured in days (e.g. pwdMaxAge=180
# meaning 180 days), the values are ~180x too small and passwords expire
# almost instantly. This script detects day-based values and converts
# them to seconds, then updates the policy.
#
# Conversion examples:
#   180 days → 180 × 86400 = 15,552,000 seconds → pwdMaxAge: 15552000
#   4 days   → 4   × 86400 = 345,600 seconds   → pwdExpireWarning: 345600
#   120 days → 120 × 86400 = 10,368,000 seconds → pwdMaxAge: 10368000
#   15 days  → 15  × 86400 = 1,296,000 seconds  → pwdExpireWarning: 1296000
#
# Detection: any value between 1 and 366 is treated as days (366 = leap year).
# Values 0 or >= 86400 are assumed to be seconds already.
#
# Usage:
#   sudo bash 28-fix-ppolicy-seconds.sh
#
# Env vars:
#   BASE_DN     – LDAP base DN (auto-detected if unset)
#   ADMIN_PW    – admin password (auto-detected if LDAPI works)
#   FORCE_CONVERT – set to 1 to force conversion even for ambiguous values
set -uo pipefail

log()   { echo "[INFO]  $*"; }
ok()    { echo "[ OK ]  $*"; }
warn()  { echo "[WARN]  $*"; }
fail()  { echo "[FAIL]  $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }
banner() { echo ""; echo "=== $* ==="; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh        ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
[[ -f /opt/symas/etc/openldap/sysmas_env.sh ]] && source /opt/symas/etc/openldap/sysmas_env.sh 2>/dev/null || true
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found"; }
require_cmd ldapsearch
require_cmd ldapmodify

SLAPD_SVC=""
for svc in symas-openldap-servers slapd; do
  if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then
    SLAPD_SVC="$svc"; break
  fi
done
[[ -z "${SLAPD_SVC:-}" ]] && pgrep -x slapd >/dev/null 2>&1 && SLAPD_SVC="slapd"
SLAPD_SVC="${SLAPD_SVC:-symas-openldap-servers}"

LDAPI_URI="ldapi:///"
ldapi_search()  { /opt/symas/bin/ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -o ldif-wrap=no "$@" 2>/dev/null; }
ldapi_modify()  { /opt/symas/bin/ldapmodify -Y EXTERNAL -H "$LDAPI_URI" "$@"; }

FORCE_CONVERT="${FORCE_CONVERT:-0}"

# ---- Detect BASE_DN if not set ----
if [[ -z "${BASE_DN:-}" ]]; then
  BASE_DN=$(ldapi_search -b cn=config -s sub '(&(objectClass=olcMdbConfig)(olcSuffix=*))' olcSuffix \
    | awk -F': ' '/^olcSuffix:/{print $2; exit}')
  BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
fi

# ---- Build policy DN ----
POLICY_DN="${POLICY_DN:-cn=default,ou=Policies,${BASE_DN}}"

ADMIN_PW="${ADMIN_PW:-TheN1le1}"
ADMIN_DN="cn=admin,${BASE_DN}"

banner "ppolicy Seconds Fix"
echo "  Base DN:   ${BASE_DN}"
echo "  Policy DN: ${POLICY_DN}"
echo ""

# ---- Step 1: Check policy exists (with retry — slapd may be restarting) ----
log "Checking policy entry..."
POLICY_EXISTS=0
for i in 1 2 3 4 5; do
  if LDAPTLS_REQCERT=never /opt/symas/bin/ldapsearch -x -ZZ \
    -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "$POLICY_DN" -s base dn 2>/dev/null | grep -q "^dn:"; then
    POLICY_EXISTS=1
    break
  fi
  sleep 2
done

if [[ "$POLICY_EXISTS" -eq 0 ]]; then
  # Fallback: try plain ldapi (before hardening is applied)
  if /opt/symas/bin/ldapsearch -x -H ldapi:/// -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "$POLICY_DN" -s base dn 2>/dev/null | grep -q "^dn:"; then
    POLICY_EXISTS=1
  fi
fi

if [[ "$POLICY_EXISTS" -eq 0 ]]; then
  warn "Policy $POLICY_DN does not exist — nothing to fix"
  log "Policy may not have been created yet. Run bank-apply-password-policy.sh first."
  exit 0
fi
ok "Policy entry exists"

# ---- Step 2: Read current values ----
log "Reading current pwdMaxAge and pwdExpireWarning..."
POLICY_ATTRS=$(LDAPTLS_REQCERT=never /opt/symas/bin/ldapsearch -o ldif-wrap=no -x -ZZ \
  -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
  -b "$POLICY_DN" -s base pwdMaxAge pwdExpireWarning 2>/dev/null)

if [[ -z "$POLICY_ATTRS" ]]; then
  POLICY_ATTRS=$(/opt/symas/bin/ldapsearch -o ldif-wrap=no -x -H ldapi:/// \
    -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "$POLICY_DN" -s base pwdMaxAge pwdExpireWarning 2>/dev/null)
fi

CURRENT_MAX_AGE=$(echo "$POLICY_ATTRS" | awk -F': ' '/^pwdMaxAge:/{print $2; exit}')
CURRENT_EXPIRE_WARN=$(echo "$POLICY_ATTRS" | awk -F': ' '/^pwdExpireWarning:/{print $2; exit}')

# ---- Step 3: Detect day-based values ----
convert_to_seconds() {
  local val="$1" attr_name="$2"
  [[ -z "$val" ]] && { echo "skip:not_set"; return; }
  [[ ! "$val" =~ ^[0-9]+$ ]] && { echo "skip:non_numeric"; return; }
  [[ "$val" -eq 0 ]] && { echo "ok:unlimited"; return; }
  if [[ "$val" -ge 86400 ]]; then
    echo "ok:already_seconds"
  elif [[ "$val" -le 366 || "$FORCE_CONVERT" -eq 1 ]]; then
    # Value is in days (1-366) or user forced conversion
    local new_val=$((val * 86400))
    echo "fix:${attr_name}:${val}:${new_val}"
  else
    # Ambiguous: 367-86399 — could be minutes or hours; warn and skip
    echo "warn:ambiguous:${val}"
  fi
}

MAX_AGE_ACTION=$(convert_to_seconds "$CURRENT_MAX_AGE" "pwdMaxAge")
EXPIRE_WARN_ACTION=$(convert_to_seconds "$CURRENT_EXPIRE_WARN" "pwdExpireWarning")

echo ""
echo "  Current values:"
echo "    pwdMaxAge:         ${CURRENT_MAX_AGE:-not set}"
echo "    pwdExpireWarning:  ${CURRENT_EXPIRE_WARN:-not set}"
echo ""

# ---- Step 4: Build LDIF if fixes needed ----
FIXES=()
FIX_REPORT=()

parse_action() {
  local action="$1" friendly="$2"
  case "$action" in
    skip:*)  log "${friendly}: no action (${action#skip:})" ;;
    ok:*)    ok  "${friendly}: already correct (${action#ok:})" ;;
    fix:pwdMaxAge:*)
      local old="${action#fix:pwdMaxAge:}"; old="${old%%:*}"
      local new="${action##*:}"
      FIX_REPORT+=("${friendly}: ${old} days → ${new} seconds ($((old))d)")
      FIXES+=("replace: pwdMaxAge
pwdMaxAge: ${new}") ;;
    fix:pwdExpireWarning:*)
      local old="${action#fix:pwdExpireWarning:}"; old="${old%%:*}"
      local new="${action##*:}"
      FIX_REPORT+=("${friendly}: ${old} days → ${new} seconds ($((old))d)")
      FIXES+=("replace: pwdExpireWarning
pwdExpireWarning: ${new}") ;;
    warn:*) warn "${friendly}: ambiguous value (${action#warn:}) — skipping" ;;
  esac
}

parse_action "$MAX_AGE_ACTION" "pwdMaxAge"
parse_action "$EXPIRE_WARN_ACTION" "pwdExpireWarning"

# ---- Step 5: Apply fixes ----
if [[ "${#FIXES[@]}" -eq 0 ]]; then
  banner "Result: No fixes needed — all values are in seconds"
  exit 0
fi

banner "Applying fixes"

# Build compound LDIF with multiple modifications
LDIF="/tmp/ppolicy-seconds-fix.ldif"
{
  echo "dn: $POLICY_DN"
  echo "changetype: modify"
  first=1
  for fix in "${FIXES[@]}"; do
    if [[ ${first:-1} -eq 1 ]]; then
      echo "$fix"
      first=0
    else
      echo "-"
      echo "$fix"
    fi
  done
} > "$LDIF"

log "Applying LDIF:"
cat "$LDIF"

LDAPTLS_REQCERT=never /opt/symas/bin/ldapmodify -x -ZZ \
  -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
  -f "$LDIF" 2>&1 || {
    log "StartTLS modify failed — trying ldapi"
    /opt/symas/bin/ldapmodify -x -H ldapi:/// -D "$ADMIN_DN" -w "$ADMIN_PW" \
      -f "$LDIF" 2>&1 || {
      fail "Both StartTLS and ldapi modify failed — trying SASL EXTERNAL"
      ldapi_modify -f "$LDIF" || fatal "All modify methods failed"
    }
  }

rm -f "$LDIF"

# ---- Step 6: Verify ----
banner "Verification"
sleep 1

VERIFY_ATTRS=$(LDAPTLS_REQCERT=never /opt/symas/bin/ldapsearch -o ldif-wrap=no -x -ZZ \
  -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" \
  -b "$POLICY_DN" -s base pwdMaxAge pwdExpireWarning 2>/dev/null)

if [[ -z "$VERIFY_ATTRS" ]]; then
  VERIFY_ATTRS=$(/opt/symas/bin/ldapsearch -o ldif-wrap=no -x -H ldapi:/// \
    -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "$POLICY_DN" -s base pwdMaxAge pwdExpireWarning 2>/dev/null)
fi

VERIFY_MAX=$(echo "$VERIFY_ATTRS" | awk -F': ' '/^pwdMaxAge:/{print $2; exit}')
VERIFY_WARN=$(echo "$VERIFY_ATTRS" | awk -F': ' '/^pwdExpireWarning:/{print $2; exit}')

PASS=0
FAIL_COUNT=0

for report in "${FIX_REPORT[@]}"; do
  ok "$report"
  PASS=$((PASS + 1))
done

# Validate both are now in seconds
if [[ -n "${VERIFY_MAX:-}" && "$VERIFY_MAX" -ge 86400 ]]; then
  ok "pwdMaxAge verified: ${VERIFY_MAX} seconds"
  PASS=$((PASS + 1))
else
  fail "pwdMaxAge = ${VERIFY_MAX:-not set} (expected >= 86400)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if [[ -n "${VERIFY_WARN:-}" && "$VERIFY_WARN" -ge 86400 ]]; then
  ok "pwdExpireWarning verified: ${VERIFY_WARN} seconds"
  PASS=$((PASS + 1))
else
  fail "pwdExpireWarning = ${VERIFY_WARN:-not set} (expected >= 86400)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---- Restart to ensure policy takes effect ----
systemctl restart "$SLAPD_SVC" 2>/dev/null || true
sleep 2
if systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1; then
  ok "$SLAPD_SVC running after restart"
  PASS=$((PASS + 1))
else
  fail "$SLAPD_SVC not running after restart"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---- Summary ----
echo ""
echo "============================================================"
echo "  PPOLICY SECONDS FIX — Complete"
echo "  Policy:   ${POLICY_DN}"
echo "  PASS=${PASS}  FAIL=${FAIL_COUNT}"
echo "============================================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
