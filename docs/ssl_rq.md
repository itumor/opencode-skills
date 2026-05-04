````markdown
# LDAPS SSL Certificate Request Guide for LDAP Backend Nodes

This guide covers how to generate and configure an SSL/TLS certificate request for LDAP backend nodes, with practical commands for Linux-based LDAP servers, especially OpenLDAP.

---

## 1. LDAP vs LDAPS

| Protocol |  Port | Encryption                | Typical Usage                                                    |
| -------- | ----: | ------------------------- | ---------------------------------------------------------------- |
| LDAP     | `389` | Plain by default          | Standard LDAP queries; can be upgraded to TLS using StartTLS     |
| LDAPS    | `636` | TLS from connection start | LDAP over SSL/TLS, commonly used for secure backend integrations |

There are two secure LDAP patterns:

```text
LDAP + StartTLS  → TCP 389, then upgrade to TLS
LDAPS            → TCP 636, TLS immediately
````

For backend services, LDAPS on `636` is often simpler because the client connects directly over TLS.

---

## 2. Certificate Requirements for LDAPS

Each LDAP node should have a certificate that matches the DNS name clients use to connect.

For example, if clients connect to:

```text
ldap01.example.com
ldap02.example.com
ldap.example.com
```

Then the certificate should include those names in the Subject Alternative Name field.

Modern TLS clients validate the `SAN` field, not only the legacy `CN`.

Recommended certificate properties:

```text
Key type: RSA 2048 or RSA 3072
Signature: SHA-256 or stronger
Certificate usage: Server Authentication
SAN: DNS names of LDAP node or LDAP VIP/load balancer
```

Example SANs:

```text
DNS:ldap01.example.com
DNS:ldap.example.com
IP:10.10.20.15
```

Use DNS SANs whenever possible. IP SANs are only needed if clients connect by IP address.

---

## 3. Prepare Working Directory

Run these commands on the LDAP node, or on a secure admin workstation.

```bash
sudo mkdir -p /etc/ldap/tls
sudo chmod 700 /etc/ldap/tls
cd /etc/ldap/tls
```

For OpenLDAP on RHEL-based systems, the TLS directory is often:

```bash
sudo mkdir -p /etc/openldap/certs
sudo chmod 700 /etc/openldap/certs
cd /etc/openldap/certs
```

---

# Option A: Generate Private Key and CSR with OpenSSL

Use this when you want a certificate signed by an internal enterprise CA or public CA.

## 4. Create an OpenSSL CSR Configuration File

Replace the values with your environment-specific details.

```bash
cat > ldap01-openssl.cnf <<'EOF'
[ req ]
default_bits       = 3072
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
C  = GB
ST = England
L  = London
O  = Example Corp
OU = Infrastructure
CN = ldap01.example.com

[ req_ext ]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[ alt_names ]
DNS.1 = ldap01.example.com
DNS.2 = ldap.example.com
IP.1  = 10.10.20.15
EOF
```

Important:

```text
CN should usually be the node FQDN.
SAN should contain all names clients use to reach this LDAP endpoint.
For LDAPS behind a load balancer, include the load balancer DNS name.
```

---

## 5. Generate the Private Key

```bash
openssl genrsa -out ldap01.key 3072
```

Secure the private key:

```bash
chmod 600 ldap01.key
```

Optional: generate an encrypted private key.

```bash
openssl genrsa -aes256 -out ldap01-encrypted.key 3072
```

However, encrypted private keys can complicate service startup because the LDAP service may require a passphrase during boot. For unattended backend services, a non-encrypted key with strict filesystem permissions is common.

---

## 6. Generate the CSR

```bash
openssl req \
  -new \
  -key ldap01.key \
  -out ldap01.csr \
  -config ldap01-openssl.cnf
```

Verify the CSR:

```bash
openssl req -in ldap01.csr -noout -text
```

Check specifically for:

```text
Subject
Subject Alternative Name
Key Usage
Extended Key Usage: TLS Web Server Authentication
```

---

# Option B: Generate a Self-Signed Certificate

Use this only for lab, development, emergency testing, or isolated internal environments where clients are explicitly configured to trust this certificate.

## 7. Generate Self-Signed Certificate

```bash
openssl req \
  -x509 \
  -nodes \
  -days 365 \
  -newkey rsa:3072 \
  -keyout ldap01.key \
  -out ldap01.crt \
  -config ldap01-openssl.cnf \
  -extensions req_ext
