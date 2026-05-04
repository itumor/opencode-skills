#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Must be run as root" >&2
  exit 1
fi

echo "[INFO] Enabling and starting Symas OpenLDAP service"
systemctl enable --now symas-openldap-servers
systemctl restart symas-openldap-servers

# Some systems also provide a slapd unit. Treat it as optional.
if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx 'slapd.service'; then
  echo "[INFO] Restarting slapd.service"
  systemctl restart slapd
fi
