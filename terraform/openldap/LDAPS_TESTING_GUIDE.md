# LDAPS Testing Guide (CA-Signed Certificate)

Use this guide to validate connectivity and LDAP behavior after migrating from self-signed certs to a CA-signed chain.

For the full endpoint inventory (GA, NLB, and all node public/private IPs) plus LDAP Studio profile settings, use:

- `/Users/eramadan/GitRepo/NEXTGenopen/terraform/openldap/CONNECTION_ENDPOINTS.md`

## What the tester needs

Provide these values explicitly:

- `BASE_DN` (example: `dc=cae,dc=local`)
- `BIND_DN` and password (read-only account preferred; write-capable account only for write tests)
- CA certificate file (`ca.crt`) that anchors trust for the server certificate chain
- Read endpoint hostname (custom DNS): `ldap-read.<your-domain>`
- Write endpoint hostname (custom DNS): `ldap-write.<your-domain>`
- Allowed source IP(s)

Never provide private keys to testers.

## Current deployed endpoints (February 19, 2026)

- Read endpoint (GA): `aa99eb27c555144df.awsglobalaccelerator.com`
- Write endpoint (GA): `a6ba558900a42b3c3.awsglobalaccelerator.com`

Preferred long-term client targets remain custom DNS names (`ldap-read.<domain>`, `ldap-write.<domain>`) that CNAME/alias to GA/NLB and are present in SAN.

## TLS/Certificate policy for this environment

- Server-side TLS is terminated on OpenLDAP (`slapd`) through TCP pass-through LB/GA.
- Certificate mode is expected to be `external_required`.
- Custom DNS names are required and must appear in certificate SANs.
- Client validation must be strict:
  - `LDAPTLS_REQCERT=demand`
  - no trust-all / permissive mode for normal testing.

## Operator rollout reference

Run the rollout utility from this repo:

```bash
bash /Users/eramadan/GitRepo/NEXTGenopen/terraform/openldap/tools/rollout_ca_signed_tls.sh \
  --ca-cert /secure/path/ca.crt \
  --server-cert /secure/path/ldap-chain.pem \
  --server-key /secure/path/ldap.key \
  --read-host ldap-read.example.com \
  --write-host ldap-write.example.com \
  --bind-dn 'cn=admin,dc=cae,dc=local' \
  --bind-pw '<bind-password>' \
  --base-dn 'dc=cae,dc=local'
```

This script runs preflight, Terraform apply, TLS handshake checks, and strict LDAP validation.

## Tester setup (Linux/macOS)

```bash
export BASE_DN="<set-me>"
export BIND_DN="<set-me>"
export BIND_PW="<set-me>"
export READ_HOST="<set-me>"
export WRITE_HOST="<set-me>"
export LDAPTLS_CACERT="$PWD/ca.crt"
export LDAPTLS_REQCERT=demand
```

## Connectivity checks (no credentials)

```bash
openssl s_client -connect "${READ_HOST}:636" -servername "${READ_HOST}" -showcerts -CAfile "$LDAPTLS_CACERT" </dev/null
openssl s_client -connect "${WRITE_HOST}:636" -servername "${WRITE_HOST}" -showcerts -CAfile "$LDAPTLS_CACERT" </dev/null
openssl s_client -connect "${READ_HOST}:389" -starttls ldap -servername "${READ_HOST}" -showcerts -CAfile "$LDAPTLS_CACERT" </dev/null
openssl s_client -connect "${WRITE_HOST}:389" -starttls ldap -servername "${WRITE_HOST}" -showcerts -CAfile "$LDAPTLS_CACERT" </dev/null
```

Expected in each output:

- `Verify return code: 0 (ok)`

## Terminal checks for all endpoints

For full endpoint inventory and terminal loops covering GA, NLB, and node endpoints for LDAP/StartTLS/LDAPS, use:

- `/Users/eramadan/GitRepo/NEXTGenopen/terraform/openldap/CONNECTION_ENDPOINTS.md`

macOS note:

- `openssl s_client` can pass while `/usr/bin/ldapwhoami` fails with TLS handshake errors.
- If this happens, trust the CA in System Keychain:

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/openldap-ca-rollout-20260218T2300Z/ca.crt
```

Apache Directory Studio note (same machine):

```bash
/usr/bin/keytool -importcert -noprompt -trustcacerts \
  -alias lab-ldap-ca-current-20260218 \
  -file /tmp/openldap-ca-rollout-20260218T2300Z/ca.crt \
  -keystore /Users/eramadan/.ldap-certs/lab-ldap-truststore.jks \
  -storepass changeit
