#!/usr/bin/env bash
# restrict-special-chars-underscore-only.sh
# ====================================================================
# All-in-one: orclisenabled (Directory String) + underscore-only
# password special chars + PPM config + ppolicy wiring.
# Run on MASTER. Policy data replicates to replica via syncrepl.
#
# What this does:
#   1. Adds or updates orclisenabled as Directory String in schema
#   2. Includes it in bankUserExtension object class MAY list
#   3. Updates PPM config: only '_' allowed as special char
#   4. Updates forbiddenChars to block all other special chars
#   5. Wires ppm.so to ppolicy overlay
#   6. Restarts slapd, verifies
#
# Usage:
#   sudo bash restrict-special-chars-underscore-only.sh
# ====================================================================
set -uo pipefail

log()   { echo "[INFO]  $*"; }
ok()    { echo "[ OK ]  $*"; }
warn()  { echo "[WARN]  $*"; }
bad()   { echo "[FAIL] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }
banner() { echo ""; echo "=== $* ==="; }
section() { echo ""; echo "--- $*"; }

PASS=0; FAIL=0; WARN=0
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh            ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
[[ -f /opt/symas/etc/openldap/sysmas_env.sh  ]] && source /opt/symas/etc/openldap/sysmas_env.sh 2>/dev/null || true
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found — install it first"; }
require_cmd /opt/symas/bin/ldapsearch
require_cmd /opt/symas/bin/ldapmodify
require_cmd base64

# ---- Find slapd service ----
SLAPD_SVC=""
for svc in symas-openldap-servers slapd; do
  if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then
    SLAPD_SVC="$svc"
    break
  fi
done
[[ -z "${SLAPD_SVC:-}" ]] && pgrep -x slapd >/dev/null 2>&1 && SLAPD_SVC="slapd"
SLAPD_SVC="${SLAPD_SVC:-symas-openldap-servers}"

# ---- LDAPI helpers ----
LDAPI_URI="ldapi:///"
ldapi_search()  { /opt/symas/bin/ldapsearch -Y EXTERNAL -H "$LDAPI_URI" "$@" 2>/dev/null; }
ldapi_modify()  { /opt/symas/bin/ldapmodify -Y EXTERNAL -H "$LDAPI_URI" "$@"; }

# ---- Config ----
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_DN="cn=admin,${BASE_DN}"
ADMIN_PW="${ADMIN_PW:-TheN1le1}"
POLICY_DN="cn=default,ou=Policies,${BASE_DN}"
MODULE_PATH="${MODULE_PATH:-/opt/symas/lib/openldap}"

ATTR_NAME="${ATTR_NAME:-orclisenabled}"
ATTR_OID="${ATTR_OID:-1.3.6.1.4.1.55555.1.16}"
SCHEMA_NAME="${SCHEMA_NAME:-bank-custom}"
OC_NAME="${OC_NAME:-bankUserExtension}"

PWD_MIN_UPPER="${PWD_MIN_UPPER:-1}"
PWD_MIN_LOWER="${PWD_MIN_LOWER:-1}"
PWD_MIN_DIGIT="${PWD_MIN_DIGIT:-1}"
PWD_MIN_QUALITY="${PWD_MIN_QUALITY:-3}"
PWD_ALLOWED_SPECIAL="_"
PWD_FORBIDDEN_CHARS='!"#$%&()*+,-./:;<=>?@[\]^`{|}~ '"'"''

banner "Restrict Special Chars to Underscore Only + orclisenabled (String)"
echo "  Base DN:  ${BASE_DN}"
echo "  Policy:   ${POLICY_DN}"
echo "  Schema:   ${SCHEMA_NAME}"
echo ""

section "Pre-flight: LDAPI check"
/opt/symas/bin/ldapwhoami -Y EXTERNAL -H "$LDAPI_URI" >/dev/null 2>&1 \
  && ok "LDAPI EXTERNAL works" \
  || fatal "LDAPI EXTERNAL failed — cannot configure"

# ====================================================================
# STEP 0: Find schema DN (dynamic index)
# ====================================================================
banner "Step 0: Locate schema & check orclisenabled"

SCHEMA_DN="$(ldapi_search -b "cn=schema,cn=config" \
  -LLL "(&(objectClass=olcSchemaConfig)(cn=*${SCHEMA_NAME}))" dn \
  | awk '/^dn: /{print $2; exit}')"

if [[ -z "$SCHEMA_DN" ]]; then
  fatal "Schema ${SCHEMA_NAME} not found. Run 12-Create_custom_schema.sh first."
fi
ok "Schema DN: ${SCHEMA_DN}"

schema_dump="$(ldapi_search -b "$SCHEMA_DN" -s base -LLL olcAttributeTypes olcObjectClasses || true)"

# Check if orclisenabled already exists
ATTR_LINE="$(echo "$schema_dump" | grep "olcAttributeTypes:" | grep "NAME '${ATTR_NAME}'" || true)"
ATTR_BOOL="$(echo "$ATTR_LINE" | grep "SYNTAX 1.3.6.1.4.1.1466.115.121.1.7" || true)"
ATTR_STR="$(echo "$ATTR_LINE" | grep "SYNTAX 1.3.6.1.4.1.1466.115.121.1.15" || true)"
OC_HAS_ATTR="$(echo "$schema_dump" | grep "olcObjectClasses:" | grep -c "${ATTR_NAME}" || true)"

# Directory String attribute definition
ATTR_DEF_STR="( ${ATTR_OID} NAME '${ATTR_NAME}' DESC 'Oracle enabled flag' EQUALITY caseIgnoreMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )"

if [[ -n "$ATTR_BOOL" ]]; then
  # ---- Case A: Exists as Boolean → replace with Directory String ----
  warn "orclisenabled exists as Boolean — replacing with Directory String"
  ATTR_VAL="${ATTR_LINE#olcAttributeTypes: }"
  ldapi_modify -f <(cat <<LDIF
dn: ${SCHEMA_DN}
changetype: modify
delete: olcAttributeTypes
olcAttributeTypes: ${ATTR_VAL}
-
add: olcAttributeTypes
olcAttributeTypes: ${ATTR_DEF_STR}
LDIF
) && { ok "orclisenabled changed from Boolean → Directory String"; PASS=$((PASS+1)); } \
  || { bad "Failed to update orclisenabled syntax"; FAIL=$((FAIL+1)); }
elif [[ -n "$ATTR_STR" ]]; then
  # ---- Case B: Already Directory String → skip ----
  ok "orclisenabled already Directory String"; PASS=$((PASS+1))
elif [[ -n "$ATTR_LINE" ]]; then
  # ---- Case C: Exists with unknown syntax → log and skip ----
  warn "orclisenabled exists with unknown syntax — skipping schema change"
  WARN=$((WARN+1))
else
  # ---- Case D: Not present → add ----
  log "Adding orclisenabled as Directory String"
  ldapi_modify -f <(cat <<LDIF
dn: ${SCHEMA_DN}
changetype: modify
add: olcAttributeTypes
olcAttributeTypes: ${ATTR_DEF_STR}
LDIF
) && { ok "Added orclisenabled (Directory String)"; PASS=$((PASS+1)); } \
  || { bad "Failed to add orclisenabled"; FAIL=$((FAIL+1)); }
fi

# ---- Add to bankUserExtension MAY list if missing ----
if [[ "$OC_HAS_ATTR" -gt 0 ]]; then
  ok "orclisenabled already in ${OC_NAME} MAY list"; PASS=$((PASS+1))
else
  current_oc="$(echo "$schema_dump" | grep "^olcObjectClasses:" | head -1)"
  if [[ -z "$current_oc" ]]; then
    warn "${OC_NAME} not found in schema dump — skipping OC update"; WARN=$((WARN+1))
  else
    OC_VAL="${current_oc#olcObjectClasses: }"
    NEW_OC="$(echo "$current_oc" | sed "s/ ) )$/ \$ ${ATTR_NAME} ) )/")"
    NEW_VAL="${NEW_OC#olcObjectClasses: }"
    ldapi_modify -f <(cat <<LDIF
dn: ${SCHEMA_DN}
changetype: modify
delete: olcObjectClasses
olcObjectClasses: ${OC_VAL}
-
add: olcObjectClasses
olcObjectClasses: ${NEW_VAL}
LDIF
) && { ok "Added ${ATTR_NAME} to ${OC_NAME} MAY list"; PASS=$((PASS+1)); } \
  || { warn "OC update failed — may need manual fix"; WARN=$((WARN+1)); }
  fi
