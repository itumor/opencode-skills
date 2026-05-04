# LDAP Connection Endpoints (CA-Signed Standard)

This document lists all active LDAP endpoints for this deployment and how to create LDAP Studio connections.

Last verified: February 19, 2026

## Environment Defaults

- Base DN: `dc=cae,dc=local`
- Typical admin bind DN: `cn=admin,dc=cae,dc=local`
- TLS mode: `external_required` with CA-signed certs
- Supported secure client modes:
  - LDAPS on `636`
  - StartTLS on `389`

## Preferred Client Endpoints

Use stable custom DNS names for applications and LDAP Studio:

- Read: `ldap-read.<your-domain>`
- Write: `ldap-write.<your-domain>`

These names must CNAME/alias to active GA/NLB endpoints and must be present in the cert SAN.

## Active Global Accelerator Endpoints

Use these immediately if custom DNS is not cut over yet:

- Read (GA): `aa99eb27c555144df.awsglobalaccelerator.com`
- Write (GA): `a6ba558900a42b3c3.awsglobalaccelerator.com`

## Active NLB Endpoints (Per VPC)

| Endpoint | Hostname |
|---|---|
| Live Read NLB | `openldap-mm-live-r-0d5b45e4360d3f90.elb.us-east-1.amazonaws.com` |
| Live Write NLB | `openldap-mm-live-w-85bb4d1c5f42e3a2.elb.us-east-1.amazonaws.com` |
| DR Read NLB | `openldap-mm-dr-r-94aae6c2d6961ea0.elb.us-east-1.amazonaws.com` |
| DR Write NLB | `openldap-mm-dr-w-5e9af129d85de929.elb.us-east-1.amazonaws.com` |

## All Node Endpoints (Direct Node Access)

Use direct node endpoints mainly for operations/debugging from trusted networks.

| Node | Role | Instance ID | Private IP | Public IP |
|---|---|---|---|---|
| `live-master-1` | Write (master) | `i-0965d8937987fc768` | `10.10.0.10` | `3.223.2.159` |
| `live-replica-1` | Read (replica) | `i-026bd28964b6e8242` | `10.10.1.30` | `52.207.209.103` |
| `live-replica-2` | Read (replica) | `i-0f1784e7fb43a0eb5` | `10.10.0.31` | `18.215.34.91` |
| `dr-master-1` | Write (master) | `i-05320074b4b658f15` | `10.20.0.10` | `3.236.134.3` |
| `dr-replica-1` | Read (replica) | `i-00e34988e13d6cba6` | `10.20.1.30` | `100.26.191.241` |
| `dr-replica-2` | Read (replica) | `i-024b25eff56c83a8a` | `10.20.0.31` | `3.219.28.90` |

Keepalived EIP currently attached to `live-master-1`:

- `3.223.2.159`

## LDAP Studio Connection Profiles

Create these profiles in Apache Directory Studio.

### Profile 1 (Recommended Read)

- Connection name: `LDAP Read (GA LDAPS)`
- Hostname: `aa99eb27c555144df.awsglobalaccelerator.com`
- Port: `636`
- Encryption method: `Use SSL encryption (ldaps://)`
- Authentication method: `Simple Authentication`
- Bind DN/User: `cn=admin,dc=cae,dc=local` (or your read-only service DN)
- Bind password: `<your-password>`
- Base DN for browser: `dc=cae,dc=local`

### Profile 2 (Recommended Write)

- Connection name: `LDAP Write (GA LDAPS)`
- Hostname: `a6ba558900a42b3c3.awsglobalaccelerator.com`
- Port: `636`
- Encryption method: `Use SSL encryption (ldaps://)`
- Authentication method: `Simple Authentication`
- Bind DN/User: `cn=admin,dc=cae,dc=local` (or your write-capable service DN)
- Bind password: `<your-password>`
- Base DN for browser: `dc=cae,dc=local`

### Profile 3-6 (Per-VPC NLB Fallback)

- `LDAP Read (Live NLB LDAPS)`:
  - Host: `openldap-mm-live-r-0d5b45e4360d3f90.elb.us-east-1.amazonaws.com`
  - Port: `636`
