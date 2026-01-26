#Load the last bind 
cat > /tmp/lastbind_overlay.ldif << 'EOF'
dn: cn=module{1},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: lastbind
EOF

ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/lastbind_overlay.ldif 

#add the lastbind overlay to the database
cat > /tmp/add_lastbind_overlay.ldif << 'EOF'
dn: olcOverlay=lastbind,olcDatabase={1}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcLastBindConfig
olcOverlay: lastbind
EOF

ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/add_lastbind_overlay.ldif 


