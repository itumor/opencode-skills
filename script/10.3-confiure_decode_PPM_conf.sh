#add pwd policy checker to password policy 

cat > /tmp/add_pwdPolicy_checker.ldif << 'EOF'
dn: cn=default,ou=Policies,dc=eab,dc=bank,dc=local
changetype: modify
add: objectClass
objectClass: pwdPolicyChecker

dn: cn=default,ou=policies,dc=eab,dc=bank,dc=local
changetype: modify
replace: pwdCheckQuality
pwdCheckQuality: 2

EOF

ldapmodify -x -D "cn=admin,dc=eab,dc=bank,dc=local" -W \
  -f /tmp/add_pwdPolicy_checker.ldif
  
#!/bin/bash
set -euo pipefail

# =========================
# VARIABLES (EDIT IF NEEDED)
# =========================
TMP_DIR="/tmp"
PPM_CONF="${TMP_DIR}/ppm.conf"
ENCODED_CONF="${TMP_DIR}/encoded_ppm.conf"
LDIF_FILE="${TMP_DIR}/pwdcomplexity.ldif"

POLICY_DN="cn=default,ou=Policies,dc=eab,dc=bank,dc=local"
LDAP_URI="ldap:///"
BIND_DN="cn=admin,dc=eab,dc=bank,dc=local"

# =========================
# 1. CREATE ppm.conf
# =========================
echo "[INFO] Creating ppm.conf..."

cat > "$PPM_CONF" << 'EOF'
# ============================
# Symas PPM Configuration
# ============================

# Minimum password length
minLength 10

# Character class requirements
minUpper 1
minLower 1
minDigit 1
minSpecial 1

# Password history
historySize 5

# Repetition control
#maxRepeat 2

# Reject passwords containing username
rejectUsername true

# Reject dictionary-based passwords
rejectDictionary true

# Optional: forbid specific words
forbiddenWords admin password bank welcome
EOF

# =========================
# 2. BASE64 ENCODE ppm.conf
# =========================
echo "[INFO] Encoding ppm.conf using base64..."

base64 "$PPM_CONF" > "$ENCODED_CONF"

# Remove line breaks (LDAP attribute must be single-line)
ENCODED_DATA="$(tr -d '\n' < "$ENCODED_CONF")"

# =========================
# 3. GENERATE LDIF
# =========================
echo "[INFO] Creating LDIF file..."

cat > "$LDIF_FILE" << EOF
dn: ${POLICY_DN}
changetype: modify
replace: pwdCheckModuleArg
pwdCheckModuleArg: ${ENCODED_DATA}
EOF

# =========================
# 4. APPLY LDIF TO LDAP
# =========================
echo "[INFO] Applying password complexity policy to LDAP..."
ldapmodify -x -H "$LDAP_URI" -D "$BIND_DN" -W -f "$LDIF_FILE"

echo "[SUCCESS] Password complexity policy applied successfully."
