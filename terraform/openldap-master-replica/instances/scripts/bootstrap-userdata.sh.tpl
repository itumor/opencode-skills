#!/usr/bin/env bash
set -euo pipefail

exec > /var/log/openldap-bootstrap.log 2>&1

ROLE="${role}"
PRIVATE_IP="${private_ip}"
MASTER_IP="${master_ip}"
BASE_DN="${base_dn}"
ORG_NAME="${org_name}"
ADMIN_DN="cn=admin,${base_dn}"
ADMIN_PW="${admin_pw}"
REPL_DN="cn=replicator,${base_dn}"
REPL_PW="${repl_pw}"
SERVER_ID="${server_id}"
LDAP_PORT="${ldap_port}"

export PATH="/opt/symas/bin:/opt/symas/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

log() { printf '[openldap-bootstrap] %s\n' "$*"; }

log "Bootstrapping OpenLDAP $ROLE (SERVER_ID=$SERVER_ID)"

# --- SSM Agent first (needed for CI SSM commands) ---
log "installing SSM Agent"
dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm >/dev/null 2>&1 || true
systemctl enable amazon-ssm-agent 2>/dev/null || true
systemctl start amazon-ssm-agent 2>/dev/null || true

# --- AWS CLI ---
log "installing AWS CLI v2"
dnf -y install unzip >/dev/null 2>&1 || true
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -qo /tmp/awscliv2.zip -d /tmp/
  /tmp/aws/install >/dev/null 2>&1 || true
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

# Swap for small instances
if ! swapon --show | awk '{print $1}' | grep -q '^/swapfile$'; then
  log "creating 2G swapfile"
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  if ! grep -q '^/swapfile ' /etc/fstab; then
    printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
  fi
fi

# Install packages
log "installing Symas OpenLDAP packages"
dnf -y install curl dnf-plugins-core >/dev/null 2>&1 || true
curl -fsSL https://repo.symas.com/configs/SOLDAP/rhel9/release26.repo -o /etc/yum.repos.d/soldap-release26.repo
dnf clean all >/dev/null 2>&1 || true
dnf -y install symas-openldap-servers symas-openldap-clients

