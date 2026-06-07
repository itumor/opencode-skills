#!/usr/bin/env bash
set -euo pipefail

exec > /var/log/openldap-bootstrap.log 2>&1

log() { printf '[openldap-bootstrap] %s\n' "$*"; }

log "Bootstrap starting: ${role}"

if ! swapon --show | grep -q '^/swapfile'; then
  log "creating 2G swapfile"
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
fi

log "installing Symas OpenLDAP packages"
dnf -y install curl dnf-plugins-core >/dev/null 2>&1 || true
curl -fsSL https://repo.symas.com/configs/SOLDAP/rhel9/release26.repo -o /etc/yum.repos.d/soldap-release26.repo
dnf clean all >/dev/null 2>&1 || true
dnf -y install symas-openldap-servers symas-openldap-clients openssl

log "adding PATH"
cat >/etc/profile.d/symas_env.sh <<'PROFILE'
export PATH="/opt/symas/bin:/opt/symas/sbin:$PATH"
export LDAPCONF="/opt/symas/etc/openldap/ldap.conf"
PROFILE
chmod 644 /etc/profile.d/symas_env.sh
source /etc/profile.d/symas_env.sh

if systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd --permanent --add-port=389/tcp 2>/dev/null || true
  firewall-cmd --permanent --add-port=636/tcp 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
fi

touch /opt/openldap-master-replica.done
log "Bootstrap complete"
