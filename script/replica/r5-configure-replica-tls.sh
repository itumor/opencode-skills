#!/usr/bin/env bash
# r5-configure-replica-tls.sh
#
# Configures TLS on the replica node.
#
# Two modes:
#   1. COPY_FROM_MASTER=1 (default):
#      Copies CA cert + server cert + key from master over SSH.
#      Signs a new server cert for the replica using the master CA.
#      Requires SSH access to master (SSH_KEY + MASTER_IP).
#
#   2. COPY_FROM_MASTER=0:
#      Generates a self-signed CA + server cert locally (standalone).
#      Use when master CA is not available.
#
# Required env:
#   MASTER_IP        - master hostname/IP (required when COPY_FROM_MASTER=1)
#   SSH_KEY          - path to SSH private key for master access
#   SSH_USER         - SSH user on master (default: ec2-user)
#   ADMIN_PW         - admin password (for ldapmodify)
#
# Optional env:
#   COPY_FROM_MASTER - 1 (default) or 0
#   TLS_DIR          - where to store certs (default: /opt/symas/etc/openldap/tls)
#
# Usage:
#   sudo MASTER_IP=10.0.0.1 SSH_KEY=~/.ssh/key.pem bash r5-configure-replica-tls.sh
set -euo pipefail

log()   { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  [[ -f "$prof" ]] && source "$prof" 2>/dev/null || true
  [[ ":${PATH}:" == *":/opt/symas/bin:"* ]]  || export PATH="/opt/symas/bin:${PATH}"
  [[ ":${PATH}:" == *":/opt/symas/sbin:"* ]] || export PATH="/opt/symas/sbin:${PATH}"
  [[ -n "${LDAPCONF:-}" ]] || export LDAPCONF="/opt/symas/etc/openldap/ldap.conf"
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }

ensure_symas_env
require_cmd openssl
require_cmd ldapmodify

MASTER_IP="${MASTER_IP:-}"
SSH_KEY="${SSH_KEY:-}"
SSH_USER="${SSH_USER:-ec2-user}"
COPY_FROM_MASTER="${COPY_FROM_MASTER:-1}"
STAGED_CA_CERT="${STAGED_CA_CERT:-}"   # pre-staged CA cert path (skips SSH to master)
STAGED_CA_KEY="${STAGED_CA_KEY:-}"    # pre-staged CA key path (skips SSH to master)
TLS_DIR="${TLS_DIR:-/opt/symas/etc/openldap/tls}"
CA_CERT="${TLS_DIR}/ca.crt"
CA_KEY="${TLS_DIR}/ca.key"
SERVER_CERT="${TLS_DIR}/ldap.crt"
SERVER_KEY="${TLS_DIR}/ldap.key"
SERVER_CSR="${TLS_DIR}/ldap.csr"
SAN_CFG="${TLS_DIR}/san.cnf"
SLAPD_DEFAULTS="/etc/default/symas-openldap"
CA_DAYS="${CA_DAYS:-3650}"
SERVER_DAYS="${SERVER_DAYS:-825}"

mkdir -p "$TLS_DIR"

# ---------------------------------------------------------------------------
# Mode 1: copy CA from master (SSH or pre-staged files)
# ---------------------------------------------------------------------------
if [[ "$COPY_FROM_MASTER" == "1" ]]; then
  # Sub-mode A: pre-staged CA files provided (avoids SSH between hosts)
  if [[ -n "$STAGED_CA_CERT" && -n "$STAGED_CA_KEY" ]]; then
    log "Using pre-staged CA cert: ${STAGED_CA_CERT}"
    cp "$STAGED_CA_CERT" "$CA_CERT"
    cp "$STAGED_CA_KEY"  "$CA_KEY"
    chmod 600 "$CA_KEY"
    log "CA cert+key copied from pre-staged files"
  else
    # Sub-mode B: SSH directly to master
    [[ -n "$MASTER_IP" ]] || fatal "MASTER_IP required when COPY_FROM_MASTER=1 and STAGED_CA_CERT not set"
    [[ -n "$SSH_KEY"   ]] || fatal "SSH_KEY required when COPY_FROM_MASTER=1 and STAGED_CA_CERT not set"

    log "Copying CA cert+key from master ${MASTER_IP}"
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
      "${SSH_USER}@${MASTER_IP}:/opt/symas/etc/openldap/tls/ca.crt" "$CA_CERT"
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
      "${SSH_USER}@${MASTER_IP}:/opt/symas/etc/openldap/tls/ca.key" "$CA_KEY"
    log "CA cert+key copied from master"
  fi

  # Generate new server key + CSR + cert signed by master CA
  host_fqdn="$(hostname -f 2>/dev/null || hostname)"
  host_short="$(hostname -s 2>/dev/null || hostname)"

  cat > "$SAN_CFG" <<EOF
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
C=US
O=Lab-Org
OU=LDAP
CN=${host_fqdn}

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${host_fqdn}
DNS.2 = ${host_short}
DNS.3 = localhost
IP.1  = 127.0.0.1
EOF

  log "Generating replica server key and certificate (signed by master CA)"
  openssl genrsa -out "$SERVER_KEY" 4096
  openssl req -new -key "$SERVER_KEY" -out "$SERVER_CSR" -config "$SAN_CFG"
  openssl x509 -req -in "$SERVER_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$SERVER_CERT" -days "$SERVER_DAYS" -sha256 -extensions req_ext -extfile "$SAN_CFG"
  rm -f "$SERVER_CSR"
  log "Replica server cert generated and signed by master CA"

