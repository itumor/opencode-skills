#!/usr/bin/env bash
set -euo pipefail

echo "=== Fixing all Symas OpenLDAP verification WARNs ==="

### 0. Require root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Must be run as root"
  exit 1
fi

### 1. System-wide Symas environment (PATH + LDAPCONF)
ENV_FILE="/etc/profile.d/symas_env.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[INFO] Creating $ENV_FILE"
  cat >"$ENV_FILE" <<'EOF'
if [ -d "/opt/symas" ]; then
  export LDAPCONF=/opt/symas/etc/openldap/ldap.conf
  export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
  export MANPATH="${MANPATH:+$MANPATH:}/opt/symas/share/man"
fi
EOF
  chmod +x "$ENV_FILE"
else
  echo "[OK] $ENV_FILE already exists"
  if grep -q 'export MANPATH=\$MANPATH:/opt/symas/share/man' "$ENV_FILE"; then
    sed -i 's|export MANPATH=\$MANPATH:/opt/symas/share/man|export MANPATH="${MANPATH:+$MANPATH:}/opt/symas/share/man"|' "$ENV_FILE"
  elif ! grep -q 'export MANPATH=' "$ENV_FILE"; then
    sed -i '/^[[:space:]]*fi[[:space:]]*$/i\  export MANPATH="${MANPATH:+$MANPATH:}/opt/symas/share/man"' "$ENV_FILE"
  fi
fi

# Load it for current shell
source "$ENV_FILE"

### 2. Ensure LDAPCONF is set system-wide
if [[ -z "${LDAPCONF:-}" ]]; then
  echo "[INFO] Exporting LDAPCONF for current session"
  export LDAPCONF=/opt/symas/etc/openldap/ldap.conf
fi

### 3. Validate Symas binaries (authoritative paths)
echo "[INFO] Validating Symas slapd location"
SLAPD_BIN="$(rpm -ql symas-openldap-servers | grep '/slapd$' | head -n1 || true)"

if [[ -z "$SLAPD_BIN" ]]; then
  echo "[ERROR] slapd binary not found via RPM"
  exit 1
fi

echo "[OK] slapd binary: $SLAPD_BIN"

### 4. Enable LDAPS listener (636)
DEFAULTS="/etc/default/symas-openldap"

if [[ -f "$DEFAULTS" ]]; then
  if grep -q '^SLAPD_URLS=' "$DEFAULTS"; then
    sed -i 's|^SLAPD_URLS=.*|SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"|' "$DEFAULTS"
  else
    echo 'SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"' >>"$DEFAULTS"
  fi
else
  echo "[WARN] $DEFAULTS not found – skipping SLAPD_URLS"
fi

### 5. Restart OpenLDAP cleanly
echo "[INFO] Restarting OpenLDAP service"
systemctl daemon-reload
systemctl restart symas-openldap-servers

### 6. Open firewall ports (389 + 636) if firewalld is active
if systemctl is-active --quiet firewalld; then
  echo "[INFO] Configuring firewalld"

  firewall-cmd --permanent --add-port=389/tcp || true
  firewall-cmd --permanent --add-port=636/tcp || true
  firewall-cmd --reload
else
  echo "[INFO] firewalld not active – skipping firewall rules"
fi

### 7. Final verification hints
echo
echo "=== Fix complete ==="
echo
echo "Recommended verification:"
echo "  source /etc/profile.d/symas_env.sh"
echo "  ./5-verify_symas_openldap.sh"
echo
echo "Expected result:"
echo "  PASS > 20"
echo "  WARN = 0"