- `LDAP Write (Live NLB LDAPS)`:
  - Host: `openldap-mm-live-w-85bb4d1c5f42e3a2.elb.us-east-1.amazonaws.com`
  - Port: `636`
- `LDAP Read (DR NLB LDAPS)`:
  - Host: `openldap-mm-dr-r-94aae6c2d6961ea0.elb.us-east-1.amazonaws.com`
  - Port: `636`
- `LDAP Write (DR NLB LDAPS)`:
  - Host: `openldap-mm-dr-w-5e9af129d85de929.elb.us-east-1.amazonaws.com`
  - Port: `636`

Use the same bind/base settings as Profile 1 and 2.

### StartTLS Profile Variant (If You Need Port 389)

For any of the hosts above:

- Port: `389`
- Encryption method: `Use StartTLS extension`

## CA Trust Requirements For Studio

- Import CA cert into JVM truststore used by Studio.
- Keep certificate/hostname verification enabled.
- Do not use trust-all mode for normal operation.

Studio on this machine is configured with:

- Truststore: `/Users/eramadan/.ldap-certs/lab-ldap-truststore.jks`

Import current CA into that truststore:

```bash
/usr/bin/keytool -importcert -noprompt -trustcacerts \
  -alias lab-ldap-ca-current-20260218 \
  -file /tmp/openldap-ca-rollout-20260218T2300Z/ca.crt \
  -keystore /Users/eramadan/.ldap-certs/lab-ldap-truststore.jks \
  -storepass changeit
```

Then fully restart Apache Directory Studio.

If Studio shows `PROTOCOL_ERROR: The server will disconnect!`, verify connection mode/port pairing:

- LDAPS: port `636` with `Use SSL encryption` (not StartTLS)
- StartTLS: port `389` with `Use StartTLS extension` (not SSL)

## Important Notes About Direct Node IP Connections

- Cert SAN contains private node IPs and GA/NLB DNS names used in this deployment.
- Public node IPs are not the standard client target and may fail strict hostname verification.
- For strict TLS from outside VPC, use:
  - Custom DNS names (`ldap-read.<domain>`, `ldap-write.<domain>`) or
  - GA/NLB hostnames listed above.

## Quick TLS Verification Commands

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/openldap-ca-rollout-20260218T2300Z/ca.crt
ldapwhoami -x -ZZ -H "ldap://a6ba558900a42b3c3.awsglobalaccelerator.com:389" -D "cn=admin,dc=cae,dc=local" -w "admin"
ldapwhoami -x -H "ldaps://a6ba558900a42b3c3.awsglobalaccelerator.com:636" -D "cn=admin,dc=cae,dc=local" -w "admin"

export LDAPTLS_CACERT='/tmp/openldap-ca-rollout-20260218T2300Z/ca.crt'
openssl s_client -connect aa99eb27c555144df.awsglobalaccelerator.com:636 -servername aa99eb27c555144df.awsglobalaccelerator.com -showcerts -CAfile "$LDAPTLS_CACERT" </dev/null
openssl s_client -connect a6ba558900a42b3c3.awsglobalaccelerator.com:636 -servername a6ba558900a42b3c3.awsglobalaccelerator.com -showcerts -CAfile "$LDAPTLS_CACERT" </dev/null
```

Expected:

- `Verify return code: 0 (ok)`

## Terminal Connection Commands (All Endpoints)

Use these commands from terminal to test LDAP auth/search against every endpoint.

## macOS Client Note (Important)

On macOS, `/usr/bin/ldapwhoami` and `/usr/bin/ldapsearch` use Apple security frameworks (not OpenSSL).
Because of that, they may fail with TLS errors even when `openssl s_client` succeeds with `-CAfile`.

If you see errors like:

- `SSLHandshake() failed: misc. bad certificate (-9825)`
- `ldap_sasl_bind(SIMPLE): Can't contact LDAP server (-1)`

do one of these:

1. Trust the CA in Keychain (recommended for Apple LDAP tools and LDAP Studio JVM trust):

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/openldap-ca-rollout-20260218T2300Z/ca.crt
```

2. Or use Homebrew OpenLDAP clients (OpenSSL-based) instead of `/usr/bin`:

```bash
brew install openldap
export PATH="/opt/homebrew/opt/openldap/bin:$PATH"
```

### 1) Set shared variables

```bash
export BIND_DN='cn=admin,dc=cae,dc=local'
export BIND_PW='admin'
export BASE_DN='dc=cae,dc=local'
export LDAPTLS_CACERT='/tmp/openldap-ca-rollout-20260218T2300Z/ca.crt'
export LDAPTLS_REQCERT='demand'
```

### 2) Define endpoint lists

```bash
ALL_DNS_ENDPOINTS=(
  aa99eb27c555144df.awsglobalaccelerator.com
  a6ba558900a42b3c3.awsglobalaccelerator.com
  openldap-mm-live-r-0d5b45e4360d3f90.elb.us-east-1.amazonaws.com
  openldap-mm-live-w-85bb4d1c5f42e3a2.elb.us-east-1.amazonaws.com
  openldap-mm-dr-r-94aae6c2d6961ea0.elb.us-east-1.amazonaws.com
  openldap-mm-dr-w-5e9af129d85de929.elb.us-east-1.amazonaws.com
)

PRIVATE_NODE_ENDPOINTS=(
  10.10.0.10
  10.10.1.30
  10.10.0.31
  10.20.0.10
  10.20.1.30
  10.20.0.31
)

PUBLIC_NODE_ENDPOINTS=(
  3.223.2.159
  52.207.209.103
  18.215.34.91
  3.236.134.3
  100.26.191.241
  3.219.28.90
)
```

### 3) LDAP on port 389 (no TLS)

```bash
for H in "${ALL_DNS_ENDPOINTS[@]}"; do
  echo "=== LDAP plain bind ldap://$H:389 ==="
  ldapwhoami -x -H "ldap://$H:389" -D "$BIND_DN" -w "$BIND_PW"
done
```

### 4) LDAP with StartTLS on port 389 (recommended over plain 389)

```bash
for H in "${ALL_DNS_ENDPOINTS[@]}"; do
  echo "=== LDAP StartTLS bind ldap://$H:389 ==="
  ldapwhoami -x -ZZ -H "ldap://$H:389" -D "$BIND_DN" -w "$BIND_PW"
done
```

### 5) LDAPS on port 636 (recommended)

```bash
for H in "${ALL_DNS_ENDPOINTS[@]}"; do
  echo "=== LDAPS bind ldaps://$H:636 ==="
  ldapwhoami -x -H "ldaps://$H:636" -D "$BIND_DN" -w "$BIND_PW"
done
```

### 6) Base-DN search over LDAPS for all DNS endpoints

```bash
for H in "${ALL_DNS_ENDPOINTS[@]}"; do
  echo "=== LDAPS base search ldaps://$H:636 ==="
  ldapsearch -LLL -x -H "ldaps://$H:636" -D "$BIND_DN" -w "$BIND_PW" -b "$BASE_DN" -s base dn
done
```

### 7) Private node IP checks (inside VPC/bastion only)

These private IP commands are intended for hosts that can route to the VPC CIDRs.

```bash
for H in "${PRIVATE_NODE_ENDPOINTS[@]}"; do
  echo "=== StartTLS to private node ldap://$H:389 ==="
  ldapwhoami -x -ZZ -H "ldap://$H:389" -D "$BIND_DN" -w "$BIND_PW"
  echo "=== LDAPS to private node ldaps://$H:636 ==="
  ldapwhoami -x -H "ldaps://$H:636" -D "$BIND_DN" -w "$BIND_PW"
done
```

### 8) Public node IP checks

Plain LDAP to public node IPs:

```bash
for H in "${PUBLIC_NODE_ENDPOINTS[@]}"; do
  echo "=== LDAP plain bind ldap://$H:389 ==="
  ldapwhoami -x -H "ldap://$H:389" -D "$BIND_DN" -w "$BIND_PW"
done
```

Strict LDAPS to public IPs may fail hostname verification because SAN is not guaranteed for public IPs.
Diagnostic-only command (not for production):

```bash
for H in "${PUBLIC_NODE_ENDPOINTS[@]}"; do
  echo "=== LDAPS public IP (diagnostic, no hostname verify) ldaps://$H:636 ==="
  ldapwhoami -x -o TLS_REQCERT=never -H "ldaps://$H:636" -D "$BIND_DN" -w "$BIND_PW"
done
```
