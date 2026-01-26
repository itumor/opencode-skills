#!/usr/bin/env bash
set -euo pipefail

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[FATAL] Run as root" >&2
    exit 1
  fi
}

ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  if [[ -f "$prof" ]]; then
    # shellcheck source=/etc/profile.d/symas_env.sh
    source "$prof"
  fi

  if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
    export PATH="/opt/symas/bin:${PATH}"
  fi
  if [[ ":${PATH}:" != *":/opt/symas/sbin:"* ]]; then
    export PATH="/opt/symas/sbin:${PATH}"
  fi

  if [[ -z "${LDAPCONF:-}" ]]; then
    export LDAPCONF="/opt/symas/etc/openldap/ldap.conf"
  fi
}

require_cmd() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[FATAL] $bin not found in PATH" >&2
    exit 1
  fi
}

update_defaults_urls() {
  local defaults_file="$1"
  if [[ -f "$defaults_file" ]]; then
    if grep -q '^SLAPD_URLS=' "$defaults_file"; then
      sed -i 's|^SLAPD_URLS=.*|SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"|' "$defaults_file"
    else
      echo 'SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"' >>"$defaults_file"
    fi
  else
    echo "[WARN] $defaults_file not found; skipping SLAPD_URLS update"
  fi
}

write_san_config() {
  local file="$1"
  local host_fqdn="$2"
  local host_short="$3"
  local extra_dns="${4:-}"
  local extra_ips="${5:-}"

  {
    echo "[ req ]"
    echo "default_bits       = 4096"
    echo "prompt             = no"
    echo "default_md         = sha256"
    echo "distinguished_name = dn"
    echo "req_extensions     = req_ext"
    echo
    echo "[ dn ]"
    echo "C=US"
    echo "O=Lab-Org"
    echo "OU=LDAP"
    echo "CN=${host_fqdn}"
    echo
    echo "[ req_ext ]"
    echo "subjectAltName = @alt_names"
    echo
    echo "[ alt_names ]"
    echo "DNS.1 = ${host_fqdn}"
    echo "DNS.2 = ${host_short}"
    echo "DNS.3 = localhost"
    echo "IP.1  = 127.0.0.1"

    local idx=4
    if [[ -n "$extra_dns" ]]; then
      while IFS= read -r dns; do
        [[ -n "$dns" ]] || continue
        echo "DNS.${idx} = ${dns}"
        idx=$((idx + 1))
      done < <(echo "$extra_dns" | tr ',' '\n')
    fi

    local ipidx=2
    if [[ -n "$extra_ips" ]]; then
      while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        echo "IP.${ipidx}  = ${ip}"
        ipidx=$((ipidx + 1))
      done < <(echo "$extra_ips" | tr ',' '\n')
    fi
  } >"$file"
}

apply_online_config() {
  local cert="$1"
  local key="$2"
  local ca_cert="$3"
  local protocol_min="$4"
  local cipher_suite="$5"
  local verify_client="$6"

  local ldif
  ldif="$(mktemp /tmp/configure-tls.XXXXXX.ldif)"

  {
    echo "dn: cn=config"
    echo "changetype: modify"
    echo "replace: olcTLSCertificateFile"
    echo "olcTLSCertificateFile: ${cert}"
    echo "-"
    echo "replace: olcTLSCertificateKeyFile"
    echo "olcTLSCertificateKeyFile: ${key}"
    echo "-"
    echo "replace: olcTLSCACertificateFile"
    echo "olcTLSCACertificateFile: ${ca_cert}"

    if [[ -n "$protocol_min" ]]; then
      echo "-"
      echo "replace: olcTLSProtocolMin"
      echo "olcTLSProtocolMin: ${protocol_min}"
    fi

    if [[ -n "$cipher_suite" ]]; then
      echo "-"
      echo "replace: olcTLSCipherSuite"
      echo "olcTLSCipherSuite: ${cipher_suite}"
    fi

    if [[ -n "$verify_client" ]]; then
      echo "-"
      echo "replace: olcTLSVerifyClient"
      echo "olcTLSVerifyClient: ${verify_client}"
    fi
  } >"$ldif"

  if ldapmodify -Y EXTERNAL -H ldapi:/// -f "$ldif"; then
    rm -f "$ldif"
    return 0
  fi

  rm -f "$ldif"
  return 1
}

