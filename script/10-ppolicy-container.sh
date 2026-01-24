cat > /tmp/ppolicy-container.ldif << 'EOF'

dn: ou=Policies,dc=eab,dc=bank,dc=local
objectClass: top
objectClass: organizationalUnit
ou: Policies
description: Password Policies


dn: cn=default,ou=policies,dc=eab,dc=bank,dc=local
objectClass: pwdPolicy
objectClass: person
objectClass: top
cn: default
sn: default
pwdAttribute: userPassword
pwdMaxAge: 7776000
pwdExpireWarning: 604800
pwdInHistory: 5
pwdCheckQuality: 1
pwdMinLength: 8
pwdMaxFailure: 5
pwdLockout: TRUE
pwdLockoutDuration: 1800
pwdGraceAuthNLimit: 3
pwdFailureCountInterval: 0
pwdMustChange: FALSE
pwdAllowUserChange: TRUE
pwdSafeModify: FALSE

EOF

#ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/pw_load_module.ldif
ldapadd -x   -D "cn=admin,dc=eab,dc=bank,dc=local"   -W   -H ldap://localhost   -f /tmp/ppolicy-container.ldif