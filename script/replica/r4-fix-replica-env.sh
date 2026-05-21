#!/usr/bin/env bash
# r4-fix-replica-env.sh
#
# Sets system-wide Symas PATH and LDAPCONF on replica.
# Mirrors 5-fix_all_symas_warns.sh from master chain.
#
# Usage: sudo bash r4-fix-replica-env.sh
set -euo pipefail

log()  { echo "[INFO] $*"; }
fatal(){ echo "[FATAL] $*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

ENV_FILE="/etc/profile.d/symas_env.sh"
SLAPD_REAL="/opt/symas/lib/slapd"
SLAPD_LINK="/opt/symas/sbin/slapd"

if [[ ! -f "$ENV_FILE" ]]; then
  log "Creating ${ENV_FILE}"
  cat > "$ENV_FILE" <<'EOF'
export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
export LDAPCONF=/opt/symas/etc/openldap/ldap.conf
EOF
else
  log "${ENV_FILE} already exists"
fi

source "$ENV_FILE"

# slapd symlink
if [[ -f "$SLAPD_REAL" ]] && [[ ! -f "$SLAPD_LINK" ]]; then
  ln -sf "$SLAPD_REAL" "$SLAPD_LINK"
  log "Created slapd symlink: ${SLAPD_LINK} -> ${SLAPD_REAL}"
elif [[ -f "$SLAPD_LINK" ]]; then
  log "slapd symlink already exists"
else
  fatal "slapd binary not found at ${SLAPD_REAL}"
fi

# Restart service to pick up env
systemctl restart symas-openldap-servers 2>/dev/null || systemctl restart slapd 2>/dev/null || true

log "Replica environment configured"