apply_offline_config() {
  local cert="$1"
  local key="$2"
  local ca_cert="$3"
  local protocol_min="$4"
  local cipher_suite="$5"
  local verify_client="$6"
  local config_ldif="$7"

  if [[ ! -f "$config_ldif" ]]; then
    echo "[FATAL] cn=config LDIF not found at $config_ldif" >&2
    exit 1
  fi

  systemctl stop symas-openldap-servers >/dev/null 2>&1 || true
  systemctl stop slapd >/dev/null 2>&1 || true

  update_ldif_attr "$config_ldif" "olcTLSCertificateFile" "$cert"
  update_ldif_attr "$config_ldif" "olcTLSCertificateKeyFile" "$key"
  update_ldif_attr "$config_ldif" "olcTLSCACertificateFile" "$ca_cert"

  if [[ -n "$protocol_min" ]]; then
    update_ldif_attr "$config_ldif" "olcTLSProtocolMin" "$protocol_min"
  fi

  if [[ -n "$cipher_suite" ]]; then
    update_ldif_attr "$config_ldif" "olcTLSCipherSuite" "$cipher_suite"
  fi

  if [[ -n "$verify_client" ]]; then
    update_ldif_attr "$config_ldif" "olcTLSVerifyClient" "$verify_client"
  fi
}

update_ldif_attr() {
  local file="$1"
  local attr="$2"
  local value="$3"

  if grep -q "^${attr}:" "$file"; then
    sed -i "s|^${attr}:.*|${attr}: ${value}|" "$file"
  else
    sed -i "/^dn: cn=config$/a ${attr}: ${value}" "$file"
  fi
}

update_ldap_conf() {
  local ldap_conf="$1"
  local ca_cert="$2"
  local reqcert="$3"

  if [[ ! -f "$ldap_conf" ]]; then
    echo "[WARN] $ldap_conf not found; skipping LDAP client config"
    return 0
  fi

  if grep -q '^TLS_CACERT' "$ldap_conf"; then
    sed -i "s|^TLS_CACERT.*|TLS_CACERT ${ca_cert}|" "$ldap_conf"
  else
    echo "TLS_CACERT ${ca_cert}" >>"$ldap_conf"
  fi

  if [[ -n "$reqcert" ]]; then
    if grep -q '^TLS_REQCERT' "$ldap_conf"; then
      sed -i "s|^TLS_REQCERT.*|TLS_REQCERT ${reqcert}|" "$ldap_conf"
    else
      echo "TLS_REQCERT ${reqcert}" >>"$ldap_conf"
    fi
  fi
}

