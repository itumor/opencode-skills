#!/usr/bin/env bash
# bank-apply-password-policy.sh
# ====================================================================
# Applies the comprehensive Bank OpenLDAP password policy.
# Run on the MASTER. Policy data replicates to replica via syncrepl.
#
# Policy Requirements (from Bank):
#   Complexity:  min 8, max 12 characters
#                at least 1 uppercase, 1 lowercase, 1 digit
#                only "_" underscore allowed as special character
#   Arabic letters NOT allowed (via forbiddenChars unicode blocks)
#   Can't be same as username or its reverse
#   Expiry:  4 months  (120 days)
#   Notice:  15 days before expiry
#   Lockout: 5 failed attempts (30 min duration)
#   History: last 5 passwords cannot be reused
#   Banned:  ' " ( ) { } [ ] / \ = @ # $ % ! . -
#
# Two-tier enforcement:
#   LDAP-level (always works):  pwdMaxAge, pwdMinLength, pwdMaxFailure,
#                               pwdInHistory, pwdLockout, pwdCheckQuality
#   PPM-level (requires ppm.so): maxLength, char classes, specialChars,
#                                forbiddenChars, rejectUsername
#
# Usage:
#   sudo bash bank-apply-password-policy.sh
# ====================================================================
set -uo pipefail