# ---------------------------------------------------------------------------
# Mode 0: standalone self-signed CA + cert (no master access)
# ---------------------------------------------------------------------------
else
  log "Generating standalone CA and server certificate (COPY_FROM_MASTER=0)"

  openssl genrsa -out "$CA_KEY" 4096
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$CA_DAYS" \
    -subj "/C=US/O=Lab-CA/OU=LDAP/CN=Lab LDAP CA (replica)" \
    -out "$CA_CERT"

  host_fqdn="$(hostname -f 2>/dev/null || hostname)"
  host_short="$(hostname -s 2>/dev/null || hostname)"

  cat > "$SAN_CFG" <<EOF
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
C=US
O=Lab-Org
OU=LDAP
CN=${host_fqdn}

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${host_fqdn}
DNS.2 = ${host_short}
DNS.3 = localhost
IP.1  = 127.0.0.1
EOF

  openssl genrsa -out "$SERVER_KEY" 4096
  openssl req -new -key "$SERVER_KEY" -out "$SERVER_CSR" -config "$SAN_CFG"
  openssl x509 -req -in "$SERVER_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$SERVER_CERT" -days "$SERVER_DAYS" -sha256 -extensions req_ext -extfile "$SAN_CFG"
  rm -f "$SERVER_CSR"
  log "Standalone CA and server cert generated"
fi

# Fix permissions
chmod 700 "$TLS_DIR"
chmod 600 "$CA_KEY" "$SERVER_KEY"
chmod 644 "$CA_CERT" "$SERVER_CERT"
if id -u symas-openldap >/dev/null 2>&1; then
  chown -R symas-openldap:symas-openldap "$TLS_DIR"
fi

# Apply TLS config to cn=config via ldapi
LDIF="$(mktemp /tmp/replica-tls.XXXXXX.ldif)"
cat > "$LDIF" <<EOF
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: ${SERVER_CERT}
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: ${SERVER_KEY}
-
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: ${CA_CERT}
-
replace: olcTLSProtocolMin
olcTLSProtocolMin: 3.3
-
replace: olcTLSCipherSuite
olcTLSCipherSuite: HIGH:!aNULL:!eNULL:!MD5:!RC4:!3DES:!DES:!NULL
EOF

if ldapmodify -Y EXTERNAL -H ldapi:/// -f "$LDIF"; then
  log "TLS applied to cn=config via ldapmodify"
else
  warn "ldapmodify failed; TLS certs written to disk but cn=config not updated. Restart slapd manually."
fi
rm -f "$LDIF"

# Update SLAPD_URLS
if [[ -f "$SLAPD_DEFAULTS" ]]; then
  if grep -q '^SLAPD_URLS=' "$SLAPD_DEFAULTS"; then
    sed -i 's|^SLAPD_URLS=.*|SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"|' "$SLAPD_DEFAULTS"
  else
    echo 'SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"' >> "$SLAPD_DEFAULTS"
  fi
  log "SLAPD_URLS updated in ${SLAPD_DEFAULTS}"
fi

systemctl daemon-reload
systemctl restart symas-openldap-servers 2>/dev/null || systemctl restart slapd 2>/dev/null || true

log "TLS configuration complete on replica"
