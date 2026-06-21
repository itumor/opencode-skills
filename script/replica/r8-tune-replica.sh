#!/usr/bin/env bash
# r8-tune-replica.sh
#
# Performance tuning for replica node.
# Mirrors 22-tuning.sh from master exactly — same limits apply.
#
# Usage: sudo bash r8-tune-replica.sh
set -euo pipefail

log()   { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

LIMIT_NOFILE="${LIMIT_NOFILE:-524288}"
SLAPD_URLS="${SLAPD_URLS:-}"
SLAPD_OPTIONS="${SLAPD_OPTIONS:-}"

# Detect service name — check unit files (not just active units)
SERVICE_NAME="${SERVICE_NAME:-}"
if [[ -z "$SERVICE_NAME" ]]; then
  for svc in symas-openldap-servers slapd; do
    if systemctl list-unit-files --type=service 2>/dev/null | grep -qF "${svc}.service"; then
      SERVICE_NAME="$svc"
      break
    fi
  done
fi
# Final fallback: check if binary exists at known path
if [[ -z "$SERVICE_NAME" ]] && [[ -f /usr/lib/systemd/system/symas-openldap-servers.service ]]; then
  SERVICE_NAME="symas-openldap-servers"
fi
[[ -n "$SERVICE_NAME" ]] || fatal "Could not detect OpenLDAP service name; set SERVICE_NAME env var"

# systemd drop-in for file descriptor limit
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
DROPIN_FILE="${DROPIN_DIR}/override.conf"
mkdir -p "$DROPIN_DIR"

if grep -q "LimitNOFILE=${LIMIT_NOFILE}" "$DROPIN_FILE" 2>/dev/null; then
  log "LimitNOFILE already set in ${DROPIN_FILE}"
else
  cat > "$DROPIN_FILE" <<EOF
[Service]
LimitNOFILE=${LIMIT_NOFILE}
EOF
  log "Set LimitNOFILE=${LIMIT_NOFILE} in ${DROPIN_FILE}"
fi

DEFAULTS_FILE="/etc/default/${SERVICE_NAME}"
[[ -f "$DEFAULTS_FILE" ]] || touch "$DEFAULTS_FILE"

if [[ -n "$SLAPD_URLS" ]]; then
  if grep -q '^SLAPD_URLS=' "$DEFAULTS_FILE"; then
    sed -i "s|^SLAPD_URLS=.*|SLAPD_URLS=\"${SLAPD_URLS}\"|" "$DEFAULTS_FILE"
  else
    echo "SLAPD_URLS=\"${SLAPD_URLS}\"" >> "$DEFAULTS_FILE"
  fi
  log "Set SLAPD_URLS in ${DEFAULTS_FILE}"
else
  log "SLAPD_URLS not provided; skipping"
fi

if [[ -n "$SLAPD_OPTIONS" ]]; then
  if grep -q '^SLAPD_OPTIONS=' "$DEFAULTS_FILE"; then
    sed -i "s|^SLAPD_OPTIONS=.*|SLAPD_OPTIONS=\"${SLAPD_OPTIONS}\"|" "$DEFAULTS_FILE"
  else
    echo "SLAPD_OPTIONS=\"${SLAPD_OPTIONS}\"" >> "$DEFAULTS_FILE"
  fi
  log "Set SLAPD_OPTIONS in ${DEFAULTS_FILE}"
else
  log "SLAPD_OPTIONS not provided; skipping"
fi

log "Setting olcIdleTimeout=0 (no idle disconnect)"
ldapmodify -Y EXTERNAL -H ldapi:/// <<'LDIFEOF' 2>/dev/null || true
dn: cn=config
changetype: modify
replace: olcIdleTimeout
olcIdleTimeout: 0
LDIFEOF
log "olcIdleTimeout set to 0"

systemctl daemon-reload
systemctl restart "$SERVICE_NAME"
log "Reloaded systemd and restarted ${SERVICE_NAME}"
