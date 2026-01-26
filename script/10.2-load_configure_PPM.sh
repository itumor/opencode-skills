#Load the PPM overlay 
cat > /tmp/ppm_overlay.ldif << 'EOF'
dn: cn=module{1},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: ppm
EOF

ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/ppm_overlay.ldif 
#verify
ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b cn=module{1},cn=config olcModuleLoad
  
#modify the pollicy to refer to the policy check module PPM
cat > /tmp/add_ppm_overlay.ldif << 'EOF'
dn: olcOverlay=ppolicy,olcDatabase={1}mdb,cn=config
changetype: modify
add: olcPPolicyCheckModule
olcPPolicyCheckModule: ppm
EOF

ldapmodify  -Y EXTERNAL -H ldapi:/// -f /tmp/add_ppm_overlay.ldif 

#verify 
ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b "olcOverlay=ppolicy,olcDatabase={1}mdb,cn=config" \
  olcPPolicyCheckModule
  
#ADD PPm configuration file   
#!/bin/bash
set -euo pipefail

PPM_CONF="/opt/symas/etc/openldap/ppm.conf"
PPM_DIR="$(dirname "$PPM_CONF")"

echo "[INFO] Creating PPM configuration directory if missing..."
mkdir -p "$PPM_DIR"

echo "[INFO] Writing PPM configuration to $PPM_CONF"

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
maxRepeat 2

# Reject passwords containing username
rejectUsername true

# Reject dictionary-based passwords
rejectDictionary true

# Optional: forbid specific words
forbiddenWords admin password bank welcome
EOF

echo "[INFO] Setting ownership and permissions..."
chown ldap:ldap "$PPM_CONF"
chmod 600 "$PPM_CONF"

echo "[SUCCESS] PPM configuration file created and secured."

#attach he PPM configuration path to the cn config 
cat > /tmp/attach-ppm-config.ldif << 'EOF'
dn: cn=config
changetype: modify
replace: olcPpmConfigFile
olcPpmConfigFile: /opt/symas/etc/openldap/ppm.conf

ldapmodify -Y EXTERNAL -H ldapi:/// -f attach-ppm-config.ldif
EOF

#restart required 
systemctl restart symas-openldap-servers