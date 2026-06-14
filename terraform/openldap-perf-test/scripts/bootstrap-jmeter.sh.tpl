#!/usr/bin/env bash
set -euo pipefail

exec > /var/log/jmeter-bootstrap.log 2>&1

log() { printf '[jmeter-bootstrap] %s\n' "$*"; }

log "Bootstrap starting: loadgen-${loadgen_index}"

log "creating 1G swapfile"
if ! swapon --show 2>/dev/null | grep -q '^/swapfile'; then
  fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
  log "swap enabled"
fi

log "installing Java 17"
dnf -y install java-17-openjdk java-17-openjdk-devel 2>&1 | tail -3 || true

JMETER_VERSION="5.6.3"
JMETER_HOME="/opt/jmeter"

log "installing Apache JMeter $${JMETER_VERSION}"
if [ ! -d "$JMETER_HOME" ]; then
  curl -fsSL "https://dlcdn.apache.org/jmeter/binaries/apache-jmeter-$${JMETER_VERSION}.tgz" -o /tmp/jmeter.tgz
  tar xzf /tmp/jmeter.tgz -C /opt/
  mv "/opt/apache-jmeter-$${JMETER_VERSION}" "$JMETER_HOME"
  rm /tmp/jmeter.tgz
fi

log "adding JMeter to PATH"
cat >/etc/profile.d/jmeter.sh <<PROFILE
export JMETER_HOME="/opt/jmeter"
export PATH="/opt/jmeter/bin:$${PATH}"
PROFILE
chmod 644 /etc/profile.d/jmeter.sh
source /etc/profile.d/jmeter.sh

log "writing LDAP hosts file"
cat >>/etc/hosts <<HOSTS
${ldap_master_ip} ldap-master.perf.local
${ldap_replica_ip} ldap-replica.perf.local
HOSTS

log "installing SSM Agent"
dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm 2>&1 | tail -3 || true
systemctl enable amazon-ssm-agent 2>/dev/null || true
systemctl start amazon-ssm-agent 2>/dev/null || true

log "installing sysstat + tools"
dnf -y install sysstat procps-ng curl 2>&1 | tail -1 || true

touch /opt/jmeter-bootstrap.done
log "JMeter bootstrap complete"
