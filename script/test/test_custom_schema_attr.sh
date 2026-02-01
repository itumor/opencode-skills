cat > /tmp/test-bank-schema-attr.ldif << 'EOF'
dn: uid=test5,ou=Users,dc=eab,dc=bank,dc=local
objectClass: inetOrgPerson
objectClass: bankUserExtension
uid: test5
cn: Test User
sn: User
employeeNumber: 12345
userPassword: Password1!
memorableAnswer: answer1
memorableQuestion: What is your favorite color?
userisactive: TRUE
cif: CIF123456
activationdatetime: 20260119120000Z
EOF
ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/test-bank-schema-attr.ldif