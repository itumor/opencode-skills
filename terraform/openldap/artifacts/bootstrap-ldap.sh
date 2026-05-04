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
  local uri="$1"
  log "Waiting for ${uri} to respond"
  for _ in {1..60}; do
    if ldapwhoami -Y EXTERNAL -H "${uri}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

detect_ldapi_uri() {
  # Prefer the default ldapi:/// if it works; otherwise locate an actual socket path.
  if ldapwhoami -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
    echo "ldapi:///"
    return 0
  fi

  local sock=""
  local candidates=(
    "/var/symas/run/ldapi"
    "/var/run/slapd/ldapi"
    "/run/slapd/ldapi"
    "/run/openldap/ldapi"
    "/var/run/openldap/ldapi"
    "/var/run/ldap/ldapi"
    "/opt/symas/var/run/ldapi"
  )
  for s in "${candidates[@]}"; do
    if [[ -S "$s" ]]; then
      sock="$s"
      break
    fi
  done

  if [[ -z "$sock" ]] && command -v ss >/dev/null 2>&1; then
    sock="$(ss -xl 2>/dev/null | awk '/ldapi|slapd/ && $NF ~ /^\\// {print $NF; exit}')"
  fi

  if [[ -z "$sock" ]] && command -v find >/dev/null 2>&1; then
    sock="$(find /run /var/run /var/symas/run -maxdepth 3 -type s -name 'ldapi*' 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -z "$sock" ]]; then
    return 1
  fi

  local enc
  enc="$(printf '%s' "$sock" | sed 's,/,%%2F,g')"
  echo "ldapi://${enc}"
}

is_symas() {
  # Symas OpenLDAP installs into /opt/symas and provides the
  # symas-openldap-servers.service unit.
  [[ -x /opt/symas/lib/slapd ]] || return 1
  [[ -f /usr/lib/systemd/system/symas-openldap-servers.service ]] || return 1
  return 0
}

symas_prepare_cnconfig() {
  # Symas package defaults do not create an active slapd.conf, and the service
  # will fail unless a config is provided. We prefer cn=config for parity with
  # the rest of this repo (ldapmodify -Y EXTERNAL -H ldapi:/// ...).
  local conf_dir="/opt/symas/etc/openldap/slapd.d"
  local data_dir="/var/symas/openldap-data"

  mkdir -p "$conf_dir" "$data_dir" /var/symas/run

  # On SELinux-enforcing systems, slapd must be able to write to cn=config and DB dirs.
  # Symas installs under /opt which can otherwise be mislabeled.
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -Rv "$conf_dir" "$data_dir" /var/symas/run >/dev/null 2>&1 || true
  fi

  # Ensure Symas tools are on PATH for slappasswd/slapadd when installed.
  if [[ -d /opt/symas/bin || -d /opt/symas/sbin ]]; then
    export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
  fi

  local need_init="true"
  if [[ -d "$conf_dir" ]] && [[ -n "$(ls -A "$conf_dir" 2>/dev/null || true)" ]]; then
    need_init="false"
  fi
  # If cn=config exists but is incomplete (missing database entries), re-init.
  if [[ "$need_init" == "false" ]]; then
    if ! find "$conf_dir" -maxdepth 3 -type f -name '*.ldif' 2>/dev/null | grep -q 'olcDatabase'; then
      need_init="true"
    fi
  fi

  if [[ "$need_init" == "true" ]]; then
    require_cmd slapadd
    require_cmd slappasswd

    local hashed_pw tmp_ldif
    hashed_pw=$(slappasswd -s "$ADMIN_PW")
    tmp_ldif="/tmp/symas-slapd.ldif"

    cat >"$tmp_ldif" <<LDIF
dn: cn=config
objectClass: olcGlobal
cn: config
olcArgsFile: /var/symas/run/slapd.args
olcPidFile: /var/symas/run/slapd.pid
olcAuthzRegexp: gidNumber=0\\+uidNumber=0,cn=peercred,cn=external,cn=auth cn=config

dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulepath: /opt/symas/lib/openldap
olcModuleload: back_mdb.la

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
olcRootPW: ${hashed_pw}
olcDbDirectory: ${data_dir}
olcDbIndex: objectClass eq

dn: olcDatabase=monitor,cn=config
objectClass: olcDatabaseConfig
olcDatabase: monitor
olcRootDN: cn=config
olcMonitoring: FALSE
LDIF

    # Append schema entries (LDIF format). Using "include:" inside LDIF is invalid
    # and causes slapadd to fail with "attribute type undefined".
    for schema in core cosine inetorgperson nis; do
      local f="/opt/symas/etc/openldap/schema/${schema}.ldif"
      if [[ -f "$f" ]]; then
        echo >>"$tmp_ldif"
        cat "$f" >>"$tmp_ldif"
      else
        log "WARN: missing Symas schema LDIF: $f"
      fi
    done

    # Fresh init of cn=config for deterministic bootstraps.
    rm -rf "${conf_dir:?}/"*
    slapadd -n 0 -F "$conf_dir" -l "$tmp_ldif"

    if command -v restorecon >/dev/null 2>&1; then
      restorecon -Rv "$conf_dir" "$data_dir" /var/symas/run >/dev/null 2>&1 || true
    fi
  fi

  # Configure systemd service to use cn=config directory.
  # If an ldap service account exists, prefer running unprivileged; otherwise run as root.
  local slapd_opts
  slapd_opts="-F ${conf_dir}"
  if id ldap >/dev/null 2>&1; then
    chown -R ldap:ldap "$conf_dir" "$data_dir" /var/symas/run || true
    slapd_opts="-F ${conf_dir} -u ldap -g ldap"
  fi

  cat >/etc/default/symas-openldap <<EOF
# Include an explicit URL that matches olcServerID/olcSyncRepl provider host IPs.
# Some OpenLDAP builds refuse to start if serverID URLs don't match any listener URL.
SLAPD_URLS="ldap://127.0.0.1:${LDAP_PORT} ldap://${PRIVATE_IP}:${LDAP_PORT} ldapi:///"
SLAPD_OPTIONS="${slapd_opts}"
EOF
}

