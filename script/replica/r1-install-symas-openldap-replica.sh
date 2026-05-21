#!/usr/bin/env bash
# r1-install-symas-openldap-replica.sh
#
# Installs Symas OpenLDAP packages on the replica node.
# Identical to master install — same packages, same binary.
# Repo must be enabled via Red Hat Satellite before running.
#
# Usage: sudo bash r1-install-symas-openldap-replica.sh
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Must be run as root" >&2
  exit 1
fi

require_cmd() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[FATAL] Required command not found: ${bin}" >&2
    exit 1
  fi
}

require_cmd dnf

echo "[INFO] Installing Symas OpenLDAP packages (replica)"
dnf -y install symas-openldap-clients symas-openldap-servers

echo "[INFO] Verifying Symas OpenLDAP packages are installed"
if ! rpm -q symas-openldap-clients symas-openldap-servers >/dev/null 2>&1; then
  echo "[FATAL] Symas OpenLDAP packages not installed." >&2
  echo "[FATAL] Ensure Symas SOLDAP repo is enabled via Red Hat Satellite." >&2
  exit 1
fi

echo "[OK] Symas OpenLDAP packages installed on replica"