```

Restart Studio after import.

Quick command to run LDAPS auth check across all DNS endpoints:

```bash
export BIND_DN='cn=admin,dc=cae,dc=local'
export BIND_PW='admin'
export LDAPTLS_CACERT='/secure/path/ca.crt'
export LDAPTLS_REQCERT='demand'

ALL_DNS_ENDPOINTS=(
  aa99eb27c555144df.awsglobalaccelerator.com
  a6ba558900a42b3c3.awsglobalaccelerator.com
  openldap-mm-live-r-0d5b45e4360d3f90.elb.us-east-1.amazonaws.com
  openldap-mm-live-w-85bb4d1c5f42e3a2.elb.us-east-1.amazonaws.com
  openldap-mm-dr-r-94aae6c2d6961ea0.elb.us-east-1.amazonaws.com
  openldap-mm-dr-w-5e9af129d85de929.elb.us-east-1.amazonaws.com
)

for H in "${ALL_DNS_ENDPOINTS[@]}"; do
  echo "=== LDAPS bind ldaps://$H:636 ==="
  ldapwhoami -x -H "ldaps://$H:636" -D "$BIND_DN" -w "$BIND_PW"
done
```

## LDAP checks with credentials

### 1) Bind checks

```bash
ldapwhoami -x -H "ldaps://${READ_HOST}:636" -D "${BIND_DN}" -w "${BIND_PW}"
ldapwhoami -x -H "ldaps://${WRITE_HOST}:636" -D "${BIND_DN}" -w "${BIND_PW}"
ldapwhoami -x -ZZ -H "ldap://${READ_HOST}:389" -D "${BIND_DN}" -w "${BIND_PW}"
```

### 2) Base DN checks

```bash
ldapsearch -LLL -x -H "ldaps://${READ_HOST}:636" -D "${BIND_DN}" -w "${BIND_PW}" -b "${BASE_DN}" -s base dn
ldapsearch -LLL -x -ZZ -H "ldap://${READ_HOST}:389" -D "${BIND_DN}" -w "${BIND_PW}" -b "${BASE_DN}" -s base dn
```

### 3) Write/read replication test (only with write-capable account)

```bash
TS="$(date +%Y%m%d%H%M%S)"
CN="ldaps-test-${TS}"
DN="cn=${CN},${BASE_DN}"

cat >"/tmp/${CN}.ldif" <<EOF
dn: ${DN}
objectClass: organizationalRole
cn: ${CN}
description: ${CN}
EOF

ldapadd -x -H "ldaps://${WRITE_HOST}:636" -D "${BIND_DN}" -w "${BIND_PW}" -f "/tmp/${CN}.ldif"

ldapsearch -LLL -x -H "ldaps://${READ_HOST}:636" -D "${BIND_DN}" -w "${BIND_PW}" -b "${BASE_DN}" "(cn=${CN})" dn cn

ldapdelete -x -H "ldaps://${WRITE_HOST}:636" -D "${BIND_DN}" -w "${BIND_PW}" "${DN}"
```

### 4) TLS enforcement check

Plain LDAP bind without StartTLS should fail when `require_tls_simple_binds=true`:

```bash
ldapwhoami -x -H "ldap://${WRITE_HOST}:389" -D "${BIND_DN}" -w "${BIND_PW}"
```

Expected: non-zero exit / bind failure when TLS simple-bind enforcement is active.

## Troubleshooting

- `Verify return code` not `0`:
  - CA file is wrong/incomplete, or chain is incomplete.
- Hostname mismatch:
  - SAN does not include the custom read/write hostnames used by tester.
- `Can't contact LDAP server`:
  - LB listener/SG/routing issue or source IP not allowlisted.
- StartTLS protocol error on `389`:
  - StartTLS not enabled or wrong endpoint/port used.

## Notes for Apache Directory Studio

- Use custom DNS names (`ldap-read...`, `ldap-write...`) in connection profiles.
- Import CA into Studio/JVM truststore.
- Keep hostname verification enabled.
