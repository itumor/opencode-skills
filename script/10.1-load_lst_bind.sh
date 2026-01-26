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
