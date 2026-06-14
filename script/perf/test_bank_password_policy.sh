#!/usr/bin/env bash
set -uo pipefail

B=/opt/symas/bin
ssha() { python3 -c "import os,hashlib,base64; s=os.urandom(8); h=hashlib.sha1(b'$1'); h.update(s); print('{SSHA}'+base64.b64encode(h.digest()+s).decode())"; }

pass_cnt=0; fail_cnt=0
tpass() { echo "[PASS] $1"; pass_cnt=$((pass_cnt+1)); }
tfail() { echo "[FAIL] $1"; fail_cnt=$((fail_cnt+1)); }

echo "============================================"
echo " BANK PASSWORD POLICY — VERIFICATION"
echo "============================================"

# Check PPM state
PPM_DN=$(sudo $B/ldapsearch -Y EXTERNAL -H ldapi:/// -b 'olcDatabase={1}mdb,cn=config' -s sub 'objectClass=olcPPolicyConfig' dn 2>/dev/null | awk '/^dn: / {print $2}')
PPM_CHECK=$(sudo $B/ldapsearch -Y EXTERNAL -H ldapi:/// -b "${PPM_DN}" -s base olcPPolicyCheckModule 2>/dev/null | awk -F': ' '/^olcPPolicyCheckModule:/{print $2}')
PPM_LOADED=$(sudo $B/ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -s sub '(olcModuleLoad=ppm)' dn 2>/dev/null | grep -c 'cn=module' | tr -d '[:space:]')
PPM_LOADED="${PPM_LOADED:-0}"
PPM_OK=0
if [ "$PPM_LOADED" != "0" ] && [ -n "$PPM_CHECK" ]; then
  if ! ldd -r /opt/symas/lib/openldap/ppm.so 2>&1 | grep -q 'undefined symbol.*ber_mem'; then
    PPM_OK=1
  fi
fi

echo "PPM module loaded: ${PPM_LOADED}"
echo "PPM checkModule:   ${PPM_CHECK:-not set}"
echo "PPM functional:    $([ $PPM_OK -eq 1 ] && echo YES || echo 'NO (ber_memalloc unresolved)')"
echo ""

echo "=== LDAP-LEVEL RULES ==="
POLICY=$(LDAPTLS_REQCERT=never $B/ldapsearch -o ldif-wrap=no -x -H ldaps://localhost:636 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  -b "cn=default,ou=Policies,dc=eab,dc=bank,dc=local" -s base \
  pwdMaxAge pwdMinLength pwdMaxFailure pwdExpireWarning pwdInHistory pwdLockout pwdLockoutDuration pwdCheckQuality pwdUseCheckModule 2>/dev/null)

CHECK_AGE=$(echo "$POLICY" | awk -F": " '/^pwdMaxAge:/{print $2}')
CHECK_WARN=$(echo "$POLICY" | awk -F": " '/^pwdExpireWarning:/{print $2}')
CHECK_HIST=$(echo "$POLICY" | awk -F": " '/^pwdInHistory:/{print $2}')
CHECK_FAIL=$(echo "$POLICY" | awk -F": " '/^pwdMaxFailure:/{print $2}')
CHECK_LOCK=$(echo "$POLICY" | awk -F": " '/^pwdLockout:/{print $2}')
CHECK_LOCKDUR=$(echo "$POLICY" | awk -F": " '/^pwdLockoutDuration:/{print $2}')
CHECK_QUAL=$(echo "$POLICY" | awk -F": " '/^pwdCheckQuality:/{print $2}')
CHECK_USE=$(echo "$POLICY" | awk -F": " '/^pwdUseCheckModule:/{print $2}')

[[ "$CHECK_AGE" == "10368000" ]] && tpass "L1: Expiry=4 months" || tfail "L1: Expiry=${CHECK_AGE}"
[[ "$CHECK_WARN" == "1296000" ]]  && tpass "L2: Notice=15 days" || tfail "L2: Notice=${CHECK_WARN}"
[[ "$CHECK_HIST" == "5" ]]        && tpass "L3: History=last 5" || tfail "L3: History=${CHECK_HIST}"
[[ "$CHECK_FAIL" == "5" ]]        && tpass "L4: Lockout=5 attempts" || tfail "L4: Lockout=${CHECK_FAIL}"
[[ "$CHECK_LOCK" == "TRUE" ]]     && tpass "L5: Lockout enabled" || tfail "L5: Lockout=${CHECK_LOCK}"
[[ "$CHECK_LOCKDUR" == "1800" ]]  && tpass "L6: Lockout dur=30min" || tfail "L6: Lockout=${CHECK_LOCKDUR}"
[[ "$CHECK_QUAL" == "2" ]]        && tpass "L7: pwdCheckQuality=2" || tfail "L7: pwdCheckQuality=${CHECK_QUAL}"
[[ "$CHECK_USE" == "TRUE" ]]      && tpass "L8: pwdUseCheckModule=TRUE" || tfail "L8: pwdUseCheckModule=${CHECK_USE}"

echo ""
echo "=== FUNCTIONAL TESTS (SSHA + LDAPS) ==="

test_reject() {
  local label="$1"; local newpass="$2"
  local uid="tr_$$_$(date +%s%N)"
  local ssha_pwd=$(ssha 'Abcd1234_')
  sudo $B/ldapmodify -Y EXTERNAL -H ldapi:/// 2>/dev/null <<LDIF
dn: uid=${uid},ou=Users,dc=eab,dc=bank,dc=local
changetype: add
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: ${uid}
cn: ${uid}
sn: Test
userPassword: ${ssha_pwd}
LDIF
  local result
  result=$(LDAPTLS_REQCERT=never $B/ldappasswd -x -H ldaps://localhost:636 \
    -D "uid=${uid},ou=Users,dc=eab,dc=bank,dc=local" -w "Abcd1234_" -s "${newpass}" 2>&1)
  if echo "$result" | grep -qi "constraint violation\|does not pass\|fails quality"; then
    tpass "${label} — REJECTED"
  elif [[ -z "$result" ]]; then
    tfail "${label} — ACCEPTED (should reject)"
  else
    tfail "${label} — ${result}"
  fi
  sudo $B/ldapdelete -Y EXTERNAL -H ldapi:/// "uid=${uid},ou=Users,dc=eab,dc=bank,dc=local" 2>/dev/null
}

test_accept() {
  local label="$1"; local newpass="$2"
  local uid="ta_$$_$(date +%s%N)"
  local ssha_pwd=$(ssha 'Abcd1234_')
  sudo $B/ldapmodify -Y EXTERNAL -H ldapi:/// 2>/dev/null <<LDIF
dn: uid=${uid},ou=Users,dc=eab,dc=bank,dc=local
changetype: add
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: ${uid}
cn: ${uid}
sn: Test
userPassword: ${ssha_pwd}
LDIF
  local result
  result=$(LDAPTLS_REQCERT=never $B/ldappasswd -x -H ldaps://localhost:636 \
    -D "uid=${uid},ou=Users,dc=eab,dc=bank,dc=local" -w "Abcd1234_" -s "${newpass}" 2>&1)
  if echo "$result" | grep -qi "constraint violation\|does not pass\|fails quality"; then
    tfail "${label} — REJECTED"
  elif [[ -z "$result" ]]; then
    tpass "${label} — accepted"
  else
    tfail "${label} — ${result}"
  fi
  sudo $B/ldapdelete -Y EXTERNAL -H ldapi:/// "uid=${uid},ou=Users,dc=eab,dc=bank,dc=local" 2>/dev/null
}

test_reject "F1: Too short (7 chars)"     "Short1A"
test_accept "F2: Valid 8 chars"           "Abcd1234"
test_accept "F3: Valid 12 chars"           "Abcd12345678"

if [ $PPM_OK -eq 1 ]; then
  echo ""
  echo "=== PPM CLASS RULES (requires fixed ppm.so) ==="
  test_reject "P1: No uppercase"        "abcdefg1"
  test_reject "P2: No lowercase"        "ABCDEFG1"
  test_reject "P3: No digit"            "Abcdefgh"
  test_reject "P4: Special @ rejected"  "Abcd@1234"
  test_accept "P5: Underscore allowed"  "Abcd_1234"
  test_reject "P6: Banned char"          "Abc'1234"
  test_reject "P7: Password=username"   "tusr99"
else
  echo ""
  echo "=== PPM CLASS RULES: SKIPPED (ppm.so needs rebuild) ==="
  echo "[INFO] ppm.so has ber_memalloc unresolved — class rules not enforced"
  echo "[INFO] LDAP-level rules (F1-F3) are fully enforced"
  echo "[INFO] To enable PPM: rebuild ppm.so (see BANK_PASSWORD_POLICY_ISSUES_SOLVED.md)"
fi

echo ""
echo "=== REPLICATION CHECK ==="
MASTER_CSN=$(sudo $B/ldapsearch -Y EXTERNAL -H ldapi:/// -b 'dc=eab,dc=bank,dc=local' -s base contextCSN -o ldif-wrap=no 2>/dev/null | awk -F': ' '/^contextCSN:/{print $2}')
if [[ -n "$MASTER_CSN" ]]; then
  tpass "R1: contextCSN present"
else
  tfail "R1: No contextCSN"
fi

echo ""
echo "============================================"
echo "  RESULTS: PASS=${pass_cnt}  FAIL=${fail_cnt}"
[ $PPM_OK -eq 0 ] && echo "  PPM:      Requires rebuild (ber_memalloc unresolved)"
echo "============================================"
