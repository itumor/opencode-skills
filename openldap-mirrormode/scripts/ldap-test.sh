#!/usr/bin/env bash
set -e

LDAP_ADMIN_DN="cn=admin,dc=cae,dc=local"
LDAP_ADMIN_PASS="admin"
BASE_DN="dc=cae,dc=local"

WRITE_URI="ldap://localhost:1389"
READ_URI="ldap://localhost:2389"

echo "=== 1) ADD USER (WRITE PATH) ==="
ldapadd -x \
  -H "$WRITE_URI" \
  -D "$LDAP_ADMIN_DN" \
  -w "$LDAP_ADMIN_PASS" \
  -f /Users/eramadan/GitRepo/NEXTGenopen/openldap-mirrormode/ldif/test-user.ldif

echo
echo "=== 2) READ USER (READ PATH) ==="
ldapsearch -x \
  -H "$READ_URI" \
  -D "$LDAP_ADMIN_DN" \
  -w "$LDAP_ADMIN_PASS" \
  -b "$BASE_DN" \
  "(uid=testuser11)" dn cn uid

echo
echo "=== 3) FAILOVER TEST (STOP ONE REPLICA) ==="
docker stop ldap-replica-a
sleep 5

ldapsearch -x \
  -H "$READ_URI" \
  -D "$LDAP_ADMIN_DN" \
  -w "$LDAP_ADMIN_PASS" \
  -b "$BASE_DN" \
  "(uid=testuser11)" dn cn uid

echo
echo "=== 4) RESTORE REPLICA ==="
docker start ldap-replica-a

echo
echo "ALL TESTS COMPLETED"
