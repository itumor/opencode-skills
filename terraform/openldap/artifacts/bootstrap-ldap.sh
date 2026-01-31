#!/usr/bin/env bash
set -euo pipefail

ROLE="${ROLE:-}"
VPC_NAME="${VPC_NAME:-}"
BASE_DN="${BASE_DN:-dc=cae,dc=local}"
ADMIN_DN="${ADMIN_DN:-cn=admin,${BASE_DN}}"
ADMIN_PW="${ADMIN_PW:-admin}"
REPL_DN="${REPL_DN:-cn=replicator,${BASE_DN}}"
REPL_PW="${REPL_PW:-replpass}"
SERVER_ID="${SERVER_ID:-1}"
PRIVATE_IP="${PRIVATE_IP:-}"
LDAP_PORT="${LDAP_PORT:-389}"
WRITE_LB_DNS="${WRITE_LB_DNS:-}"
ORG_NAME="${ORG_NAME:-CAE}"
MASTER_IPS_RAW="${MASTER_IPS:-}"

KEEPALIVED_ENABLED="${KEEPALIVED_ENABLED:-false}"
KEEPALIVED_ROLE="${KEEPALIVED_ROLE:-}"
KEEPALIVED_PEER_IP="${KEEPALIVED_PEER_IP:-}"
KEEPALIVED_PRIORITY="${KEEPALIVED_PRIORITY:-100}"
KEEPALIVED_AUTH_PASS="${KEEPALIVED_AUTH_PASS:-openldap}"
KEEPALIVED_EIP_ALLOC_ID="${KEEPALIVED_EIP_ALLOC_ID:-}"

ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-}"

MASTER_IPS=()
if [[ -n "$MASTER_IPS_RAW" ]]; then
  IFS=' ' read -r -a MASTER_IPS <<< "$MASTER_IPS_RAW"
fi

log() {
  echo "[bootstrap] $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[bootstrap] Missing required command: $1" >&2
    exit 1
  }
}