start_directory_service() {
  if is_symas; then
    symas_prepare_cnconfig
    log "Starting Symas OpenLDAP service"
    systemctl enable --now symas-openldap-servers
    return 0
  fi

  log "Starting slapd"
  systemctl enable --now slapd
}

install_packages() {
  # On small instances (e.g., t3.micro), re-running dnf installs can be slow and may
  # get OOM-killed. If the node is already bootstrapped, default to skipping package
  # installation and only ensure the directory service is running.
  if [[ "${BOOTSTRAP_SKIP_INSTALL:-}" == "1" ]] || [[ -f /opt/openldap/.bootstrap_done ]]; then
    if rpm -q openldap-servers >/dev/null 2>&1 || rpm -q symas-openldap-servers >/dev/null 2>&1; then
      log "Packages already installed; skipping dnf installs (BOOTSTRAP_SKIP_INSTALL/marker present)"
      start_directory_service
      return 0
    fi
  fi

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

  start_directory_service

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
  local ldapi_uri="${OPENLDAP_LDAPI_URI:-ldapi:///}"
  local hashed_pw
  hashed_pw=$(slappasswd -s "$ADMIN_PW")

  ldapmodify -Y EXTERNAL -H "$ldapi_uri" <<LDIF
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
  local repl_hashed_pw

  # Always store the replication bind password hashed. Some builds may not
  # accept a cleartext userPassword value for bind comparisons.
  repl_hashed_pw=$(slappasswd -s "$REPL_PW")

  mkdir -p /opt/openldap/ldif

  cat >/opt/openldap/ldif/01-replicator.ldif <<LDIF
dn: ${REPL_DN}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: replicator
userPassword: ${repl_hashed_pw}
description: Replication user
LDIF

  # If the entry already exists, ensure its password is updated.
  cat >/opt/openldap/ldif/03-replicator-pw.ldif <<LDIF
dn: ${REPL_DN}
changetype: modify
replace: userPassword
userPassword: ${repl_hashed_pw}
LDIF

  cat >/opt/openldap/ldif/02-replicator-acl.ldif <<LDIF
dn: ${db_dn}
changetype: modify
replace: olcAccess
# Allow simple binds to work by granting "auth" access to userPassword.
olcAccess: {0}to attrs=userPassword by self write by anonymous auth by * none
olcAccess: {1}to * by dn.exact="${REPL_DN}" read by * read
LDIF

  cat >/opt/openldap/ldif/10-serverid.ldif <<LDIF
dn: cn=config
changetype: modify
replace: olcServerID
#
# Important:
# - Using an olcServerID with an explicit URL requires that the URL match one of
#   the listener URLs passed to slapd via `-h` (Symas uses SLAPD_URLS).
# - In this repo we typically listen on `ldap:///` (all interfaces), which can
#   still fail to "match" URL-based serverID entries on some builds.
# - Using numeric-only serverIDs avoids the listener URL matching issue and is
#   sufficient for syncrepl since providers are configured explicitly.
olcServerID: ${SERVER_ID}
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
  local ldapi_uri="${OPENLDAP_LDAPI_URI:-ldapi:///}"

  write_ldif_files "$db_dn" "$module_dn" "$peer_ip"

  log "Applying replication LDIFs"
  ldapadd -x -H ldap://localhost:${LDAP_PORT} -D "$ADMIN_DN" -w "$ADMIN_PW" -f /opt/openldap/ldif/01-replicator.ldif || true
  ldapmodify -x -H ldap://localhost:${LDAP_PORT} -D "$ADMIN_DN" -w "$ADMIN_PW" -f /opt/openldap/ldif/03-replicator-pw.ldif || true
  ldapmodify -Y EXTERNAL -H "$ldapi_uri" -f /opt/openldap/ldif/02-replicator-acl.ldif || true
  ldapmodify -Y EXTERNAL -H "$ldapi_uri" -f /opt/openldap/ldif/10-serverid.ldif || true

  if [[ "$ROLE" == "master" ]]; then
    if [[ -n "$module_dn" ]]; then
      ldapmodify -Y EXTERNAL -H "$ldapi_uri" -f /opt/openldap/ldif/19-load-syncprov.ldif || true
    fi
    ldapadd -Y EXTERNAL -H "$ldapi_uri" -f /opt/openldap/ldif/20-syncprov-master.ldif || true
    if [[ -n "$peer_ip" ]]; then
      ldapmodify -Y EXTERNAL -H "$ldapi_uri" -f /opt/openldap/ldif/21-mirrormode-master.ldif || true
    fi
  else
    ldapmodify -Y EXTERNAL -H "$ldapi_uri" -f /opt/openldap/ldif/30-replica-consumer.ldif || true
    ldapmodify -Y EXTERNAL -H "$ldapi_uri" -f /opt/openldap/ldif/31-replica-readonly.ldif || true
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
systemctl is-active --quiet slapd || systemctl is-active --quiet symas-openldap-servers
SCRIPT
  chmod +x /usr/local/bin/check_slapd.sh

  cat >/usr/local/bin/keepalived-notify.sh <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
state="\${1:-}"
if [[ "\${state}" == "master" ]]; then
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

  local ldapi_uri=""
  ldapi_uri="$(detect_ldapi_uri || true)"
  if [[ -z "$ldapi_uri" ]]; then
    log "Failed to detect an ldapi socket/URI" >&2
    exit 1
  fi
  export OPENLDAP_LDAPI_URI="$ldapi_uri"

  if ! wait_for_ldapi "$ldapi_uri"; then
    log "${ldapi_uri} not available" >&2
    exit 1
  fi

  local db_dn
  db_dn=$(ldapsearch -Y EXTERNAL -H "$ldapi_uri" -b cn=config -LLL '(olcDatabase=mdb)' dn | awk '/^dn: / {print $2; exit}')
  if [[ -z "$db_dn" ]]; then
    db_dn=$(ldapsearch -Y EXTERNAL -H "$ldapi_uri" -b cn=config -LLL '(olcDatabase=*)' dn | awk '/^dn: / {print $2; exit}')
  fi
  if [[ -z "$db_dn" ]]; then
    log "Failed to detect database DN" >&2
    exit 1
  fi

  local module_dn
  module_dn=$(ldapsearch -Y EXTERNAL -H "$ldapi_uri" -b cn=config -LLL '(objectClass=olcModuleList)' dn | awk '/^dn: / {print $2; exit}')

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
  touch /opt/openldap/.bootstrap_done
}

main "$@"
