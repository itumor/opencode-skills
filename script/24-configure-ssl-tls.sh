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

detect_ldapi_uri() {
  # Prefer the default ldapi:/// if it works; otherwise locate an actual socket path.
  if ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
    echo "ldapi:///"
    return 0
  fi

  local sock=""
  local candidates=(
    "/var/symas/run/ldapi"
    "/var/run/slapd/ldapi"
    "/run/slapd/ldapi"
    "/run/openldap/ldapi"
    "/var/run/openldap/ldapi"
    "/var/run/ldap/ldapi"
    "/opt/symas/var/run/ldapi"
  )
  for s in "${candidates[@]}"; do
    if [[ -S "$s" ]]; then
      sock="$s"
      break
    fi
  done

  if [[ -z "$sock" ]] && command -v ss >/dev/null 2>&1; then
    sock="$(ss -xl 2>/dev/null | awk '/ldapi|slapd/ && $NF ~ /^\\// {print $NF; exit}')"
  fi

  if [[ -z "$sock" ]] && command -v find >/dev/null 2>&1; then
    sock="$(find /run /var/run /var/symas/run -maxdepth 3 -type s -name 'ldapi*' 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -z "$sock" ]]; then
    return 1
  fi

  local enc
  enc="$(printf '%s' "$sock" | sed 's,/,%%2F,g')"
  echo "ldapi://${enc}"
}

update_defaults_urls() {
  local defaults_file="$1"
  local listener_mode="$2"
  local urls ldap_urls ldaps_urls ldapi_urls
  local serverid_url=""
  local p="${LDAPS_PORT:-636}"

  to_ldaps_url() {
    local ldap_url="$1"

    if [[ "$ldap_url" == "ldap:///" ]]; then
      echo "ldaps:///"
      return 0
    fi

    local rest hostport host path host_only
    rest="${ldap_url#ldap://}"
    hostport="${rest%%/*}"
    path=""
    if [[ "$rest" == */* ]]; then
      path="/${rest#*/}"
    fi
    host_only="${hostport%%:*}"
    echo "ldaps://${host_only}:${p}${path}"
  }

  case "$listener_mode" in
    ldaps_only)
      # NOTE: Many OpenLDAP deployments set olcServerID with an explicit ldap://IP:389 URL.
      # If we remove ldap:// from SLAPD_URLS, slapd will fail to start with:
      # "read_config: no serverID / URL match found. Check slapd -h arguments."
      urls='ldaps:/// ldapi:///'
      ;;
    starttls_and_ldaps)
      urls='ldap:/// ldaps:/// ldapi:///'
      ;;
    *)
      echo "[FATAL] Unknown LDAP_LISTENER_MODE=${listener_mode}. Use ldaps_only or starttls_and_ldaps." >&2
      exit 1
      ;;
  esac

  # Try to discover an explicit ldap:// URL from cn=config so we can keep SLAPD_URLS compatible
  # with olcServerID mappings.
  if [[ -f "${CONFIG_LDIF:-}" ]]; then
    serverid_url="$(awk '/^olcServerID:/ {for (i=1;i<=NF;i++) if ($i ~ /^ldap:\/\//) {print $i; exit}}' "${CONFIG_LDIF}" 2>/dev/null || true)"
  fi

  if [[ ! -f "$defaults_file" ]]; then
    mkdir -p "$(dirname "$defaults_file")"
    touch "$defaults_file"
  fi

  # Preserve any existing ldapi:// socket URL (it may be an encoded-path ldapi://%2F... form).
  ldapi_urls="$(awk -F= '/^SLAPD_URLS=/ {gsub(/"/,"",$2); print $2}' "$defaults_file" 2>/dev/null | tr ' ' '\n' | awk '/^ldapi:\/\// {print}' | xargs || true)"

  # Preserve explicit ldap:// URL(s) if present; otherwise fall back to olcServerID URL if available.
  ldap_urls="$(awk -F= '/^SLAPD_URLS=/ {gsub(/"/,"",$2); print $2}' "$defaults_file" 2>/dev/null | tr ' ' '\n' | awk '/^ldap:\/\// {print}' | xargs || true)"
  if [[ -z "$ldap_urls" && -n "$serverid_url" ]]; then
    ldap_urls="$serverid_url"
  fi
  if [[ -z "$ldap_urls" ]]; then
    ldap_urls="ldap:///"
  fi

  # Derive LDAPS URL(s) from the LDAP URL(s).
  ldaps_urls=""
  for u in $ldap_urls; do
    if [[ "$u" == "ldap:///" ]]; then
      ldaps_urls="${ldaps_urls} ldaps:///"
    else
      # Keep host the same as the ldap:// URL and swap scheme+port.
      ldaps_urls="${ldaps_urls} $(to_ldaps_url "$u")"
    fi
  done
  ldaps_urls="$(echo "$ldaps_urls" | xargs)"

  # If serverID is explicitly ldap://... and caller requested ldaps_only, refuse because it bricks slapd.
  if [[ "$listener_mode" == "ldaps_only" && -n "$serverid_url" ]]; then
    echo "[FATAL] LDAP_LISTENER_MODE=ldaps_only is incompatible with olcServerID URL ${serverid_url}. Use starttls_and_ldaps." >&2
    exit 1
  fi

  if [[ "$listener_mode" == "ldaps_only" ]]; then
    urls="$(echo "${ldaps_urls} ${ldapi_urls:-ldapi:///}" | xargs)"
  else
    urls="$(echo "${ldap_urls} ${ldaps_urls} ${ldapi_urls:-ldapi:///}" | xargs)"
  fi

  if grep -q '^SLAPD_URLS=' "$defaults_file"; then
    sed -i "s|^SLAPD_URLS=.*|SLAPD_URLS=\"${urls}\"|" "$defaults_file"
  else
    echo "SLAPD_URLS=\"${urls}\"" >>"$defaults_file"
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
  local ldapi_uri="$7"

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

  if ldapmodify -Y EXTERNAL -H "$ldapi_uri" -f "$ldif"; then
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
require_cmd ldapwhoami

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
LDAP_LISTENER_MODE="${LDAP_LISTENER_MODE:-starttls_and_ldaps}"
TLS_CERT_MODE="${TLS_CERT_MODE:-external_or_self_signed}"
TLS_CA_CERT_PEM="${TLS_CA_CERT_PEM:-}"
TLS_CERT_PEM="${TLS_CERT_PEM:-}"
TLS_KEY_PEM="${TLS_KEY_PEM:-}"
EXTRA_DNS="${TLS_DNS_NAMES:-}"
EXTRA_IPS="${TLS_IPS:-}"
FORCE_REGEN_CA="${FORCE_REGEN_CA:-0}"
FORCE_REGEN_SERVER="${FORCE_REGEN_SERVER:-0}"

mkdir -p "$TLS_DIR"

case "$TLS_CERT_MODE" in
  external_or_self_signed|self_signed|external_required) ;;
  *)
    echo "[FATAL] TLS_CERT_MODE must be external_or_self_signed, self_signed, or external_required" >&2
    exit 1
    ;;