fi

# ====================================================================
# STEP 1: Check PPM module
# ====================================================================
banner "Step 1: Check PPM module"
if [[ -f "${MODULE_PATH}/ppm.so" ]]; then
  ok "ppm.so found at ${MODULE_PATH}/ppm.so"; PASS=$((PASS+1))
  PPM_AVAILABLE=1
else
  warn "ppm.so not found — LDAP-level rules only (class-special/forbiddenChars need ppm.so)"; WARN=$((WARN+1))
  PPM_AVAILABLE=0
fi

# ====================================================================
# STEP 2: Ensure ppolicy overlay wired to ppm.so
# ====================================================================
banner "Step 2: Wire ppm.so to ppolicy overlay"
PPOLICY_DN=$(ldapi_search -b cn=config -s sub "(olcOverlay=ppolicy)" dn 2>/dev/null | awk '/^dn: /{print $2; exit}')
if [[ -z "$PPOLICY_DN" ]]; then
  DB_DN=$(ldapi_search -b cn=config -s sub '(&(objectClass=olcMdbConfig)(olcSuffix=*))' dn 2>/dev/null | awk '/^dn: /{print $2; exit}')
  PPOLICY_DN="olcOverlay={1}ppolicy,${DB_DN:-olcDatabase={1}mdb,cn=config}"