```

Secure the private key:

```bash
chmod 600 ldap01.key
```

Verify the certificate:

```bash
openssl x509 -in ldap01.crt -noout -text
```

Check SAN:

```bash
openssl x509 -in ldap01.crt -noout -text | grep -A2 "Subject Alternative Name"
```

---

# Option C: Generate a CSR with an Existing Private Key

Use this if your private key already exists.

```bash
openssl req \
  -new \
  -key /etc/ldap/tls/ldap01.key \
  -out /etc/ldap/tls/ldap01.csr \
  -config /etc/ldap/tls/ldap01-openssl.cnf
```

---

# Option D: Generate an ECDSA Key and CSR

RSA is widely compatible, but ECDSA is also common in modern environments.

```bash
openssl ecparam -name prime256v1 -genkey -noout -out ldap01-ecdsa.key
chmod 600 ldap01-ecdsa.key
```

Generate CSR:

```bash
openssl req \
  -new \
  -key ldap01-ecdsa.key \
  -out ldap01-ecdsa.csr \
  -config ldap01-openssl.cnf
```

Use ECDSA only if your LDAP clients and middleware support it.

---

## 8. Submit the CSR to a Certificate Authority

The CSR file to submit is:

```text
ldap01.csr
```

View it:

```bash
cat ldap01.csr
```

It will look like:

```text
-----BEGIN CERTIFICATE REQUEST-----
...
-----END CERTIFICATE REQUEST-----
```

Submit this CSR to one of the following:

```text
Internal enterprise CA
Microsoft Active Directory Certificate Services
HashiCorp Vault PKI
Public CA
Cloud private CA
```

When requesting the certificate, select a template or profile suitable for:

```text
Server Authentication
TLS server certificate
Key usage: digitalSignature, keyEncipherment
Extended key usage: serverAuth
```

The CA should return:

```text
Server certificate, for example ldap01.crt
Intermediate CA certificate, for example intermediate-ca.crt
Root CA certificate, for example root-ca.crt
```

Usually, OpenLDAP needs:

```text
Private key:        ldap01.key
Server certificate: ldap01.crt
CA chain:           ca-chain.crt
```

Create a CA chain file if your CA gives you separate root and intermediate certificates:

```bash
cat intermediate-ca.crt root-ca.crt > ca-chain.crt
```

In many enterprise environments, only the issuing intermediate is configured on the server, while clients trust the root via their OS trust store. For simplicity and compatibility, provide the full chain where supported.

---

# 9. File Placement and Permissions

## Debian/Ubuntu OpenLDAP Paths

```bash
sudo mkdir -p /etc/ldap/tls

sudo cp ldap01.key /etc/ldap/tls/
sudo cp ldap01.crt /etc/ldap/tls/
sudo cp ca-chain.crt /etc/ldap/tls/

sudo chown openldap:openldap /etc/ldap/tls/ldap01.key /etc/ldap/tls/ldap01.crt /etc/ldap/tls/ca-chain.crt
sudo chmod 600 /etc/ldap/tls/ldap01.key
sudo chmod 644 /etc/ldap/tls/ldap01.crt /etc/ldap/tls/ca-chain.crt
```

## RHEL/CentOS/Rocky/AlmaLinux OpenLDAP Paths

```bash
sudo mkdir -p /etc/openldap/certs

sudo cp ldap01.key /etc/openldap/certs/
sudo cp ldap01.crt /etc/openldap/certs/
sudo cp ca-chain.crt /etc/openldap/certs/

