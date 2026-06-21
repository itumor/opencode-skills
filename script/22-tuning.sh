#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Run as root" >&2
  exit 1
fi

SERVICE_NAME="${SERVICE_NAME:-}"
if [[ -z "$SERVICE_NAME" ]]; then
  # Be robust across systemctl versions/output formats.
  if systemctl list-unit-files --type=service --no-pager --no-legend 'symas-openldap-servers.service' 2>/dev/null | awk '{print $1}' | grep -qx 'symas-openldap-servers.service'; then
    SERVICE_NAME="symas-openldap-servers"
  elif systemctl list-unit-files --type=service --no-pager --no-legend 'slapd.service' 2>/dev/null | awk '{print $1}' | grep -qx 'slapd.service'; then
    SERVICE_NAME="slapd"
  elif systemctl status symas-openldap-servers >/dev/null 2>&1; then
    SERVICE_NAME="symas-openldap-servers"
  elif systemctl status slapd >/dev/null 2>&1; then
    SERVICE_NAME="slapd"
  else
    echo "[FATAL] Could not detect service name; set SERVICE_NAME" >&2
    exit 1
  fi
fi

LIMIT_NOFILE="${LIMIT_NOFILE:-524288}"
DEFAULTS_FILE="${DEFAULTS_FILE:-/etc/default/symas-openldap}"
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
DROPIN_FILE="${DROPIN_DIR}/override.conf"

changed=0

mkdir -p "$DROPIN_DIR"
dropin_content=$(
  cat <<EOF
[Service]
LimitNOFILE=${LIMIT_NOFILE}
EOF
)

if [[ ! -f "$DROPIN_FILE" ]] || ! printf '%s\n' "$dropin_content" | diff -q - "$DROPIN_FILE" >/dev/null; then
  printf '%s\n' "$dropin_content" >"$DROPIN_FILE"
  echo "[OK] Set LimitNOFILE=${LIMIT_NOFILE} in $DROPIN_FILE"
  changed=1
else
  echo "[OK] LimitNOFILE already set in $DROPIN_FILE"
fi

update_default() {
  local key="$1"
  local value="$2"

  if [[ ! -f "$DEFAULTS_FILE" ]]; then
    touch "$DEFAULTS_FILE"
  fi

  if grep -q "^${key}=" "$DEFAULTS_FILE"; then
    sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$DEFAULTS_FILE"
  else
    printf '%s="%s"\n' "$key" "$value" >>"$DEFAULTS_FILE"
  fi
}

if [[ -n "${SLAPD_URLS:-}" ]]; then
  update_default "SLAPD_URLS" "$SLAPD_URLS"
  echo "[OK] Set SLAPD_URLS in $DEFAULTS_FILE"
  changed=1
else
  echo "[INFO] SLAPD_URLS not set; skipping"
fi

if [[ -n "${SLAPD_OPTIONS:-}" ]]; then
  update_default "SLAPD_OPTIONS" "$SLAPD_OPTIONS"
  echo "[OK] Set SLAPD_OPTIONS in $DEFAULTS_FILE"
  changed=1
else
  echo "[INFO] SLAPD_OPTIONS not set; skipping"
fi

echo "[INFO] Setting olcIdleTimeout=0 (no idle disconnect)"
ldapmodify -Y EXTERNAL -H ldapi:/// <<'LDIFEOF' 2>/dev/null || true
dn: cn=config
changetype: modify
replace: olcIdleTimeout
olcIdleTimeout: 0
LDIFEOF
echo "[OK] olcIdleTimeout set to 0"

if [[ "$changed" -eq 1 ]]; then
  systemctl daemon-reload
  systemctl restart "$SERVICE_NAME"
  echo "[OK] Reloaded systemd and restarted $SERVICE_NAME"
else
  echo "[OK] No changes; skipping restart"
fi
