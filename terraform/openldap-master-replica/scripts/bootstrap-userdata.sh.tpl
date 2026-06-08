#!/usr/bin/env bash
set -euo pipefail

exec > /var/log/openldap-bootstrap.log 2>&1

log() { printf '[openldap-bootstrap] %s\n' "$*"; }

log "Bootstrap starting: ${role}"

# --- Swap FIRST (avoid OOM on small instances) ---
log "creating 2G swapfile"
if ! swapon --show 2>/dev/null | grep -q '^/swapfile'; then
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
  log "swap enabled"
fi

# --- Symas OpenLDAP packages ---
log "installing Symas OpenLDAP packages"
dnf -y install curl dnf-plugins-core 2>&1 | tail -1 || true
curl -fsSL https://repo.symas.com/configs/SOLDAP/rhel9/release26.repo -o /etc/yum.repos.d/soldap-release26.repo
dnf clean all 2>&1 | tail -1 || true
dnf -y install symas-openldap-servers symas-openldap-clients openssl 2>&1 | tail -5 || true

log "adding PATH"
cat >/etc/profile.d/symas_env.sh <<'PROFILE'
export PATH="/opt/symas/bin:/opt/symas/sbin:$PATH"
export LDAPCONF="/opt/symas/etc/openldap/ldap.conf"
PROFILE
chmod 644 /etc/profile.d/symas_env.sh
source /etc/profile.d/symas_env.sh

# --- SSM Agent (after swap, lower priority) ---
log "installing SSM Agent"
dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm 2>&1 | tail -3 || true
systemctl enable amazon-ssm-agent 2>/dev/null || true
systemctl start amazon-ssm-agent 2>/dev/null || true

# --- AWS CLI ---
log "installing AWS CLI v2"
dnf -y install unzip 2>&1 | tail -1 || true
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -qo /tmp/awscliv2.zip -d /tmp/
  /tmp/aws/install 2>&1 | tail -1 || true
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

if systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd --permanent --add-port=389/tcp 2>/dev/null || true
  firewall-cmd --permanent --add-port=636/tcp 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
fi

touch /opt/openldap-master-replica.done
log "Bootstrap complete"