sudo chown ldap:ldap /etc/openldap/certs/ldap01.key /etc/openldap/certs/ldap01.crt /etc/openldap/certs/ca-chain.crt
sudo chmod 600 /etc/openldap/certs/ldap01.key
sudo chmod 644 /etc/openldap/certs/ldap01.crt /etc/openldap/certs/ca-chain.crt
```

---

# 10. Configure OpenLDAP for TLS/LDAPS

OpenLDAP can be configured in two common ways:

```text
cn=config dynamic configuration
slapd.conf legacy configuration
```

Most modern installations use `cn=config`.

---

## 10.1 Configure OpenLDAP Using cn=config

Create an LDIF file.

### Debian/Ubuntu Example

```bash
cat > tls-config.ldif <<'EOF'
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ldap/tls/ldap01.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ldap/tls/ldap01.key
-
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ldap/tls/ca-chain.crt
-
replace: olcTLSProtocolMin
olcTLSProtocolMin: 3.3
-
replace: olcTLSCipherSuite
olcTLSCipherSuite: HIGH:!aNULL:!MD5:!RC4:!3DES
EOF
```

Apply the config:

```bash
sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f tls-config.ldif
```

Restart OpenLDAP:

```bash
sudo systemctl restart slapd
```

### RHEL-Based Example

```bash
cat > tls-config.ldif <<'EOF'
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/openldap/certs/ldap01.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/openldap/certs/ldap01.key
-
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/openldap/certs/ca-chain.crt
-
replace: olcTLSProtocolMin
olcTLSProtocolMin: 3.3
-
replace: olcTLSCipherSuite
olcTLSCipherSuite: HIGH:!aNULL:!MD5:!RC4:!3DES
EOF
```

Apply:

```bash
sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f tls-config.ldif
```

Restart:

```bash
sudo systemctl restart slapd
```

`olcTLSProtocolMin: 3.3` means TLS 1.2 minimum in OpenLDAP's TLS protocol numbering.

---

## 10.2 Enable slapd to Listen on LDAPS Port 636

### Debian/Ubuntu

Edit:

```bash
sudo vi /etc/default/slapd
```

Set:

```bash
SLAPD_SERVICES="ldap:/// ldapi:/// ldaps:///"
```

Restart:

```bash
sudo systemctl restart slapd
```

Check listener:

```bash
sudo ss -lntp | grep -E ':389|:636'
```

Expected:

```text
LISTEN ... :389 ...
LISTEN ... :636 ...
```

### RHEL/CentOS/Rocky/AlmaLinux

Edit:

```bash
sudo vi /etc/sysconfig/slapd
```

Set:

```bash
SLAPD_URLS="ldapi:/// ldap:/// ldaps:///"
```

Restart:

```bash
sudo systemctl restart slapd
```

Check listener:

```bash
sudo ss -lntp | grep -E ':389|:636'
```

---

## 10.3 Legacy slapd.conf Configuration

If your OpenLDAP server uses `/etc/openldap/slapd.conf`, add or update:

```conf
TLSCertificateFile      /etc/openldap/certs/ldap01.crt
TLSCertificateKeyFile   /etc/openldap/certs/ldap01.key
TLSCACertificateFile    /etc/openldap/certs/ca-chain.crt
TLSProtocolMin          3.3
TLSCipherSuite          HIGH:!aNULL:!MD5:!RC4:!3DES
```

Restart:

```bash
sudo systemctl restart slapd
```

---

# 11. Verify LDAPS with OpenSSL

From a client host that can reach the LDAP server:

```bash
openssl s_client \
  -connect ldap01.example.com:636 \
  -servername ldap01.example.com \
  -showcerts
```

Expected indicators:

```text
SSL-Session:
Verify return code: 0 (ok)
```

If using a private CA that is not in the OS trust store, specify the CA file:

```bash
openssl s_client \
  -connect ldap01.example.com:636 \
  -servername ldap01.example.com \
  -CAfile ca-chain.crt \
  -showcerts
```

Check certificate dates:

```bash
echo | openssl s_client \
  -connect ldap01.example.com:636 \
  -servername ldap01.example.com 2>/dev/null \
  | openssl x509 -noout -dates -subject -issuer
```

Check SAN:

```bash
echo | openssl s_client \
  -connect ldap01.example.com:636 \
  -servername ldap01.example.com 2>/dev/null \
  | openssl x509 -noout -text \
  | grep -A2 "Subject Alternative Name"
```

---

# 12. Verify with ldapsearch

## LDAPS on Port 636

Anonymous query example:

```bash
ldapsearch \
  -H ldaps://ldap01.example.com:636 \
  -x \
  -b "dc=example,dc=com" \
  -s base
```

Authenticated query example:

```bash
ldapsearch \
  -H ldaps://ldap01.example.com:636 \
  -x \
  -D "cn=admin,dc=example,dc=com" \
  -W \
  -b "dc=example,dc=com" \
  "(objectClass=*)"
