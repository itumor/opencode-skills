cat > /tmp/create-bank-schema.ldif << 'EOF'
dn: cn=bank-custom,cn=schema,cn=config
objectClass: olcSchemaConfig
cn: bank-custom
EOF
ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/create-bank-schema.ldif