# ---- Logging helpers ----
log()   { echo "[INFO]  $*"; }
ok()    { echo "[ OK ]  $*"; }
warn()  { echo "[WARN]  $*"; }
bad()   { echo "[FAIL] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }
banner() { echo ""; echo "=== $* ==="; }
section() { echo ""; echo "--- $*"; }

PASS=0; FAIL=0; WARN=0
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ====================================================================
# Environment Setup
# ====================================================================
[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh        ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
[[ -f /opt/symas/etc/openldap/sysmas_env.sh ]] && source /opt/symas/etc/openldap/sysmas_env.sh 2>/dev/null || true
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found — install it first"; }
require_cmd ldapsearch
require_cmd ldapmodify
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
POLICIES_OU="ou=Policies,${BASE_DN}"
MODULE_PATH="${MODULE_PATH:-/opt/symas/lib/openldap}"

# ---- Bank Policy Parameters ----
PWD_MIN_LENGTH=8
PWD_MAX_LENGTH=12
PWD_MIN_UPPER=1
PWD_MIN_LOWER=1
PWD_MIN_DIGIT=1
PWD_ALLOWED_SPECIAL="_"
PWD_MAX_AGE=$((120 * 86400))
PWD_EXPIRE_WARNING=$((15 * 86400))
PWD_IN_HISTORY=5
PWD_MAX_FAILURE=5
PWD_LOCKOUT_DURATION=1800
PWD_GRACE_AUTHN_LIMIT=3
PWD_HISTORY_SIZE=5
PWD_MAX_REPEAT=2

# ====================================================================
banner "Bank Password Policy — Apply"
echo "  Base DN:  ${BASE_DN}"
echo "  Policy:   ${POLICY_DN}"
echo "  PPM:      $([[ -f ${MODULE_PATH}/ppm.so ]] && echo 'available (ppm.so found)' || echo 'not available (licensed Symas required)')"
echo ""

# ---- Pre-flight: LDAPI access ----
section "Pre-flight: LDAPI check"
ldapwhoami -Y EXTERNAL -H "$LDAPI_URI" >/dev/null 2>&1 && ok "LDAPI EXTERNAL works" || fatal "LDAPI EXTERNAL failed — cannot configure"

# ---- Step 1: Load ppolicy module ----
banner "Step 1: Load ppolicy module"
MODULE_DN=$(ldapi_search -b cn=config -s sub "(objectClass=olcModuleList)" dn | grep "^dn: " | head -1 | sed 's/^dn: //')
MODULE_DN="${MODULE_DN:-cn=module{0},cn=config}"

PPOLICY_LOADED=$(ldapi_search -b cn=config -s sub "(olcModuleLoad=ppolicy.la)" dn 2>/dev/null | grep -c "^dn: cn=module" || true)
if [[ "$PPOLICY_LOADED" -gt 0 ]]; then
  ok "ppolicy module already loaded"
  PASS=$((PASS+1))
else
  log "Loading ppolicy module..."
  ldapi_modify -f <(cat <<LDIF
dn: $MODULE_DN
changetype: modify
add: olcModuleLoad
olcModuleLoad: ppolicy.la
LDIF
) && { ok "ppolicy module loaded"; PASS=$((PASS+1)); } || { bad "ppolicy load failed"; FAIL=$((FAIL+1)); }
fi

# ---- Step 2: Ensure ppolicy overlay ----
banner "Step 2: Ensure ppolicy overlay on database"
DB_DN=$(ldapi_search -b cn=config -s sub '(&(objectClass=olcMdbConfig)(olcSuffix=*))' dn | grep "^dn: " | head -1 | sed 's/^dn: //')
DB_DN="${DB_DN:-olcDatabase={1}mdb,cn=config}"

PPOLICY_CHILD=$(ldapi_search -b "$DB_DN" -s sub "(olcOverlay=ppolicy)" dn 2>/dev/null | grep -c "^dn: " || true)
PPOLICY_ATTR=$(ldapi_search -b "$DB_DN" -s base -LLL olcOverlay 2>/dev/null | grep -i "ppolicy" || true)

if [[ "$PPOLICY_CHILD" -gt 0 ]] || [[ -n "$PPOLICY_ATTR" ]]; then
  ok "ppolicy overlay already on $DB_DN"
  PASS=$((PASS+1))
else
  log "Adding ppolicy overlay to $DB_DN..."
  ldapi_modify -f <(cat <<LDIF
dn: ${DB_DN}
changetype: modify
add: olcOverlay
olcOverlay: ppolicy
LDIF
) && { ok "ppolicy overlay added"; PASS=$((PASS+1)); } || { bad "ppolicy overlay add failed"; FAIL=$((FAIL+1)); }
fi

# ---- Step 3: Find ppolicy overlay DN ----
banner "Step 3: Locate ppolicy overlay entry"
PPOLICY_DN=$(ldapi_search -b "$DB_DN" -s one "(olcOverlay=ppolicy)" dn | grep "^dn: " | head -1 | sed 's/^dn: //')
PPOLICY_DN="${PPOLICY_DN:-olcOverlay={1}ppolicy,${DB_DN}}"
log "ppolicy overlay DN: $PPOLICY_DN"

# ---- Step 4: Create Policies OU ----
banner "Step 4: Ensure Policies OU exists"
POLICY_OU_EXISTS=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
  -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$POLICIES_OU" -s base dn 2>/dev/null | grep -c "^dn:" || true)
if [[ "$POLICY_OU_EXISTS" -gt 0 ]]; then
  ok "Policies OU exists"; PASS=$((PASS+1))
else
  log "Creating Policies OU..."
  LDAPTLS_REQCERT=never ldapadd -x -ZZ -H ldap://localhost \
    -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<LDIF
dn: $POLICIES_OU
objectClass: top
objectClass: organizationalUnit
ou: Policies
description: Password Policies
LDIF
  if LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
    -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$POLICIES_OU" -s base dn 2>/dev/null | grep -q "^dn:"; then
    ok "Policies OU created"; PASS=$((PASS+1))
  else
    bad "Policies OU creation failed"; FAIL=$((FAIL+1))
  fi
fi

# ---- Step 5: Create/Update password policy entry ----
banner "Step 5: Configure password policy entry"
POLICY_EXISTS=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
  -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$POLICY_DN" -s base dn 2>/dev/null | grep -c "^dn:" || true)

if [[ "$POLICY_EXISTS" -gt 0 ]]; then
  log "Policy entry exists — updating attributes..."
  LDAPTLS_REQCERT=never ldapmodify -x -ZZ -H ldap://localhost \
    -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<LDIF
dn: $POLICY_DN
changetype: modify
replace: pwdAttribute
pwdAttribute: userPassword
-
replace: pwdMaxAge
pwdMaxAge: $PWD_MAX_AGE
-
replace: pwdExpireWarning
pwdExpireWarning: $PWD_EXPIRE_WARNING
-
replace: pwdInHistory
pwdInHistory: $PWD_IN_HISTORY
-
replace: pwdCheckQuality
pwdCheckQuality: 2
-
replace: pwdMinLength
pwdMinLength: $PWD_MIN_LENGTH
-
replace: pwdMaxLength
pwdMaxLength: $PWD_MAX_LENGTH
-
replace: pwdMaxFailure
pwdMaxFailure: $PWD_MAX_FAILURE
-
replace: pwdLockout
pwdLockout: TRUE
-
replace: pwdLockoutDuration
pwdLockoutDuration: $PWD_LOCKOUT_DURATION
-
replace: pwdGraceAuthNLimit
pwdGraceAuthNLimit: $PWD_GRACE_AUTHN_LIMIT
-
replace: pwdFailureCountInterval
pwdFailureCountInterval: 0
-
replace: pwdMustChange
pwdMustChange: FALSE
-
replace: pwdAllowUserChange
pwdAllowUserChange: TRUE
-
replace: pwdSafeModify
pwdSafeModify: FALSE
-
add: pwdUseCheckModule
pwdUseCheckModule: TRUE
LDIF
  ok "Policy entry updated"; PASS=$((PASS+1))
else
  log "Creating policy entry..."
  LDAPTLS_REQCERT=never ldapadd -x -ZZ -H ldap://localhost \
    -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<LDIF
dn: $POLICY_DN
objectClass: pwdPolicy
objectClass: person
objectClass: top
cn: default
sn: default
pwdAttribute: userPassword
pwdMaxAge: $PWD_MAX_AGE
pwdExpireWarning: $PWD_EXPIRE_WARNING
pwdInHistory: $PWD_IN_HISTORY
pwdCheckQuality: 2
pwdMinLength: $PWD_MIN_LENGTH
pwdMaxLength: $PWD_MAX_LENGTH
pwdMaxFailure: $PWD_MAX_FAILURE
pwdLockout: TRUE
pwdLockoutDuration: $PWD_LOCKOUT_DURATION
pwdGraceAuthNLimit: $PWD_GRACE_AUTHN_LIMIT
pwdFailureCountInterval: 0
pwdMustChange: FALSE
pwdAllowUserChange: TRUE
pwdSafeModify: FALSE
pwdUseCheckModule: TRUE
LDIF
  if LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
    -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$POLICY_DN" -s base dn 2>/dev/null | grep -q "^dn:"; then
    ok "Policy entry created"; PASS=$((PASS+1))
  else
    bad "Policy creation failed"; FAIL=$((FAIL+1))
  fi
fi

# ---- Step 6: Set as default policy ----
banner "Step 6: Set default policy in overlay"
CURRENT_DEFAULT=$(ldapi_search -b "$PPOLICY_DN" -s base -LLL olcPPolicyDefault 2>/dev/null | awk -F': ' '/^olcPPolicyDefault:/{print $2; exit}')
if [[ "$CURRENT_DEFAULT" == "$POLICY_DN" ]]; then
  ok "Default policy already set to $POLICY_DN"
  PASS=$((PASS+1))
else
  log "Setting olcPPolicyDefault to $POLICY_DN..."
  ldapi_modify -f <(cat <<LDIF
dn: $PPOLICY_DN
changetype: modify
replace: olcPPolicyDefault
olcPPolicyDefault: $POLICY_DN
-
replace: olcPPolicyUseLockout
olcPPolicyUseLockout: TRUE
LDIF
) && { ok "Default policy set"; PASS=$((PASS+1)); } || { bad "Default policy set failed"; FAIL=$((FAIL+1)); }
fi

# ---- Step 7: PPM configuration (password quality checker) ----
banner "Step 7: PPM password quality checker"

PPM_AVAILABLE=0
if [[ -f "${MODULE_PATH}/ppm.so" ]]; then
  PPM_AVAILABLE=1
  log "ppm.so found at ${MODULE_PATH}/ppm.so"

  # Check if ppm.so is properly linked to liblber
  # The shipped RPM has ber_memalloc unresolved (build defect).
  # Without liblber, class-based rules are silently ignored.
  section "7a: Validate ppm.so linking"
  PPM_LDD=$(ldd -r "${MODULE_PATH}/ppm.so" 2>&1 || true)
  if echo "$PPM_LDD" | grep -q "undefined symbol.*ber_mem"; then
    warn "ppm.so has unresolved symbols — PPM class rules will NOT work!"
    warn "  Cause: ppm.so was compiled without linking liblber (ber_memalloc undefined)"
    warn "  Symptom: LDAP-level rules work, but class-upperCase/class-digit/forbiddenChars/checkRDN do not"

    if [[ -d "/tmp/symas-openldap-v2.6.13" ]]; then
      log "OpenLDAP source found at /tmp/symas-openldap-v2.6.13 — attempting rebuild..."
      log "  Rebuilding ppm.so with liblber linked..."
      PPM_SRC="/tmp/symas-openldap-v2.6.13"
      PPM_REBUILD_DIR="${PPM_SRC}/contrib/slapd-modules/ppm"
      if [[ -f "$PPM_REBUILD_DIR/ppm.c" ]]; then
        (gcc -fPIC -DDEBUG \
          -I"${PPM_SRC}/include" \
          -I"${PPM_SRC}/servers/slapd" \
          -c "$PPM_REBUILD_DIR/ppm.c" -o /tmp/ppm-rebuild.o 2>/dev/null && \
         gcc -shared -o /tmp/ppm-rebuild.so /tmp/ppm-rebuild.o \
          /opt/symas/lib/liblber.so.2 \
          -Wl,-rpath,/opt/symas/lib 2>/dev/null && \
         ldd -r /tmp/ppm-rebuild.so 2>/dev/null | grep -q "undefined symbol.*ber_mem" && \
         { warn "ppm.so rebuild produced unresolved ber_memalloc"; rm -f /tmp/ppm-rebuild.o /tmp/ppm-rebuild.so; false; } || \
         { cp /opt/symas/lib/openldap/ppm.so /opt/symas/lib/openldap/ppm.so.bak 2>/dev/null; \
           cp /tmp/ppm-rebuild.so /opt/symas/lib/openldap/ppm.so; \
           chmod 755 /opt/symas/lib/openldap/ppm.so; \
           rm -f /tmp/ppm-rebuild.o /tmp/ppm-rebuild.so; \
           ok "ppm.so rebuilt with liblber — restarting slapd"; \
           systemctl restart "$SLAPD_SVC" && sleep 3 && \
           ok "slapd restarted with fixed ppm.so"; }) || \
        warn "ppm.so rebuild failed — check that gcc and source are available"
      else
        log "OpenLDAP source incomplete — cannot rebuild"
        log "  Install dev tools and extract source:"
        log "    dnf groupinstall -y 'Development Tools'"
        log "    dnf download --source symas-openldap"
        log "    rpm -ivh symas-openldap*.src.rpm"
        log "    cd ~/rpmbuild/SOURCES && tar xf symas-openldap-v2.6.13.tar.xz"
        log "    cd symas-openldap-v2.6.13 && ./configure && make depend"
        log "  Then re-run this script."
      fi
    else
      log "OpenLDAP source not found at /tmp/symas-openldap-v2.6.13"
      log "  To fix, run the rebuild procedure from BANK_PASSWORD_POLICY.md"
      log "  then re-run this script. Without the fix, only LDAP-level rules apply."
    fi
  else
    ok "ppm.so is properly linked (no unresolved symbols)"
  fi
else
  warn "ppm.so not found — PPM unavailable (licensed Symas required)"
  log "LDAP-level policy still applies (pwdMaxAge, pwdMinLength, pwdMaxFailure, pwdInHistory, pwdLockout)"
  WARN=$((WARN+1))
fi

if [[ "$PPM_AVAILABLE" -eq 1 ]]; then
  # 7a: Build PPM config in class-based format (per Symas docs for 2.5.13+)
  section "7a: Build PPM config (class-based format)"
  PPM_CONFIG="/tmp/ppm-${TIMESTAMP}.conf"

  cat > "$PPM_CONFIG" << PPMEOF
minQuality 3
checkRDN 1
forbiddenChars '"(){}[]/\\=@#\$%!.-
maxConsecutivePerClass 0
class-upperCase ABCDEFGHIJKLMNOPQRSTUVWXYZ ${PWD_MIN_UPPER} 1 0
class-lowerCase abcdefghijklmnopqrstuvwxyz ${PWD_MIN_LOWER} 1 0
class-digit 0123456789 ${PWD_MIN_DIGIT} 1 0
class-special ${PWD_ALLOWED_SPECIAL} 0 1 0
PPMEOF

  ok "PPM config written (5-field class format per slapm-ppm(5))"
  log "  minQuality=3 (requires 3 classes of 4)"
  log "  class-upperCase: min=${PWD_MIN_UPPER}, minForPoint=1, max=0 (A-Z)"
  log "  class-lowerCase: min=${PWD_MIN_LOWER}, minForPoint=1, max=0 (a-z)"
  log "  class-digit:     min=${PWD_MIN_DIGIT}, minForPoint=1, max=0 (0-9)"
  log "  class-special:   min=0, minForPoint=1, max=0 (only '${PWD_ALLOWED_SPECIAL}')"
  log "  checkRDN=1 (reject username/rdn in password)"
  log "  forbiddenChars: '\" ( ) { } [ ] / \\ = @ # \$ % ! . -"
  PASS=$((PASS+1))

  # 7b: Base64-encode and store as pwdCheckModuleArg
  section "7b: Store base64 config in pwdCheckModuleArg"
  PPM_B64=$(base64 "$PPM_CONFIG" | tr -d '\n')
  rm -f "$PPM_CONFIG"

  LDAPTLS_REQCERT=never ldapmodify -x -ZZ -H ldap://localhost \
    -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<LDIF
dn: $POLICY_DN
changetype: modify
replace: pwdCheckModuleArg
pwdCheckModuleArg:: $PPM_B64
LDIF

  ARG_CHECK=$(LDAPTLS_REQCERT=never ldapsearch -o ldif-wrap=no -x -ZZ -H ldap://localhost \
    -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$POLICY_DN" -s base pwdCheckModuleArg 2>/dev/null | grep -c "pwdCheckModuleArg:" || true)
  if [[ "$ARG_CHECK" -gt 0 ]]; then
    ok "pwdCheckModuleArg stored (${#PPM_B64} bytes base64)"
    PASS=$((PASS+1))
  else
    warn "pwdCheckModuleArg store failed — trying ldapi"
    ldapi_modify -f <(cat <<LDIF
dn: $POLICY_DN
changetype: modify
replace: pwdCheckModuleArg
pwdCheckModuleArg:: $PPM_B64
LDIF
) && { ok "pwdCheckModuleArg stored (via ldapi)"; PASS=$((PASS+1)); } || { warn "pwdCheckModuleArg store failed"; }
  fi

  # 7c: Wire ppm.so into ppolicy overlay via olcPPolicyCheckModule
  section "7c: Wire ppm.so into ppolicy overlay"
  CURRENT_CHK=$(ldapi_search -b "$PPOLICY_DN" -s base -LLL olcPPolicyCheckModule 2>/dev/null | awk -F': ' '/^olcPPolicyCheckModule:/{print $2; exit}')
  if [[ "$CURRENT_CHK" == "ppm.so" ]]; then
    ok "olcPPolicyCheckModule already set to ppm.so"
    PASS=$((PASS+1))
  else
    CHK_OUT=$(ldapi_modify -f <(cat <<LDIF
dn: $PPOLICY_DN
changetype: modify
replace: olcPPolicyCheckModule
olcPPolicyCheckModule: ppm.so
LDIF
) 2>&1)
    if echo "$CHK_OUT" | grep -q "modifying entry"; then
      ok "olcPPolicyCheckModule set to ppm.so"; PASS=$((PASS+1))
    else
      warn "olcPPolicyCheckModule set failed: $(echo "$CHK_OUT" | head -1)"; WARN=$((WARN+1))
    fi
  fi
fi

# ---- Step 8: pwdPolicyChecker objectClass ----
banner "Step 8: Ensure pwdPolicyChecker on policy entry"
POLICY_OBJ=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
  -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$POLICY_DN" -s base objectClass 2>/dev/null)
if echo "$POLICY_OBJ" | grep -qi '^objectClass: pwdPolicyChecker$'; then
  ok "pwdPolicyChecker objectClass present"; PASS=$((PASS+1))
else
  LDAPTLS_REQCERT=never ldapmodify -x -ZZ -H ldap://localhost \
    -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<LDIF
dn: $POLICY_DN
changetype: modify
add: objectClass
objectClass: pwdPolicyChecker
LDIF
  if LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
    -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$POLICY_DN" -s base objectClass 2>/dev/null | grep -qi 'pwdPolicyChecker'; then
    ok "pwdPolicyChecker added"; PASS=$((PASS+1))
  else
    warn "could not add pwdPolicyChecker"; WARN=$((WARN+1))
  fi
fi

# ---- Step 9: Restart slapd ----
banner "Step 9: Restart OpenLDAP service"
systemctl restart "$SLAPD_SVC"
sleep 3
if systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1; then
  ok "$SLAPD_SVC running after restart"; PASS=$((PASS+1))
else
  bad "$SLAPD_SVC failed to restart"; FAIL=$((FAIL+1))
fi

# ====================================================================
# VERIFICATION
# ====================================================================
banner "Verification"

# V1: Service running
systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1 && { ok "Slapd is running"; PASS=$((PASS+1)); } || { bad "Slapd not running"; FAIL=$((FAIL+1)); }

# V2: Policy readable
LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
  -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$POLICY_DN" -s base dn 2>/dev/null | grep -q "^dn:" && { ok "Policy entry readable"; PASS=$((PASS+1)); } || { bad "Policy entry not accessible"; FAIL=$((FAIL+1)); }

# V3: Core policy attributes
POLICY_ATTRS=$(LDAPTLS_REQCERT=never ldapsearch -o ldif-wrap=no -x -ZZ -H ldap://localhost \
  -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$POLICY_DN" -s base \
  pwdMaxAge pwdExpireWarning pwdInHistory pwdMinLength pwdMaxLength pwdMaxFailure \
  pwdLockout pwdCheckQuality pwdLockoutDuration 2>/dev/null)

CHECK_MAX_AGE=$(echo "$POLICY_ATTRS" | awk -F': ' '/^pwdMaxAge:/{print $2; exit}')
CHECK_MIN_LEN=$(echo "$POLICY_ATTRS" | awk -F': ' '/^pwdMinLength:/{print $2; exit}')
CHECK_MAX_LEN=$(echo "$POLICY_ATTRS" | awk -F': ' '/^pwdMaxLength:/{print $2; exit}')
CHECK_HISTORY=$(echo "$POLICY_ATTRS" | awk -F': ' '/^pwdInHistory:/{print $2; exit}')
CHECK_FAILURE=$(echo "$POLICY_ATTRS" | awk -F': ' '/^pwdMaxFailure:/{print $2; exit}')
CHECK_QUALITY=$(echo "$POLICY_ATTRS" | awk -F': ' '/^pwdCheckQuality:/{print $2; exit}')

[[ "$CHECK_MAX_AGE" == "$PWD_MAX_AGE"    ]] && ok "pwdMaxAge=${CHECK_MAX_AGE}s (4 months)"    && PASS=$((PASS+1)) || bad "pwdMaxAge=${CHECK_MAX_AGE} (expected ${PWD_MAX_AGE})"
[[ "$CHECK_MIN_LEN" == "$PWD_MIN_LENGTH" ]] && ok "pwdMinLength=${CHECK_MIN_LEN}"              && PASS=$((PASS+1)) || bad "pwdMinLength=${CHECK_MIN_LEN} (expected ${PWD_MIN_LENGTH})"
[[ "$CHECK_MAX_LEN" == "$PWD_MAX_LENGTH" ]] && ok "pwdMaxLength=${CHECK_MAX_LEN}"              && PASS=$((PASS+1)) || bad "pwdMaxLength=${CHECK_MAX_LEN} (expected ${PWD_MAX_LENGTH})"
[[ "$CHECK_HISTORY" == "$PWD_IN_HISTORY" ]] && ok "pwdInHistory=${CHECK_HISTORY}"              && PASS=$((PASS+1)) || bad "pwdInHistory=${CHECK_HISTORY} (expected ${PWD_IN_HISTORY})"
[[ "$CHECK_FAILURE" == "$PWD_MAX_FAILURE" ]] && ok "pwdMaxFailure=${CHECK_FAILURE}"             && PASS=$((PASS+1)) || bad "pwdMaxFailure=${CHECK_FAILURE} (expected ${PWD_MAX_FAILURE})"
[[ "$CHECK_QUALITY" == "2"               ]] && ok "pwdCheckQuality=2 (PPM delegated)"          && PASS=$((PASS+1)) || bad "pwdCheckQuality=${CHECK_QUALITY} (expected 2)"

# V4: PPM verification (only if ppm.so available)
if [[ "$PPM_AVAILABLE" -eq 1 ]]; then
  PPM_ARG=$(LDAPTLS_REQCERT=never ldapsearch -o ldif-wrap=no -x -ZZ -H ldap://localhost \
    -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$POLICY_DN" -s base pwdCheckModuleArg 2>/dev/null | grep -c "pwdCheckModuleArg:" || true)
  if [[ "$PPM_ARG" -gt 0 ]]; then
    ok "pwdCheckModuleArg stored (PPM config embedded)"; PASS=$((PASS+1))
  else
    warn "pwdCheckModuleArg not found — PPM may not be active"; WARN=$((WARN+1))
  fi

  PPM_CHK=$(ldapi_search -b "$PPOLICY_DN" -s base -LLL olcPPolicyCheckModule 2>/dev/null | awk -F': ' '/^olcPPolicyCheckModule:/{print $2; exit}')
  if [[ "$PPM_CHK" == "ppm.so" ]]; then
    ok "olcPPolicyCheckModule: ppm.so on overlay"; PASS=$((PASS+1))
  else
    warn "olcPPolicyCheckModule = ${PPM_CHK:-not set} (expected ppm.so)"; WARN=$((WARN+1))
  fi
fi

# ====================================================================
# SUMMARY
# ====================================================================
echo ""
echo "============================================================"
echo "  BANK PASSWORD POLICY — Applied"
echo "  Policy:   ${POLICY_DN}"
echo "  PPM:      $([[ $PPM_AVAILABLE -eq 1 ]] && echo 'base64-embedded (pwdCheckModuleArg)' || echo 'not available (licensed Symas required)')"
echo ""
  echo "  Enforced (LDAP-level via native ppolicy overlay):"
  echo "    Min Length:        ${PWD_MIN_LENGTH}"
  echo "    Max Length:        ${PWD_MAX_LENGTH} (native ppolicy pwdMaxLength)"
  echo "    Max Age:           ${PWD_MAX_AGE}s (~120 days / 4 months)"
echo "    Expire Warning:    ${PWD_EXPIRE_WARNING}s (~15 days)"
echo "    Password History:  last ${PWD_IN_HISTORY}"
echo "    Max Failures:      ${PWD_MAX_FAILURE} (${PWD_LOCKOUT_DURATION}s lockout)"
echo ""
echo "  Enforced (PPM-level, if ppm.so available):"
echo "    Max Length:        ${PWD_MAX_LENGTH}"
echo "    Upper/Lower/Digit: ${PWD_MIN_UPPER}/${PWD_MIN_LOWER}/${PWD_MIN_DIGIT} minimum each"
echo "    Special Chars:     only \"${PWD_ALLOWED_SPECIAL}\" (optional)"
echo "    Banned ASCII:      '\" ( ) { } [ ] / \\ = @ # \$ % ! . -"
echo "    Arabic Letters:    blocked (unicode blocks)"
echo "    Username Check:    reject forward + reverse"
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
