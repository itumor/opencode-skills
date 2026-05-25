#!/usr/bin/env bash
set -euo pipefail

exec > /var/log/openldap-bootstrap.log 2>&1

ROLE="${role}"
PRIVATE_IP="${private_ip}"
MASTER_IP="${master_ip}"
BASE_DN="${base_dn}"
ORG_NAME="${org_name}"
ADMIN_DN="cn=admin,${BASE_DN}"
ADMIN_PW="${admin_pw}"
REPL_DN="cn=replicator,${BASE_DN}"
REPL_PW="${repl_pw}"
SERVER_ID="${server_id}"
LDAP_PORT="389"

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"

log() { printf '[openldap-bootstrap] %s\n' "$*"; }

log "Bootstrapping OpenLDAP $ROLE (SERVER_ID=$SERVER_ID)"

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

# Write cn=config
log "writing cn=config for $ROLE"
systemctl stop symas-openldap-servers >/dev/null 2>&1 || true
mkdir -p /opt/symas/etc/openldap/slapd.d /var/symas/openldap-data /var/symas/run
rm -rf /opt/symas/etc/openldap/slapd.d/* /var/symas/openldap-data/*

ADMIN_HASH=$(slappasswd -s "${ADMIN_PW}")
TMP_LDIF="/tmp/symas-slapd-${ROLE}.ldif"

cat >"${TMP_LDIF}" <<LDIF
dn: cn=config
objectClass: olcGlobal
cn: config
olcArgsFile: /var/symas/run/slapd.args
olcPidFile: /var/symas/run/slapd.pid
olcAuthzRegexp: gidNumber=0\\+uidNumber=0,cn=peercred,cn=external,cn=auth cn=config
olcServerID: ${SERVER_ID}

dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulepath: /opt/symas/lib/openldap
olcModuleload: back_mdb.la
olcModuleload: syncprov.la

dn: cn=schema,cn=config
objectClass: olcSchemaConfig
cn: schema

dn: olcDatabase=frontend,cn=config
objectClass: olcDatabaseConfig
objectClass: olcFrontendConfig
olcDatabase: frontend

dn: olcDatabase=mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: mdb
olcDbMaxSize: 1073741824
olcSuffix: ${BASE_DN}
olcRootDN: ${ADMIN_DN}
olcRootPW: ${ADMIN_HASH}
olcDbDirectory: /var/symas/openldap-data
olcDbIndex: objectClass eq
olcDbIndex: entryCSN,entryUUID eq

dn: olcDatabase=monitor,cn=config
objectClass: olcDatabaseConfig
olcDatabase: monitor
olcRootDN: cn=config
olcMonitoring: FALSE
LDIF

for schema in core cosine inetorgperson nis; do
  if [[ -f "/opt/symas/etc/openldap/schema/${schema}.ldif" ]]; then
    printf '\n' >>"${TMP_LDIF}"
    cat "/opt/symas/etc/openldap/schema/${schema}.ldif" >>"${TMP_LDIF}"
  fi
done

slapadd -n 0 -F /opt/symas/etc/openldap/slapd.d -l "${TMP_LDIF}"

if id ldap >/dev/null 2>&1; then
  chown -R ldap:ldap /opt/symas/etc/openldap/slapd.d /var/symas/openldap-data /var/symas/run
  cat >/etc/default/symas-openldap <<EOF
SLAPD_URLS="ldap://127.0.0.1:${LDAP_PORT} ldap://${PRIVATE_IP}:${LDAP_PORT} ldapi:///"
SLAPD_OPTIONS="-F /opt/symas/etc/openldap/slapd.d -u ldap -g ldap"
EOF
else
  cat >/etc/default/symas-openldap <<EOF
SLAPD_URLS="ldap://127.0.0.1:${LDAP_PORT} ldap://${PRIVATE_IP}:${LDAP_PORT} ldapi:///"
SLAPD_OPTIONS="-F /opt/symas/etc/openldap/slapd.d"
EOF
fi

restorecon -Rv /opt/symas/etc/openldap/slapd.d /var/symas/openldap-data /var/symas/run >/dev/null 2>&1 || true

# Start slapd
log "starting Symas OpenLDAP"
systemctl enable --now symas-openldap-servers
for _ in $(seq 1 60); do
  if ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then break; fi
  sleep 2
done

# Open firewall
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${LDAP_PORT}/tcp" || true
  firewall-cmd --reload || true
fi

# Master: create data
if [[ "$ROLE" == "master" ]]; then
  REPL_HASH=$(slappasswd -s "${REPL_PW}")
  BASE_DC=$(printf '%s' "${BASE_DN}" | awk -F'[=,]' '{print $2}')
  DB_DN=$(ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b cn=config '(olcSuffix=*)' dn | awk '/^dn: / {print $2; exit}')

  log "creating base entries and replication user"
  cat >/tmp/openldap-base.ldif <<LDIF
dn: ${BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${ORG_NAME}
dc: ${BASE_DC}

dn: ou=people,${BASE_DN}
objectClass: organizationalUnit
ou: people

dn: ou=groups,${BASE_DN}
objectClass: organizationalUnit
ou: groups

dn: ${REPL_DN}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: replicator
userPassword: ${REPL_HASH}
description: Replication bind user
LDIF
  ldapadd -x -H "ldap://localhost:${LDAP_PORT}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" -f /tmp/openldap-base.ldif

  cat >/tmp/openldap-master-acl.ldif <<LDIF
dn: ${DB_DN}
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword by self write by anonymous auth by * none
olcAccess: {1}to * by dn.exact="${REPL_DN}" read by * read
LDIF
  ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/openldap-master-acl.ldif

  cat >/tmp/openldap-master-syncprov.ldif <<LDIF
dn: olcOverlay=syncprov,${DB_DN}
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
  log "configuring replica consumer from ${MASTER_IP}"
  DB_DN=$(ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b cn=config '(olcSuffix=*)' dn | awk '/^dn: / {print $2; exit}')

  cat >/tmp/openldap-replica-config.ldif <<LDIF
dn: ${DB_DN}
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword by self write by anonymous auth by * none
olcAccess: {1}to * by * read
-
add: olcSyncRepl
olcSyncRepl: rid=101 provider=ldap://${MASTER_IP}:${LDAP_PORT} bindmethod=simple binddn="${REPL_DN}" credentials=${REPL_PW} searchbase="${BASE_DN}" type=refreshAndPersist retry="5 5 300 5" timeout=1 starttls=no
-
add: olcUpdateRef
olcUpdateRef: ldap://${MASTER_IP}:${LDAP_PORT}
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
  if ldapwhoami -x -H "ldap://localhost:${LDAP_PORT}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" >/dev/null 2>&1; then
    break
  fi
  sleep 3
done
ldapwhoami -x -H "ldap://localhost:${LDAP_PORT}" -D "${ADMIN_DN}" -w "${ADMIN_PW}"

touch /opt/openldap-master-replica.done
log "bootstrap complete"
