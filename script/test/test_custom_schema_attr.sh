cat > /tmp/test-bank-schema-attr.ldif << 'EOF'
dn: uid=test1,ou=Users,dc=eab,dc=bank,dc=local
objectClass: inetOrgPerson
objectClass: bankUserExtension
uid: test1
cn: Test User
sn: User
employeeNumber: 12345
userPassword: Test@123
memorableAnswer: answer1
memorableQuestion: What is your favorite color?
userisactive: TRUE
cif: CIF123456
activationdatetime: 20260119120000Z
EOF
ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/test-bank-schema-attr.ldif