fix_permissions() {
  local dir="$1"
  local ca_key="$2"
  local srv_key="$3"

  chmod 700 "$dir"
  [[ -f "$ca_key" ]] && chmod 600 "$ca_key"
  [[ -f "$srv_key" ]] && chmod 600 "$srv_key"

  if id -u symas-openldap >/dev/null 2>&1; then
    chown symas-openldap:symas-openldap "$dir"/* 2>/dev/null || true
  elif id -u ldap >/dev/null 2>&1; then
    chown ldap:ldap "$dir"/* 2>/dev/null || true
  fi
}

require_root
ensure_symas_env
require_cmd openssl
require_cmd ldapmodify

TLS_DIR="${TLS_DIR:-/opt/symas/etc/openldap/tls}"
CA_CERT="${CA_CERT:-${TLS_DIR}/ca.crt}"
CA_KEY="${CA_KEY:-${TLS_DIR}/ca.key}"
SERVER_CERT="${SERVER_CERT:-${TLS_DIR}/ldap.crt}"
SERVER_KEY="${SERVER_KEY:-${TLS_DIR}/ldap.key}"
SERVER_CSR="${SERVER_CSR:-${TLS_DIR}/ldap.csr}"
SAN_CONFIG="${SAN_CONFIG:-${TLS_DIR}/san.cnf}"
CA_DAYS="${CA_DAYS:-3650}"
SERVER_DAYS="${SERVER_DAYS:-825}"
TLS_PROTOCOL_MIN="${TLS_PROTOCOL_MIN:-3.3}"
TLS_CIPHER_SUITE="${TLS_CIPHER_SUITE:-}"
TLS_VERIFY_CLIENT="${TLS_VERIFY_CLIENT:-}"
TLS_REQCERT="${TLS_REQCERT:-}"
LDAP_CONF="${LDAP_CONF:-/opt/symas/etc/openldap/ldap.conf}"
SLAPD_DEFAULTS="${SLAPD_DEFAULTS:-/etc/default/symas-openldap}"
CONFIG_LDIF="${CONFIG_LDIF:-/opt/symas/etc/openldap/slapd.d/cn=config.ldif}"
EXTRA_DNS="${TLS_DNS_NAMES:-}"
EXTRA_IPS="${TLS_IPS:-}"
FORCE_REGEN_CA="${FORCE_REGEN_CA:-0}"
FORCE_REGEN_SERVER="${FORCE_REGEN_SERVER:-0}"

mkdir -p "$TLS_DIR"

need_server_cert=0
if [[ "$FORCE_REGEN_SERVER" -eq 1 || ! -f "$SERVER_CERT" ]]; then
  need_server_cert=1
fi

if [[ -f "$SERVER_CERT" && ! -f "$SERVER_KEY" && "$FORCE_REGEN_SERVER" -ne 1 ]]; then
  echo "[FATAL] Server cert exists but server key is missing. Provide SERVER_KEY or set FORCE_REGEN_SERVER=1." >&2
  exit 1
fi

if [[ "$FORCE_REGEN_CA" -eq 1 ]]; then
  echo "[INFO] Forcing CA regeneration"
  openssl genrsa -out "$CA_KEY" 4096
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$CA_DAYS" \
    -subj "/C=US/O=Lab-CA/OU=LDAP/CN=Lab LDAP CA" \
    -out "$CA_CERT"
elif [[ ! -f "$CA_CERT" && ! -f "$CA_KEY" ]]; then
  echo "[INFO] Generating CA certificate"
  openssl genrsa -out "$CA_KEY" 4096
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$CA_DAYS" \
    -subj "/C=US/O=Lab-CA/OU=LDAP/CN=Lab LDAP CA" \
    -out "$CA_CERT"
elif [[ ! -f "$CA_CERT" && -f "$CA_KEY" ]]; then
  echo "[INFO] Generating CA certificate from existing key"
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$CA_DAYS" \
    -subj "/C=US/O=Lab-CA/OU=LDAP/CN=Lab LDAP CA" \
    -out "$CA_CERT"
elif [[ -f "$CA_CERT" && ! -f "$CA_KEY" && "$need_server_cert" -eq 1 ]]; then
  echo "[FATAL] CA cert exists but CA key is missing; cannot sign a new server cert." >&2
  echo "Provide CA_KEY or set FORCE_REGEN_CA=1 to replace the CA." >&2
  exit 1
fi

if [[ "$FORCE_REGEN_SERVER" -eq 1 || ! -f "$SERVER_KEY" ]]; then
  echo "[INFO] Generating server key"
  openssl genrsa -out "$SERVER_KEY" 4096
fi

if [[ "$FORCE_REGEN_SERVER" -eq 1 || ! -f "$SERVER_CERT" ]]; then
  if [[ ! -f "$CA_CERT" || ! -f "$CA_KEY" ]]; then
    echo "[FATAL] CA cert/key required to sign server certificate" >&2
    exit 1
  fi

  host_fqdn="$(hostname -f 2>/dev/null || hostname)"
  host_short="$(hostname -s 2>/dev/null || hostname)"
  write_san_config "$SAN_CONFIG" "$host_fqdn" "$host_short" "$EXTRA_DNS" "$EXTRA_IPS"

  echo "[INFO] Generating server certificate"
  openssl req -new -key "$SERVER_KEY" -out "$SERVER_CSR" -config "$SAN_CONFIG"
  openssl x509 -req -in "$SERVER_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$SERVER_CERT" -days "$SERVER_DAYS" -sha256 -extensions req_ext -extfile "$SAN_CONFIG"
fi

fix_permissions "$TLS_DIR" "$CA_KEY" "$SERVER_KEY"
update_defaults_urls "$SLAPD_DEFAULTS"
update_ldap_conf "$LDAP_CONF" "$CA_CERT" "$TLS_REQCERT"

if apply_online_config "$SERVER_CERT" "$SERVER_KEY" "$CA_CERT" "$TLS_PROTOCOL_MIN" "$TLS_CIPHER_SUITE" "$TLS_VERIFY_CLIENT"; then
  echo "[OK] TLS configured via ldapmodify"
else
  echo "[WARN] ldapmodify failed; falling back to offline update"
  apply_offline_config "$SERVER_CERT" "$SERVER_KEY" "$CA_CERT" "$TLS_PROTOCOL_MIN" "$TLS_CIPHER_SUITE" "$TLS_VERIFY_CLIENT" "$CONFIG_LDIF"
fi

systemctl daemon-reload
systemctl restart symas-openldap-servers >/dev/null 2>&1 || systemctl restart slapd

echo "[SUCCESS] SSL/TLS configuration completed"
