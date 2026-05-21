#!/usr/bin/env bash
# r3-start-replica-daemon.sh
#
# Enables and starts the Symas OpenLDAP service on replica.
# Validates service comes up and ldapi:// is reachable.
#
# Usage: sudo bash r3-start-replica-daemon.sh
set -euo pipefail

log()   { echo "[INFO] $*"; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  [[ -f "$prof" ]] && source "$prof" 2>/dev/null || true
  [[ ":${PATH}:" == *":/opt/symas/bin:"* ]]  || export PATH="/opt/symas/bin:${PATH}"
  [[ ":${PATH}:" == *":/opt/symas/sbin:"* ]] || export PATH="/opt/symas/sbin:${PATH}"
}
ensure_symas_env

log "Enabling and starting Symas OpenLDAP service (replica)"
systemctl daemon-reload

# Ensure SELinux context correct on slapd.d before start
if command -v restorecon >/dev/null 2>&1; then
  restorecon -Rv /opt/symas/etc/openldap/slapd.d/ 2>/dev/null || true
elif command -v chcon >/dev/null 2>&1; then
  chcon -Rt slapd_db_t /opt/symas/etc/openldap/slapd.d/ 2>/dev/null || true
fi

if systemctl list-unit-files symas-openldap-servers.service >/dev/null 2>&1; then
  systemctl enable symas-openldap-servers
  systemctl restart symas-openldap-servers
  SVC="symas-openldap-servers"
elif systemctl list-unit-files slapd.service >/dev/null 2>&1; then
  systemctl enable slapd
  systemctl restart slapd
  SVC="slapd"
else
  fatal "No recognised OpenLDAP systemd unit found"
fi

log "Waiting for service to start..."
for i in $(seq 1 15); do
  if systemctl is-active --quiet "$SVC"; then
    break
  fi
  sleep 2
done

systemctl is-active --quiet "$SVC" || fatal "${SVC} did not start. Check: journalctl -u ${SVC} -n 50"

log "Service ${SVC} is active"

# Verify ldapi reachable
for i in $(seq 1 10); do
  if ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1 || fatal "ldapi:// not reachable after service start"

log "Replica daemon started and ldapi:// reachable"