```

Using a custom CA file:

```bash
LDAPTLS_CACERT=/path/to/ca-chain.crt ldapsearch \
  -H ldaps://ldap01.example.com:636 \
  -x \
  -D "cn=admin,dc=example,dc=com" \
  -W \
  -b "dc=example,dc=com" \
  "(objectClass=*)"
```

---

## LDAP with StartTLS on Port 389

```bash
ldapsearch \
  -H ldap://ldap01.example.com:389 \
  -ZZ \
  -x \
  -D "cn=admin,dc=example,dc=com" \
  -W \
  -b "dc=example,dc=com" \
  "(objectClass=*)"
```

`-ZZ` requires StartTLS and fails if TLS cannot be negotiated.

---

# 13. Firewall and Network Requirements

Allow the required LDAP ports between backend clients and LDAP nodes.

## firewalld

```bash
sudo firewall-cmd --permanent --add-service=ldap
sudo firewall-cmd --permanent --add-service=ldaps
sudo firewall-cmd --reload
```

Or explicitly:

```bash
sudo firewall-cmd --permanent --add-port=389/tcp
sudo firewall-cmd --permanent --add-port=636/tcp
sudo firewall-cmd --reload
```

## ufw

```bash
sudo ufw allow 389/tcp
sudo ufw allow 636/tcp
sudo ufw reload
```

## iptables Example

```bash
sudo iptables -A INPUT -p tcp --dport 389 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 636 -j ACCEPT
```

For LDAPS-only backend integrations, allow:

```text
TCP 636 from application/backend subnets to LDAP nodes
```

For StartTLS integrations, allow:

```text
TCP 389 from application/backend subnets to LDAP nodes
```

Avoid exposing LDAP or LDAPS directly to the public internet unless there is a very specific, controlled reason.

---

# 14. TLS Settings and Hardening

Recommended baseline:

```text
Minimum TLS version: TLS 1.2
Preferred TLS version: TLS 1.3 where supported
Disable SSLv2, SSLv3, TLS 1.0, TLS 1.1
Use SAN-based certificate validation
Use SHA-256 or stronger signatures
Use RSA 2048 minimum; RSA 3072 preferred
Protect private keys with strict permissions
```

For OpenLDAP:

```ldif
olcTLSProtocolMin: 3.3
olcTLSCipherSuite: HIGH:!aNULL:!MD5:!RC4:!3DES
```

Client-side OpenLDAP TLS config is often in:

```text
/etc/ldap/ldap.conf
/etc/openldap/ldap.conf
```

Example client trust configuration:

```conf
TLS_CACERT /etc/ssl/certs/ca-chain.crt
TLS_REQCERT demand
```

Do not set this in production:

```conf
TLS_REQCERT allow
TLS_REQCERT never
```

Those settings weaken or bypass certificate validation.

---

# 15. Backend Deployment Considerations

## Use Stable DNS Names

Backend services should connect using a stable DNS name:

```text
ldaps://ldap.example.com:636
```

The certificate must include that name as a SAN:

```text
DNS:ldap.example.com
```

If clients connect directly to nodes, include node DNS names:

```text
DNS:ldap01.example.com
DNS:ldap02.example.com
```

---

## Load Balancer in Front of LDAP

If LDAPS terminates on the LDAP node:

```text
Client → Load Balancer TCP pass-through → LDAP node:636
```

Certificate should be valid for the DNS name used by the client, such as:

```text
ldap.example.com
```

If LDAPS terminates on the load balancer:

```text
Client → Load Balancer TLS termination → LDAP backend
```

Then the load balancer needs the certificate and private key. This is less common for LDAP because some deployments prefer end-to-end TLS to the directory nodes.

Recommended enterprise pattern:

```text
TCP pass-through on 636
TLS terminates on LDAP nodes
Health checks use TCP or LDAP-aware probes
```

---

## Kubernetes or Containerized LDAP

Mount certificates as secrets.

Example Kubernetes Secret:

```bash
kubectl create secret generic ldap-tls \
  --from-file=tls.crt=ldap01.crt \
  --from-file=tls.key=ldap01.key \
  --from-file=ca.crt=ca-chain.crt \
  -n directory
```

Mount into the LDAP container:

```yaml
volumes:
  - name: ldap-tls
    secret:
      secretName: ldap-tls
      defaultMode: 0400
```

Example volume mount:

```yaml
volumeMounts:
  - name: ldap-tls
    mountPath: /etc/ldap/tls
    readOnly: true
