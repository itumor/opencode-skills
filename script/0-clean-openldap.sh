#!/usr/bin/env bash
set -euo pipefail

log()  { echo "[CLEAN] $*"; }
warn() { echo "[WARN] $*"; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Must be run as root"
  exit 1
fi

log "Stopping and disabling slapd services (if present)"
SERVICES=(symas-openldap-servers slapd)
for svc in "${SERVICES[@]}"; do
  if systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"; then
    systemctl stop "${svc}.service" || warn "stop ${svc} failed"
    systemctl disable "${svc}.service" >/dev/null 2>&1 || true
  fi
done
systemctl daemon-reload || true

if systemctl is-active --quiet firewalld; then
  log "Removing firewalld rules for 389/tcp and 636/tcp"
  firewall-cmd --permanent --remove-port=389/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --remove-port=636/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi

log "Removing Symas packages"
PKGS=(symas-openldap-servers symas-openldap-clients symas-openldap-servers-selinux symas-openldap)
for pkg in "${PKGS[@]}"; do
  if rpm -q "$pkg" >/dev/null 2>&1; then
    dnf -y remove "$pkg" || warn "dnf remove $pkg failed"
  fi
done
dnf -y autoremove >/dev/null 2>&1 || true
dnf clean all >/dev/null 2>&1 || true

log "Removing Symas repo and config"
rm -f /etc/yum.repos.d/soldap-release26.repo
rm -f /etc/default/symas-openldap
rm -f /etc/profile.d/symas_env.sh
rm -rf /etc/systemd/system/symas-openldap-servers.service.d

log "Removing Symas binaries and data"
rm -rf /opt/symas /var/symas

log "Removing temporary LDIF artifacts"
rm -f /tmp/pw_load_module.ldif /tmp/ppolicy-container.ldif

log "Cleanup complete. You can re-run install-symas-openldap-all-in-one.sh for a fresh install."
