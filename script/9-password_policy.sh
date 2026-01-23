#create the root OU
cat > /tmp/pw_load_module.ldif << 'EOF'
dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulePath: /opt/symas/lib/openldap
olcModuleLoad: ppolicy

EOF

ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/pw_load_module.ldif