```

Ensure the LDAP process user can read the mounted private key.

---

## Certificate Rotation

For production, define a rotation process:

```text
Generate new key and CSR
Submit CSR to CA
Install new certificate and chain
Restart or reload LDAP service
Verify with openssl and ldapsearch
Update backend trust stores if CA changed
```

Check expiration:

```bash
echo | openssl s_client \
  -connect ldap01.example.com:636 \
  -servername ldap01.example.com 2>/dev/null \
  | openssl x509 -noout -enddate
```

---

# 16. Full End-to-End Example

This example assumes:

```text
LDAP node FQDN: ldap01.example.com
LDAP service DNS: ldap.example.com
LDAP node IP: 10.10.20.15
Base DN: dc=example,dc=com
OS path: /etc/ldap/tls
LDAP user: openldap
```

## Step 1: Create CSR Config

```bash
sudo mkdir -p /etc/ldap/tls
sudo chmod 700 /etc/ldap/tls
cd /etc/ldap/tls

sudo tee ldap01-openssl.cnf > /dev/null <<'EOF'
[ req ]
default_bits       = 3072
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
C  = GB
ST = England
L  = London
O  = Example Corp
OU = Infrastructure
CN = ldap01.example.com

[ req_ext ]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[ alt_names ]
DNS.1 = ldap01.example.com
DNS.2 = ldap.example.com
IP.1  = 10.10.20.15
EOF
```

## Step 2: Generate Key and CSR

```bash
sudo openssl genrsa -out ldap01.key 3072

sudo openssl req \
  -new \
  -key ldap01.key \
  -out ldap01.csr \
  -config ldap01-openssl.cnf

sudo chmod 600 ldap01.key
```

## Step 3: Verify CSR

```bash
sudo openssl req -in ldap01.csr -noout -text
```

## Step 4: Submit CSR to CA

Submit this file to your CA:

```text
/etc/ldap/tls/ldap01.csr
```

After approval, place the returned files here:

```text
/etc/ldap/tls/ldap01.crt
/etc/ldap/tls/intermediate-ca.crt
/etc/ldap/tls/root-ca.crt
```

Create chain:

```bash
sudo cat intermediate-ca.crt root-ca.crt | sudo tee ca-chain.crt > /dev/null
```

## Step 5: Set Permissions

```bash
sudo chown openldap:openldap /etc/ldap/tls/ldap01.key
sudo chown openldap:openldap /etc/ldap/tls/ldap01.crt
sudo chown openldap:openldap /etc/ldap/tls/ca-chain.crt

sudo chmod 600 /etc/ldap/tls/ldap01.key
sudo chmod 644 /etc/ldap/tls/ldap01.crt
sudo chmod 644 /etc/ldap/tls/ca-chain.crt
```

## Step 6: Configure OpenLDAP TLS

```bash
sudo tee tls-config.ldif > /dev/null <<'EOF'
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ldap/tls/ldap01.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ldap/tls/ldap01.key
-
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ldap/tls/ca-chain.crt
-
replace: olcTLSProtocolMin
olcTLSProtocolMin: 3.3
-
replace: olcTLSCipherSuite
olcTLSCipherSuite: HIGH:!aNULL:!MD5:!RC4:!3DES
EOF

sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f tls-config.ldif
```

## Step 7: Enable LDAPS Listener

```bash
sudo sed -i 's|^SLAPD_SERVICES=.*|SLAPD_SERVICES="ldap:/// ldapi:/// ldaps:///"|' /etc/default/slapd
sudo systemctl restart slapd
```

For RHEL-based systems:

```bash
sudo sed -i 's|^SLAPD_URLS=.*|SLAPD_URLS="ldapi:/// ldap:/// ldaps:///"|' /etc/sysconfig/slapd
sudo systemctl restart slapd
```

## Step 8: Confirm Port 636 Is Listening

```bash
sudo ss -lntp | grep ':636'
```

## Step 9: Verify TLS

```bash
openssl s_client \
  -connect ldap01.example.com:636 \
  -servername ldap01.example.com \
  -CAfile /etc/ldap/tls/ca-chain.crt \
  -showcerts