wait_for_ldapi() {
  log "Waiting for ldapi:/// to respond"
  for _ in {1..60}; do
    if ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

install_packages() {
  log "Installing OpenLDAP packages"
  if ! dnf -y install openldap-servers openldap-clients; then
    log "Initial install failed; attempting to enable RHEL RHUI repos and retry"
    if [[ -f /etc/os-release ]]; then
      # shellcheck disable=SC1091
      source /etc/os-release
      if [[ "${ID:-}" == "rhel" ]]; then
        local major="${VERSION_ID%%.*}"
        dnf -y install dnf-plugins-core rh-amazon-rhui-client || true
        if command -v dnf >/dev/null 2>&1; then
          repos=$(dnf -q repolist all | awk 'NR>2 {print $1}')
          for repo in $repos; do
            if [[ "$repo" =~ rhui.*(baseos|appstream) ]] || [[ "$repo" =~ rhel-${major}.*(baseos|appstream) ]]; then
              dnf config-manager --set-enabled "$repo" || true
            fi
          done
        fi
      fi
    fi
    dnf -y makecache || true
    dnf -y install openldap-servers openldap-clients || true
  fi

  if ! rpm -q openldap-servers >/dev/null 2>&1; then
    log "openldap-servers not available; installing Symas OpenLDAP 2.6"
    if ! command -v curl >/dev/null 2>&1; then
      dnf -y install curl || true
    fi
    curl -fsSL https://repo.symas.com/configs/SOLDAP/rhel9/release26.repo -o /etc/yum.repos.d/soldap-release26.repo
    dnf clean all || true
    dnf -y install symas-openldap-servers symas-openldap-clients
  fi

  if [[ -d /opt/symas/bin ]]; then
    export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
  fi

  if [[ -f /usr/share/openldap-servers/DB_CONFIG.example ]]; then
    cp -n /usr/share/openldap-servers/DB_CONFIG.example /var/lib/ldap/DB_CONFIG
    chown ldap:ldap /var/lib/ldap/DB_CONFIG
  fi

  log "Starting slapd"
  systemctl enable --now slapd

  if systemctl is-active --quiet firewalld; then
    log "Opening firewall for LDAP"
    firewall-cmd --permanent --add-port=${LDAP_PORT}/tcp || true
    firewall-cmd --reload || true
  fi
}

sync_artifacts() {
  if [[ -z "$ARTIFACTS_BUCKET" ]]; then
    return 0
  fi
  log "Syncing artifacts from s3://${ARTIFACTS_BUCKET}"
  dnf -y install awscli >/dev/null 2>&1 || true
  aws s3 sync "s3://${ARTIFACTS_BUCKET}/script" /opt/openldap/script || true
  aws s3 sync "s3://${ARTIFACTS_BUCKET}/ldif" /opt/openldap/ldif-src || true
  aws s3 sync "s3://${ARTIFACTS_BUCKET}/mirrormode-scripts" /opt/openldap/mirrormode-scripts || true
}

configure_base_dn() {
  local db_dn="$1"
  log "Configuring base DN and root DN"
  local hashed_pw
  hashed_pw=$(slappasswd -s "$ADMIN_PW")

  ldapmodify -Y EXTERNAL -H ldapi:/// <<LDIF
 dn: ${db_dn}
 changetype: modify
 replace: olcSuffix
 olcSuffix: ${BASE_DN}
 -
 replace: olcRootDN
 olcRootDN: ${ADMIN_DN}
 -
 replace: olcRootPW
 olcRootPW: ${hashed_pw}
LDIF

  if ! ldapsearch -x -H ldap://localhost:${LDAP_PORT} -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$BASE_DN" -s base dn >/dev/null 2>&1; then
    log "Creating base entries"
    local base_dc
    base_dc=$(echo "$BASE_DN" | awk -F',' '{print $1}' | awk -F= '{print $2}')
    cat >/tmp/base.ldif <<LDIF
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
LDIF
    ldapadd -x -H ldap://localhost:${LDAP_PORT} -D "$ADMIN_DN" -w "$ADMIN_PW" -f /tmp/base.ldif || true
  fi
}

write_ldif_files() {
  local db_dn="$1"
  local module_dn="$2"
  local peer_ip="$3"

  mkdir -p /opt/openldap/ldif

  cat >/opt/openldap/ldif/01-replicator.ldif <<LDIF
 dn: ${REPL_DN}
 objectClass: simpleSecurityObject
 objectClass: organizationalRole
 cn: replicator
 userPassword: ${REPL_PW}
 description: Replication user
LDIF

  cat >/opt/openldap/ldif/02-replicator-acl.ldif <<LDIF
 dn: ${db_dn}
 changetype: modify
 add: olcAccess
 olcAccess: {0}to * by dn.exact="${REPL_DN}" read by * break
LDIF

  cat >/opt/openldap/ldif/10-serverid.ldif <<LDIF
 dn: cn=config
 changetype: modify
 replace: olcServerID
 olcServerID: ${SERVER_ID} ldap://${PRIVATE_IP}:${LDAP_PORT}
LDIF

  if [[ -n "$module_dn" ]]; then
    cat >/opt/openldap/ldif/19-load-syncprov.ldif <<LDIF
 dn: ${module_dn}
 changetype: modify
 add: olcModuleLoad
 olcModuleLoad: syncprov
LDIF
  fi

  cat >/opt/openldap/ldif/20-syncprov-master.ldif <<LDIF
 dn: olcOverlay=syncprov,${db_dn}
 objectClass: olcOverlayConfig
 objectClass: olcSyncProvConfig
 olcOverlay: syncprov
 olcSpCheckpoint: 100 10
 olcSpSessionLog: 100
LDIF

  if [[ -n "$peer_ip" ]]; then
    local rid
    rid=$(printf "%03d" "$SERVER_ID")
    cat >/opt/openldap/ldif/21-mirrormode-master.ldif <<LDIF
 dn: ${db_dn}
 changetype: modify
 add: olcSyncRepl
 olcSyncRepl: rid=${rid} provider=ldap://${peer_ip}:${LDAP_PORT} bindmethod=simple binddn="${REPL_DN}" credentials=${REPL_PW} searchbase="${BASE_DN}" type=refreshAndPersist retry="5 5 300 5" timeout=1
 -
 add: olcMirrorMode
 olcMirrorMode: TRUE
LDIF
  fi

  cat >/opt/openldap/ldif/30-replica-consumer.ldif <<LDIF
 dn: ${db_dn}
 changetype: modify
 add: olcSyncRepl
LDIF
  local rid=101
  for ip in "${MASTER_IPS[@]}"; do
    echo "olcSyncRepl: rid=${rid} provider=ldap://${ip}:${LDAP_PORT} bindmethod=simple binddn=\"${REPL_DN}\" credentials=${REPL_PW} searchbase=\"${BASE_DN}\" type=refreshAndPersist retry=\"5 5 300 5\" timeout=1" >> /opt/openldap/ldif/30-replica-consumer.ldif
    rid=$((rid + 1))
  done
  cat >> /opt/openldap/ldif/30-replica-consumer.ldif <<LDIF
 -
 add: olcUpdateRef
 olcUpdateRef: ldap://${WRITE_LB_DNS}:${LDAP_PORT}
LDIF

  cat >/opt/openldap/ldif/31-replica-readonly.ldif <<LDIF
 dn: ${db_dn}
 changetype: modify
 add: olcReadOnly
 olcReadOnly: TRUE
LDIF
}

apply_replication_ldifs() {
  local db_dn="$1"
  local module_dn="$2"
  local peer_ip="$3"

  write_ldif_files "$db_dn" "$module_dn" "$peer_ip"

  log "Applying replication LDIFs"
  ldapadd -x -H ldap://localhost:${LDAP_PORT} -D "$ADMIN_DN" -w "$ADMIN_PW" -f /opt/openldap/ldif/01-replicator.ldif || true
  ldapmodify -Y EXTERNAL -H ldapi:/// -f /opt/openldap/ldif/02-replicator-acl.ldif || true
  ldapmodify -Y EXTERNAL -H ldapi:/// -f /opt/openldap/ldif/10-serverid.ldif || true

  if [[ "$ROLE" == "master" ]]; then
    if [[ -n "$module_dn" ]]; then
      ldapmodify -Y EXTERNAL -H ldapi:/// -f /opt/openldap/ldif/19-load-syncprov.ldif || true
    fi
    ldapadd -Y EXTERNAL -H ldapi:/// -f /opt/openldap/ldif/20-syncprov-master.ldif || true
    if [[ -n "$peer_ip" ]]; then
      ldapmodify -Y EXTERNAL -H ldapi:/// -f /opt/openldap/ldif/21-mirrormode-master.ldif || true
    fi
  else
    ldapmodify -Y EXTERNAL -H ldapi:/// -f /opt/openldap/ldif/30-replica-consumer.ldif || true
    ldapmodify -Y EXTERNAL -H ldapi:/// -f /opt/openldap/ldif/31-replica-readonly.ldif || true
  fi
}

setup_keepalived() {
  if [[ "$KEEPALIVED_ENABLED" != "true" ]]; then
    return 0
  fi

  if [[ -z "$KEEPALIVED_EIP_ALLOC_ID" || -z "$KEEPALIVED_PEER_IP" || -z "$KEEPALIVED_ROLE" ]]; then
    log "Keepalived enabled but missing configuration; skipping"
    return 0
  fi

  log "Installing keepalived"
  dnf -y install keepalived awscli

  local iface
  iface=$(ip -o -4 route show to default | awk '{print $5; exit}')

  local token
  token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)
  local md_header=""
  if [[ -n "$token" ]]; then
    md_header="X-aws-ec2-metadata-token: ${token}"
  fi

  local instance_id
  instance_id=$(curl -s -H "$md_header" http://169.254.169.254/latest/meta-data/instance-id)
  local region
  region=$(curl -s -H "$md_header" http://169.254.169.254/latest/dynamic/instance-identity/document | awk -F'"' '/region/ {print $4; exit}')

  cat >/usr/local/bin/check_slapd.sh <<'SCRIPT'
#!/usr/bin/env bash
systemctl is-active --quiet slapd
SCRIPT
  chmod +x /usr/local/bin/check_slapd.sh

  cat >/usr/local/bin/keepalived-notify.sh <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
state="${1:-}"
if [[ "${state}" == "master" ]]; then
  aws ec2 associate-address --allocation-id "${KEEPALIVED_EIP_ALLOC_ID}" --instance-id "${instance_id}" --allow-reassociation --region "${region}"
fi
SCRIPT
  chmod +x /usr/local/bin/keepalived-notify.sh

  cat >/etc/keepalived/keepalived.conf <<CONF
vrrp_script chk_slapd {
  script "/usr/local/bin/check_slapd.sh"
  interval 2
  fall 2
  rise 2
}

vrrp_instance VI_1 {
  state ${KEEPALIVED_ROLE}
  interface ${iface}
  virtual_router_id 51
  priority ${KEEPALIVED_PRIORITY}
  advert_int 1
  unicast_src_ip ${PRIVATE_IP}
  unicast_peer {
    ${KEEPALIVED_PEER_IP}
  }
  authentication {
    auth_type PASS
    auth_pass ${KEEPALIVED_AUTH_PASS}
  }
  track_script {
    chk_slapd
  }
  notify_master "/usr/local/bin/keepalived-notify.sh master"
  notify_backup "/usr/local/bin/keepalived-notify.sh backup"
  notify_fault "/usr/local/bin/keepalived-notify.sh fault"
}
CONF

  systemctl enable --now keepalived
  log "Keepalived configured (${KEEPALIVED_ROLE})"
}

main() {
  if [[ -z "$ROLE" || -z "$PRIVATE_IP" ]]; then
    log "ROLE or PRIVATE_IP missing; exiting" >&2
    exit 1
  fi

  mkdir -p /opt/openldap
  sync_artifacts
  install_packages
  require_cmd ldapsearch
  require_cmd ldapmodify
  require_cmd ldapadd
  require_cmd ldapwhoami

  if ! wait_for_ldapi; then
    log "ldapi:/// not available" >&2
    exit 1
  fi

  local db_dn
  db_dn=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -LLL '(olcDatabase=mdb)' dn | awk '/^dn: / {print $2; exit}')
  if [[ -z "$db_dn" ]]; then
    db_dn=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -LLL '(olcDatabase=*)' dn | awk '/^dn: / {print $2; exit}')
  fi
  if [[ -z "$db_dn" ]]; then
    log "Failed to detect database DN" >&2
    exit 1
  fi

  local module_dn
  module_dn=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -LLL '(objectClass=olcModuleList)' dn | awk '/^dn: / {print $2; exit}')

  configure_base_dn "$db_dn"

  local peer_ip=""
  if [[ "$ROLE" == "master" ]]; then
    for ip in "${MASTER_IPS[@]}"; do
      if [[ "$ip" != "$PRIVATE_IP" ]]; then
        peer_ip="$ip"
        break
      fi
    done
  fi

  apply_replication_ldifs "$db_dn" "$module_dn" "$peer_ip"

  setup_keepalived

  log "Bootstrap completed for ${ROLE} (${VPC_NAME})"
}

main "$@"
