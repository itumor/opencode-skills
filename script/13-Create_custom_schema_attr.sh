cat > /tmp/create-bank-schema-attr.ldif << 'EOF'
dn: cn={3}bank-custom,cn=schema,cn=config
changetype: modify
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.1 NAME 'userisactive' DESC 'User active flag' EQUALITY booleanMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.7 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.2 NAME 'memorableAnswer' DESC 'Memorable answer' EQUALITY caseExactMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.3 NAME 'memorableQuestion' DESC 'Memorable question' EQUALITY caseIgnoreMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.4 NAME 'activationdatetime' DESC 'Account activation datetime' EQUALITY generalizedTimeMatch ORDERING generalizedTimeOrderingMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.24 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.5 NAME 'cif' DESC 'Customer Information File ID' EQUALITY caseExactMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcObjectClasses
olcObjectClasses: ( 1.3.6.1.4.1.55555.2.1 NAME 'bankUserExtension' SUP top AUXILIARY MAY ( userisactive $ memorableAnswer $ memorableQuestion $ activationdatetime $ cif ) )
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/create-bank-schema-attr.ldif