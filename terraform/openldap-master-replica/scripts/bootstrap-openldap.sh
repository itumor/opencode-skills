#!/usr/bin/env bash
set -euo pipefail

ROLE="${ROLE:?ROLE is required}"
PRIVATE_IP="${PRIVATE_IP:?PRIVATE_IP is required}"
MASTER_IP="${MASTER_IP:-}"
BASE_DN="${BASE_DN:-dc=cae,dc=local}"
ORG_NAME="${ORG_NAME:-CAE}"
ADMIN_DN="cn=admin,${BASE_DN}"
ADMIN_PW="${ADMIN_PW:-admin}"
REPL_DN="cn=replicator,${BASE_DN}"
REPL_PW="${REPL_PW:-replpass}"
SERVER_ID="${SERVER_ID:-1}"
LDAP_PORT="${LDAP_PORT:-389}"

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"

log() {
  printf '[openldap-bootstrap] %s\n' "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "must run as root"
    exit 1
  fi
}

install_packages() {
  log "installing Symas OpenLDAP packages"
  dnf -y install curl dnf-plugins-core >/dev/null 2>&1 || true
  curl -fsSL https://repo.symas.com/configs/SOLDAP/rhel9/release26.repo -o /etc/yum.repos.d/soldap-release26.repo
  dnf clean all >/dev/null 2>&1 || true
  dnf -y install symas-openldap-servers symas-openldap-clients
}

ensure_swap() {
  if swapon --show | awk '{print $1}' | grep -q '^/swapfile$'; then
    return 0
  fi

  log "creating 2G swapfile for small EC2 package installs"
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  if ! grep -q '^/swapfile ' /etc/fstab; then
    printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
  fi
}

write_slapd_config() {
  log "writing fresh cn=config for ${ROLE}"
  systemctl stop symas-openldap-servers >/dev/null 2>&1 || true

  mkdir -p /opt/symas/etc/openldap/slapd.d /var/symas/openldap-data /var/symas/run
  rm -rf /opt/symas/etc/openldap/slapd.d/* /var/symas/openldap-data/*

  local admin_hash tmp_ldif
  admin_hash="$(slappasswd -s "${ADMIN_PW}")"
  tmp_ldif="/tmp/symas-slapd-${ROLE}.ldif"

  cat >"${tmp_ldif}" <<LDIF
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
olcRootPW: ${admin_hash}
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
      printf '\n' >>"${tmp_ldif}"
      cat "/opt/symas/etc/openldap/schema/${schema}.ldif" >>"${tmp_ldif}"
    fi
  done

  slapadd -n 0 -F /opt/symas/etc/openldap/slapd.d -l "${tmp_ldif}"

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
}

start_slapd() {
  log "starting Symas OpenLDAP"
  systemctl enable --now symas-openldap-servers
  for _ in {1..60}; do
    if ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  systemctl status symas-openldap-servers --no-pager || true
  exit 1
}

create_master_data() {
  local repl_hash base_dc db_dn
  repl_hash="$(slappasswd -s "${REPL_PW}")"
  base_dc="$(printf '%s' "${BASE_DN}" | awk -F'[=,]' '{print $2}')"
  db_dn="$(ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b cn=config '(olcSuffix=*)' dn | awk '/^dn: / {print $2; exit}')"

  log "creating base entries and replication user"
  cat >/tmp/openldap-base.ldif <<LDIF
dn: ${BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${ORG_NAME}
dc: ${base_dc}

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
userPassword: ${repl_hash}
description: Replication bind user
LDIF
  ldapadd -x -H "ldap://localhost:${LDAP_PORT}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" -f /tmp/openldap-base.ldif

  cat >/tmp/openldap-master-acl.ldif <<LDIF
dn: ${db_dn}
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword by self write by anonymous auth by * none
olcAccess: {1}to * by dn.exact="${REPL_DN}" read by * read
LDIF
  ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/openldap-master-acl.ldif

  cat >/tmp/openldap-master-syncprov.ldif <<LDIF
dn: olcOverlay=syncprov,${db_dn}
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 100
LDIF
  ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/openldap-master-syncprov.ldif
}

configure_replica() {
  if [[ -z "${MASTER_IP}" ]]; then
    log "MASTER_IP required for replica"
    exit 1
  fi

  local db_dn
  db_dn="$(ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b cn=config '(olcSuffix=*)' dn | awk '/^dn: / {print $2; exit}')"

  log "configuring replica consumer from ${MASTER_IP}"
  cat >/tmp/openldap-replica-config.ldif <<LDIF
dn: ${db_dn}
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword by self write by anonymous auth by * none
olcAccess: {1}to * by * read
-
add: olcSyncRepl
olcSyncRepl: rid=101 provider=ldap://${MASTER_IP}:${LDAP_PORT} bindmethod=simple binddn="${REPL_DN}" credentials=${REPL_PW} searchbase="${BASE_DN}" type=refreshAndPersist retry="5 5 300 5" timeout=1
-
add: olcUpdateRef
olcUpdateRef: ldap://${MASTER_IP}:${LDAP_PORT}
-
add: olcReadOnly
olcReadOnly: TRUE
LDIF
  ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/openldap-replica-config.ldif
}

open_firewall() {
  if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${LDAP_PORT}/tcp" || true
    firewall-cmd --reload || true
  fi
}

verify_local() {
  log "verifying ${ROLE}"
  ldapwhoami -x -H "ldap://localhost:${LDAP_PORT}" -D "${ADMIN_DN}" -w "${ADMIN_PW}"
  if [[ "${ROLE}" == "master" ]]; then
    ldapsearch -LLL -x -H "ldap://localhost:${LDAP_PORT}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" -b "${BASE_DN}" -s base dn
  fi
}

main() {
  require_root
  ensure_swap
  install_packages
  write_slapd_config
  start_slapd
  open_firewall

  if [[ "${ROLE}" == "master" ]]; then
    create_master_data
  elif [[ "${ROLE}" == "replica" ]]; then
    configure_replica
  else
    log "unsupported ROLE: ${ROLE}"
    exit 1
  fi

  verify_local
  touch /opt/openldap-master-replica.done
  log "complete"
}

main "$@"