```

Expected:

```text
Verify return code: 0 (ok)
```

## Step 10: Verify LDAP Query over LDAPS

```bash
LDAPTLS_CACERT=/etc/ldap/tls/ca-chain.crt ldapsearch \
  -H ldaps://ldap01.example.com:636 \
  -x \
  -b "dc=example,dc=com" \
  -s base
```

---

# 17. Troubleshooting Checklist

## Certificate Name Mismatch

Symptom:

```text
hostname mismatch
certificate verify failed
```

Fix:

```text
Ensure the LDAP hostname used by clients exists in certificate SAN.
```

Check SAN:

```bash
openssl x509 -in ldap01.crt -noout -text | grep -A2 "Subject Alternative Name"
```

---

## CA Not Trusted

Symptom:

```text
unable to get local issuer certificate
self-signed certificate in certificate chain
```

Fix:

```text
Install the CA certificate in the client trust store or specify LDAPTLS_CACERT.
```

Example:

```bash
LDAPTLS_CACERT=/etc/ldap/tls/ca-chain.crt ldapsearch \
  -H ldaps://ldap01.example.com:636 \
  -x \
  -b "dc=example,dc=com" \
  -s base
```

---

## slapd Cannot Read Private Key

Symptom:

```text
Permission denied
TLS init def ctx failed
```

Fix:

```bash
sudo chown openldap:openldap /etc/ldap/tls/ldap01.key
sudo chmod 600 /etc/ldap/tls/ldap01.key
sudo systemctl restart slapd
```

For RHEL-based systems:

```bash
sudo chown ldap:ldap /etc/openldap/certs/ldap01.key
sudo chmod 600 /etc/openldap/certs/ldap01.key
sudo systemctl restart slapd
```

---

## Port 636 Not Listening

Check slapd service URLs:

```bash
sudo systemctl cat slapd
sudo ss -lntp | grep slapd
```

Debian/Ubuntu:

```bash
grep SLAPD_SERVICES /etc/default/slapd
```

RHEL-based:

```bash
grep SLAPD_URLS /etc/sysconfig/slapd
```

---

# 18. Minimal Command Set

For a quick production CSR request:

```bash
sudo mkdir -p /etc/ldap/tls
cd /etc/ldap/tls

sudo tee ldap01-openssl.cnf > /dev/null <<'EOF'
[ req ]
default_bits       = 3072
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
C  = GB
ST = England
L  = London
O  = Example Corp
OU = Infrastructure
CN = ldap01.example.com

[ req_ext ]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[ alt_names ]
DNS.1 = ldap01.example.com
DNS.2 = ldap.example.com
EOF

sudo openssl genrsa -out ldap01.key 3072

sudo openssl req \
  -new \
  -key ldap01.key \
  -out ldap01.csr \
  -config ldap01-openssl.cnf

sudo chmod 600 ldap01.key

sudo openssl req -in ldap01.csr -noout -text
```

Submit this file to the CA:

```text
/etc/ldap/tls/ldap01.csr
```

After the CA returns the certificate, configure OpenLDAP with:

```text
olcTLSCertificateFile
olcTLSCertificateKeyFile
olcTLSCACertificateFile
```

Then verify using:

```bash
openssl s_client -connect ldap01.example.com:636 -servername ldap01.example.com -showcerts
```

and:

```bash
ldapsearch -H ldaps://ldap01.example.com:636 -x -b "dc=example,dc=com" -s base
```

---

## References

* OpenLDAP Administrator's Guide — TLS configuration: [https://www.openldap.org/doc/admin24/tls.html](https://www.openldap.org/doc/admin24/tls.html)
* OpenLDAP `slapd-config` manual — `olcTLS*` options: [https://www.openldap.org/software/man.cgi?query=slapd-config](https://www.openldap.org/software/man.cgi?query=slapd-config)
* OpenLDAP `ldapsearch` manual: [https://www.openldap.org/software/man.cgi?query=ldapsearch](https://www.openldap.org/software/man.cgi?query=ldapsearch)
* OpenSSL `req` manual: [https://docs.openssl.org/master/man1/openssl-req/](https://docs.openssl.org/master/man1/openssl-req/)
* OpenSSL `s_client` manual: [https://docs.openssl.org/master/man1/openssl-s_client/](https://docs.openssl.org/master/man1/openssl-s_client/)
* IANA service names and port numbers — LDAP `389`, LDAPS `636`: [https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml](https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml)

```
```