# Generate slapd.conf then convert to cn=config via slaptest.
# The direct cn=config LDIF path (slapadd -n 0) fails on newer Symas
# schema LDIFs due to DC normalization issues. Using slapd.conf with
# "include" schema directives avoids this.
log "generating slapd.conf for $ROLE"
systemctl stop symas-openldap-servers >/dev/null 2>&1 || true
rm -rf /var/symas/openldap-data/* /opt/symas/etc/openldap/slapd.d/*
mkdir -p /opt/symas/etc/openldap/slapd.d /var/symas/openldap-data /var/symas/run

ADMIN_HASH=$(slappasswd -s "${admin_pw}")
SLAPD_CONF="/opt/symas/etc/openldap/slapd.conf"
SCHEMA_DIR="/opt/symas/etc/openldap/schema"

cat >"$SLAPD_CONF" <<SLCONF
include  $SCHEMA_DIR/core.schema
include  $SCHEMA_DIR/cosine.schema
include  $SCHEMA_DIR/inetorgperson.schema
include  $SCHEMA_DIR/nis.schema

pidfile  /var/symas/run/slapd.pid
argsfile /var/symas/run/slapd.args

modulepath  /opt/symas/lib/openldap
moduleload  back_mdb.la
moduleload  syncprov.la

database  mdb
maxsize   1073741824
suffix    ${base_dn}
rootdn    $$${ADMIN_DN}
rootpw    $$${ADMIN_HASH}
directory /var/symas/openldap-data
index     objectClass eq
index     entryCSN,entryUUID eq

database  monitor
rootdn    cn=config
SLCONF

slaptest -f "$SLAPD_CONF" -F /opt/symas/etc/openldap/slapd.d

# Fix ownership and selinux context
if id ldap >/dev/null 2>&1; then
  chown -R ldap:ldap /opt/symas/etc/openldap/slapd.d /var/symas/openldap-data /var/symas/run
fi
restorecon -Rv /opt/symas/etc/openldap/slapd.d /var/symas/openldap-data /var/symas/run >/dev/null 2>&1 || true

# Write default/env configuration
cat >/etc/default/symas-openldap <<SYMEOF
SLAPD_URLS="ldap://127.0.0.1:${ldap_port} ldap://${private_ip}:${ldap_port} ldapi:///"
SLAPD_OPTIONS="-F /opt/symas/etc/openldap/slapd.d"
SYMEOF

# Start slapd
log "starting Symas OpenLDAP"
systemctl enable --now symas-openldap-servers
for _ in $(seq 1 60); do
  if ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then break; fi
  sleep 2
done

# Open firewall
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${ldap_port}/tcp" || true
  firewall-cmd --reload || true
fi

# Master: create data
if [[ "$ROLE" == "master" ]]; then
  REPL_HASH=$(slappasswd -s "${repl_pw}")
  BASE_DC=$(printf '%s' "${base_dn}" | awk -F'[=,]' '{print $2}')
  DB_DN=$(ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b cn=config '(olcSuffix=*)' dn | awk '/^dn: / {print $2; exit}')

  log "creating base entries and replication user"
  cat >/tmp/openldap-base.ldif <<LDIF
dn: ${base_dn}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${org_name}
dc: $$${BASE_DC}

dn: ou=people,${base_dn}
objectClass: organizationalUnit
ou: people

dn: ou=groups,${base_dn}
objectClass: organizationalUnit
ou: groups

dn: $$${REPL_DN}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: replicator
userPassword: $$${REPL_HASH}
description: Replication bind user
LDIF
  ldapadd -x -H "ldap://localhost:${ldap_port}" -D "$$${ADMIN_DN}" -w "${admin_pw}" -f /tmp/openldap-base.ldif

  cat >/tmp/openldap-master-acl.ldif <<LDIF
dn: $$${DB_DN}
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword by self write by anonymous auth by * none
olcAccess: {1}to * by dn.exact="$$${REPL_DN}" read by * read
LDIF
  ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/openldap-master-acl.ldif

  cat >/tmp/openldap-master-syncprov.ldif <<LDIF
dn: olcOverlay=syncprov,$$${DB_DN}
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 100
LDIF
  ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/openldap-master-syncprov.ldif
fi

# Replica: configure syncrepl
if [[ "$ROLE" == "replica" ]]; then
  log "configuring replica consumer from ${master_ip}"
  DB_DN=$(ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b cn=config '(olcSuffix=*)' dn | awk '/^dn: / {print $2; exit}')

  cat >/tmp/openldap-replica-config.ldif <<LDIF
dn: $$${DB_DN}
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword by self write by anonymous auth by * none
olcAccess: {1}to * by * read
-
add: olcSyncRepl
olcSyncRepl: rid=101 provider=ldap://${master_ip}:${ldap_port} bindmethod=simple binddn="$$${REPL_DN}" credentials=${repl_pw} searchbase="${base_dn}" type=refreshAndPersist retry="5 5 300 5" timeout=1 starttls=no
-
add: olcUpdateRef
olcUpdateRef: ldap://${master_ip}:${ldap_port}
-
add: olcReadOnly
olcReadOnly: TRUE
LDIF
  ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/openldap-replica-config.ldif
  systemctl restart symas-openldap-servers
fi

# Verify
log "verifying $ROLE"
for _ in $(seq 1 10); do
  if ldapwhoami -x -H "ldap://localhost:${ldap_port}" -D "$$${ADMIN_DN}" -w "${admin_pw}" >/dev/null 2>&1; then
    break
  fi
  sleep 3
done
ldapwhoami -x -H "ldap://localhost:${ldap_port}" -D "$$${ADMIN_DN}" -w "${admin_pw}"

touch /opt/openldap-master-replica.done
log "bootstrap complete"
