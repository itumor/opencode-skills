#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Run as root to read cn=config via ldapi:///" >&2
  exit 1
fi

# Ensure Symas tools are on PATH so ldapsearch is found.
if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
  PATH="/opt/symas/bin:${PATH}"
fi

LDAPSEARCH="${LDAPSEARCH:-$(command -v ldapsearch || true)}"
if [[ -z "$LDAPSEARCH" ]]; then
  echo "[FATAL] ldapsearch not found; ensure Symas clients are installed" >&2
  exit 1
fi

TLS_DIR="${TLS_DIR:-/opt/symas/etc/openldap/tls}"
CA_CERT="${CA_CERT:-${TLS_DIR}/ca.crt}"
SERVER_CERT="${SERVER_CERT:-${TLS_DIR}/ldap.crt}"
SERVER_KEY="${SERVER_KEY:-${TLS_DIR}/ldap.key}"
SLAPD_DEFAULTS="${SLAPD_DEFAULTS:-/etc/default/symas-openldap}"
CHECK_SLAPD_URLS="${CHECK_SLAPD_URLS:-1}"

TLS_PROTOCOL_MIN_EXPECTED="${TLS_PROTOCOL_MIN_EXPECTED:-}"
TLS_CIPHER_SUITE_EXPECTED="${TLS_CIPHER_SUITE_EXPECTED:-}"
TLS_VERIFY_CLIENT_EXPECTED="${TLS_VERIFY_CLIENT_EXPECTED:-}"

for f in "$CA_CERT" "$SERVER_CERT" "$SERVER_KEY"; do
  if [[ -f "$f" ]]; then
    echo "[PASS] File present: $f"
  else
    echo "[FAIL] Missing file: $f" >&2
    exit 1
  fi
done

result="$($LDAPSEARCH -Y EXTERNAL -H ldapi:/// -b "cn=config" -s base \
  olcTLSCertificateFile olcTLSCertificateKeyFile olcTLSCACertificateFile \
  olcTLSProtocolMin olcTLSCipherSuite olcTLSVerifyClient 2>/dev/null)"

get_attr() {
  local name="$1"
  echo "$result" | awk -F': ' -v k="$name" '$1 == k {print $2; exit}'
}

cert_file="$(get_attr olcTLSCertificateFile)"
if [[ "$cert_file" == "$SERVER_CERT" ]]; then
  echo "[PASS] olcTLSCertificateFile set to $cert_file"
else
  echo "[FAIL] olcTLSCertificateFile mismatch (found: ${cert_file:-empty})" >&2
  exit 1
fi

key_file="$(get_attr olcTLSCertificateKeyFile)"
if [[ "$key_file" == "$SERVER_KEY" ]]; then
  echo "[PASS] olcTLSCertificateKeyFile set to $key_file"
else
  echo "[FAIL] olcTLSCertificateKeyFile mismatch (found: ${key_file:-empty})" >&2
  exit 1
fi

ca_file="$(get_attr olcTLSCACertificateFile)"
if [[ "$ca_file" == "$CA_CERT" ]]; then
  echo "[PASS] olcTLSCACertificateFile set to $ca_file"
else
  echo "[FAIL] olcTLSCACertificateFile mismatch (found: ${ca_file:-empty})" >&2
  exit 1
fi

if [[ -n "$TLS_PROTOCOL_MIN_EXPECTED" ]]; then
  protocol_min="$(get_attr olcTLSProtocolMin)"
  if [[ "$protocol_min" == "$TLS_PROTOCOL_MIN_EXPECTED" ]]; then
    echo "[PASS] olcTLSProtocolMin set to $protocol_min"
  else
    echo "[FAIL] olcTLSProtocolMin mismatch (found: ${protocol_min:-empty})" >&2
    exit 1
  fi
fi

if [[ -n "$TLS_CIPHER_SUITE_EXPECTED" ]]; then
  cipher_suite="$(get_attr olcTLSCipherSuite)"
  if [[ "$cipher_suite" == "$TLS_CIPHER_SUITE_EXPECTED" ]]; then
    echo "[PASS] olcTLSCipherSuite set"
  else
    echo "[FAIL] olcTLSCipherSuite mismatch (found: ${cipher_suite:-empty})" >&2
    exit 1
  fi
fi

if [[ -n "$TLS_VERIFY_CLIENT_EXPECTED" ]]; then
  verify_client="$(get_attr olcTLSVerifyClient)"
  if [[ "$verify_client" == "$TLS_VERIFY_CLIENT_EXPECTED" ]]; then
    echo "[PASS] olcTLSVerifyClient set to $verify_client"
  else
    echo "[FAIL] olcTLSVerifyClient mismatch (found: ${verify_client:-empty})" >&2
    exit 1
  fi
fi

if [[ "$CHECK_SLAPD_URLS" == "1" && -f "$SLAPD_DEFAULTS" ]]; then
  urls="$(awk -F= '/^SLAPD_URLS=/{print $2}' "$SLAPD_DEFAULTS" | tr -d '"')"
  if echo "$urls" | grep -q 'ldaps:///'; then
    echo "[PASS] SLAPD_URLS includes ldaps:///"
  else
    echo "[FAIL] SLAPD_URLS missing ldaps:/// (found: ${urls:-empty})" >&2
    exit 1
  fi
fi

echo "[SUCCESS] SSL/TLS configuration verification completed"
