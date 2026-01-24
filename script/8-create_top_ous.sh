

#create Users,Admins,Groups,Systems
cat > /tmp/create-top-ous.ldif << 'EOF'
dn: ou=Users,dc=eab,dc=bank,dc=local
objectClass: top
objectClass: organizationalUnit
ou: Users

dn: ou=Admins,dc=eab,dc=bank,dc=local
objectClass: top
objectClass: organizationalUnit
ou: Admins

dn: ou=Groups,dc=eab,dc=bank,dc=local
objectClass: top
objectClass: organizationalUnit
ou: Groups

dn: ou=Systems,dc=eab,dc=bank,dc=local
objectClass: top
objectClass: organizationalUnit
ou: Systems
EOF

ldapadd -x   -D "cn=admin,dc=eab,dc=bank,dc=local"   -W   -H ldap://localhost   -f /tmp/create-top-ous.ldif