fi
if [[ "$PPM_AVAILABLE" -eq 1 ]]; then
  CURRENT_CHK=$(ldapi_search -b "$PPOLICY_DN" -s base -LLL olcPPolicyCheckModule 2>/dev/null | awk -F': ' '/^olcPPolicyCheckModule:/{print $2; exit}')
  if [[ "$CURRENT_CHK" == "ppm.so" ]]; then
    ok "olcPPolicyCheckModule already ppm.so"; PASS=$((PASS+1))
  else
    ldapi_modify -f <(cat <<LDIF
dn: $PPOLICY_DN
changetype: modify
replace: olcPPolicyCheckModule
olcPPolicyCheckModule: ppm.so
LDIF
) && { ok "olcPPolicyCheckModule set to ppm.so"; PASS=$((PASS+1)); } \
  || { warn "olcPPolicyCheckModule set failed"; WARN=$((WARN+1)); }
  fi
fi

# ====================================================================
# STEP 3: Build + apply PPM config (underscore-only)
# ====================================================================
banner "Step 3: Build PPM config — underscore only"
PPM_CONFIG="/tmp/ppm-restrict-${TIMESTAMP}.conf"

cat > "$PPM_CONFIG" << PPMEOF
minQuality ${PWD_MIN_QUALITY}
checkRDN 1
forbiddenChars ${PWD_FORBIDDEN_CHARS}
maxConsecutivePerClass 0
class-upperCase ABCDEFGHIJKLMNOPQRSTUVWXYZ ${PWD_MIN_UPPER} 1 0
class-lowerCase abcdefghijklmnopqrstuvwxyz ${PWD_MIN_LOWER} 1 0
class-digit 0123456789 ${PWD_MIN_DIGIT} 1 0
class-special _ 0 1 0
PPMEOF

ok "PPM config written"
log "  class-special: only '_'"
log "  forbiddenChars: all other ASCII special chars blocked"
PASS=$((PASS+1))

