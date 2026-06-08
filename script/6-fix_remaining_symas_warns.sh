#!/usr/bin/env bash
set -euo pipefail

echo "=== Fixing remaining Symas OpenLDAP WARNs ==="

# Must be root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Run as root"
  exit 1
fi

### 1. Normalize slapd binary location (verifier expects this)
REAL_SLAPD="/opt/symas/lib/slapd"
LINK_SLAPD="/opt/symas/sbin/slapd"

if [[ -x "$REAL_SLAPD" ]]; then
  mkdir -p /opt/symas/sbin
  if [[ ! -L "$LINK_SLAPD" ]]; then
    ln -s "$REAL_SLAPD" "$LINK_SLAPD"
    echo "[OK] Created slapd symlink: $LINK_SLAPD -> $REAL_SLAPD"
  else
    echo "[OK] slapd symlink already exists"
  fi
else
  echo "[FATAL] slapd binary not found at $REAL_SLAPD"
  exit 1
fi

### 2. Ensure slapd is in PATH for verifier
ENV_FILE="/etc/profile.d/symas_env.sh"
if ! grep -q "/opt/symas/sbin" "$ENV_FILE"; then
  echo 'export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH' >>"$ENV_FILE"
fi
source "$ENV_FILE"

### 3. Configure minimal TLS (required for LDAPS listener)
TLS_DIR="/opt/symas/etc/openldap/tls"
CERT="$TLS_DIR/ldap.crt"
KEY="$TLS_DIR/ldap.key"

mkdir -p "$TLS_DIR"
chmod 700 "$TLS_DIR"

if [[ "${TLS_MODE:-yes}" != "no" ]]; then
  if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
    echo "[INFO] Generating self-signed TLS cert"
    openssl req -x509 -nodes -newkey rsa:4096 \
      -keyout "$KEY" \
      -out "$CERT" \
      -days 3650 \
      -subj "/CN=$(hostname)"
    chmod 600 "$KEY"
  fi
else
  echo "[INFO] TLS_MODE=no — skipping TLS cert generation"
fi

### 4. Ensure slapd listens on ldaps:// + ldapi://
DEFAULTS="/etc/default/symas-openldap"
if [[ -f "$DEFAULTS" ]]; then
  sed -i 's|^SLAPD_URLS=.*|SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"|' "$DEFAULTS"
fi

### 5. Enable TLS + LDAPS in cn=config (online first, fallback to offline edit)
if [[ "${TLS_MODE:-yes}" != "no" ]]; then
set +e
ldapmodify_out="$(
  cat <<EOF | ldapmodify -Y EXTERNAL -H ldapi:/// 2>&1
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: $CERT
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: $KEY
EOF
)"
ldapmodify_rc=$?
set -e

if [[ $ldapmodify_rc -ne 0 ]]; then
  echo "[WARN] ldapmodify failed (rc=$ldapmodify_rc). Output:"
  echo "$ldapmodify_out"
  echo "[INFO] Falling back to offline cn=config edit"

  CONFIG_LDIF="/opt/symas/etc/openldap/slapd.d/cn=config.ldif"
  if [[ ! -f "$CONFIG_LDIF" ]]; then
    echo "[FATAL] cn=config LDIF not found at $CONFIG_LDIF"
    exit 1
  fi

  systemctl stop symas-openldap-servers || true

  if grep -q '^olcTLSCertificateFile:' "$CONFIG_LDIF"; then
    sed -i "s|^olcTLSCertificateFile:.*|olcTLSCertificateFile: $CERT|" "$CONFIG_LDIF"
  else
    sed -i "/^dn: cn=config$/a olcTLSCertificateFile: $CERT" "$CONFIG_LDIF"
  fi

  if grep -q '^olcTLSCertificateKeyFile:' "$CONFIG_LDIF"; then
    sed -i "s|^olcTLSCertificateKeyFile:.*|olcTLSCertificateKeyFile: $KEY|" "$CONFIG_LDIF"
  else
    sed -i "/^dn: cn=config$/a olcTLSCertificateKeyFile: $KEY" "$CONFIG_LDIF"
  fi
fi

else
  echo "[INFO] TLS_MODE=no — skipping TLS cn=config update"
fi

### 6. Restart cleanly
systemctl daemon-reload
systemctl restart symas-openldap-servers

echo
echo "=== All WARN fixes applied ==="
echo "Run verification again:"
echo "  ./5-verify_symas_openldap.sh"