esac

have_external_bundle=0
if [[ -n "$TLS_CA_CERT_PEM" || -n "$TLS_CERT_PEM" || -n "$TLS_KEY_PEM" ]]; then
  if [[ -z "$TLS_CA_CERT_PEM" || -z "$TLS_CERT_PEM" || -z "$TLS_KEY_PEM" ]]; then
    echo "[FATAL] External TLS PEM input is partial; provide TLS_CA_CERT_PEM, TLS_CERT_PEM, and TLS_KEY_PEM together." >&2
    exit 1
  fi
  have_external_bundle=1
fi

if [[ "$TLS_CERT_MODE" == "external_required" && "$have_external_bundle" -ne 1 ]]; then
  echo "[FATAL] TLS_CERT_MODE=external_required but external PEM values were not provided." >&2
  exit 1
fi

if [[ "$have_external_bundle" -eq 1 ]]; then
  printf '%s\n' "$TLS_CA_CERT_PEM" >"$CA_CERT"
  printf '%s\n' "$TLS_CERT_PEM" >"$SERVER_CERT"
  printf '%s\n' "$TLS_KEY_PEM" >"$SERVER_KEY"
fi

LDAPI_URI="${OPENLDAP_LDAPI_URI:-}"
if [[ -z "$LDAPI_URI" ]]; then
  if LDAPI_URI="$(detect_ldapi_uri)"; then
    :
  else
    # We'll still attempt offline update below; online ldapmodify won't work.
    LDAPI_URI="ldapi:///"
  fi
fi

need_server_cert=0
if [[ "$have_external_bundle" -ne 1 && ("$FORCE_REGEN_SERVER" -eq 1 || ! -f "$SERVER_CERT") ]]; then
  need_server_cert=1
fi

if [[ -f "$SERVER_CERT" && ! -f "$SERVER_KEY" && "$FORCE_REGEN_SERVER" -ne 1 ]]; then
  echo "[FATAL] Server cert exists but server key is missing. Provide SERVER_KEY or set FORCE_REGEN_SERVER=1." >&2
  exit 1
fi

if [[ "$have_external_bundle" -eq 1 ]]; then
  :
elif [[ "$TLS_CERT_MODE" == "self_signed" || "$TLS_CERT_MODE" == "external_or_self_signed" ]]; then
  :
else
  echo "[FATAL] No certificate material available for TLS_CERT_MODE=${TLS_CERT_MODE}" >&2
  exit 1
fi

if [[ "$have_external_bundle" -eq 1 ]]; then
  :
elif [[ "$FORCE_REGEN_CA" -eq 1 ]]; then
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

if [[ "$have_external_bundle" -ne 1 && ("$FORCE_REGEN_SERVER" -eq 1 || ! -f "$SERVER_KEY") ]]; then
  echo "[INFO] Generating server key"
  openssl genrsa -out "$SERVER_KEY" 4096
fi

if [[ "$have_external_bundle" -ne 1 && ("$FORCE_REGEN_SERVER" -eq 1 || ! -f "$SERVER_CERT") ]]; then
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
update_defaults_urls "$SLAPD_DEFAULTS" "$LDAP_LISTENER_MODE"
update_ldap_conf "$LDAP_CONF" "$CA_CERT" "$TLS_REQCERT"

if apply_online_config "$SERVER_CERT" "$SERVER_KEY" "$CA_CERT" "$TLS_PROTOCOL_MIN" "$TLS_CIPHER_SUITE" "$TLS_VERIFY_CLIENT" "$LDAPI_URI"; then
  echo "[OK] TLS configured via ldapmodify"
else
  echo "[WARN] ldapmodify failed; falling back to offline update"
  apply_offline_config "$SERVER_CERT" "$SERVER_KEY" "$CA_CERT" "$TLS_PROTOCOL_MIN" "$TLS_CIPHER_SUITE" "$TLS_VERIFY_CLIENT" "$CONFIG_LDIF"
fi

systemctl daemon-reload
systemctl restart symas-openldap-servers >/dev/null 2>&1 || systemctl restart slapd

echo "[SUCCESS] TLS configuration completed (listener mode: ${LDAP_LISTENER_MODE}; SSL is not used)"