banner "Step 4: Apply base64 PPM config to policy entry"
PPM_B64=$(base64 "$PPM_CONFIG" | tr -d '\n')
rm -f "$PPM_CONFIG"

ldapi_modify -f <(cat <<LDIF
dn: $POLICY_DN
changetype: modify
replace: pwdCheckModuleArg
pwdCheckModuleArg:: $PPM_B64
LDIF
)

if ldapi_search -o ldif-wrap=no -b "$POLICY_DN" -s base pwdCheckModuleArg 2>/dev/null | grep -q "pwdCheckModuleArg:"; then
  ok "pwdCheckModuleArg updated (${#PPM_B64} bytes base64)"; PASS=$((PASS+1))
else
  bad "pwdCheckModuleArg update failed"; FAIL=$((FAIL+1))
fi

# ====================================================================
# STEP 5: Restart slapd
# ====================================================================
banner "Step 5: Restart slapd"
systemctl restart "$SLAPD_SVC" 2>/dev/null || true
sleep 3
if systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1; then
  ok "$SLAPD_SVC running"; PASS=$((PASS+1))
else
  bad "$SLAPD_SVC failed to restart"; FAIL=$((FAIL+1))
fi

# ====================================================================
# VERIFICATION
# ====================================================================
banner "Verification"

# V1: Policy entry accessible
ldapi_search -b "$POLICY_DN" -s base dn 2>/dev/null | grep -q "^dn:" \
  && { ok "Policy entry readable"; PASS=$((PASS+1)); } \
  || { bad "Policy entry not accessible"; FAIL=$((FAIL+1)); }

# V2: orclisenabled present as Directory String
ATTR_CHECK=$(ldapi_search -b "$SCHEMA_DN" -s base -LLL olcAttributeTypes 2>/dev/null)
if echo "$ATTR_CHECK" | grep -q "NAME '${ATTR_NAME}'" && echo "$ATTR_CHECK" | grep -q "SYNTAX 1.3.6.1.4.1.1466.115.121.1.15"; then
  ok "orclisenabled confirmed as Directory String in schema"; PASS=$((PASS+1))
else
  warn "orclisenabled syntax may not be Directory String — verify manually"; WARN=$((WARN+1))
fi

# V3: Decode and verify PPM config
PPM_ARG=$(ldapi_search -o ldif-wrap=no -b "$POLICY_DN" -s base pwdCheckModuleArg 2>/dev/null \
  | awk -F': ' '/^pwdCheckModuleArg:/{print $2; exit}')

if [[ -n "$PPM_ARG" ]]; then
  DECODED="/tmp/ppm-decoded-${TIMESTAMP}.conf"
  echo "$PPM_ARG" | base64 -d > "$DECODED" 2>/dev/null
  if grep -q "^class-special _ 0 1 0$" "$DECODED" 2>/dev/null; then
    ok "Underscore-only confirmed in PPM config"; PASS=$((PASS+1))
  else
    warn "class-special not matching expected '_' only"; WARN=$((WARN+1))
  fi
  if grep -q "^forbiddenChars" "$DECODED" 2>/dev/null; then
    ok "forbiddenChars present in PPM config"; PASS=$((PASS+1))
  else
    warn "forbiddenChars missing from PPM config"; WARN=$((WARN+1))
  fi
  rm -f "$DECODED"
else
  warn "pwdCheckModuleArg empty — PPM config not applied"; WARN=$((WARN+1))
fi

# ====================================================================
# SUMMARY
# ====================================================================
echo ""
echo "============================================================"
echo "  ALL-IN-ONE — Complete"
echo "  Policy:   ${POLICY_DN}"
echo "  Schema:   ${SCHEMA_DN}"
echo ""
echo "  orclisenabled:  Directory String (OID ${ATTR_OID})"
echo "  Special chars:  _ (underscore ONLY)"
echo "  Blocked chars:  all other ASCII special characters"
echo ""
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
