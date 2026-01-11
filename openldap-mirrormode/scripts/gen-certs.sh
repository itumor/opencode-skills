#!/usr/bin/env bash
set -euo pipefail

mkdir -p certs
cd certs

# 1) CA
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -subj "/C=EG/O=Lab-CA/OU=LDAP/CN=Lab LDAP CA" \
  -out ca.crt

# 2) Server key + CSR
openssl genrsa -out ldap.key 4096

cat > san.cnf <<'CONF'
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
C=EG
O=Lab-Org
OU=LDAP
CN=ldap-write

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ldap-write
DNS.2 = ldap-read
DNS.3 = ldap-master-a
DNS.4 = ldap-master-b
DNS.5 = ldap-replica-a
DNS.6 = ldap-replica-b
DNS.7 = localhost
IP.1  = 127.0.0.1
CONF

openssl req -new -key ldap.key -out ldap.csr -config san.cnf
openssl x509 -req -in ldap.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out ldap.crt -days 825 -sha256 -extensions req_ext -extfile san.cnf

# osixia/openldap expects specific filenames we will reference via env vars
# We'll use:
#   ca.crt, ldap.crt, ldap.key
chmod 600 ldap.key
echo "Certs generated in ./certs"

chown -R 911:911 certs/
chmod -R 600 certs/*.key
chmod -R 644 certs/*.crt
