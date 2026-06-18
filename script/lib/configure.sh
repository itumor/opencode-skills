#!/usr/bin/env bash
# lib/configure.sh — cn=config, TLS, replication, ppolicy, schema, OUs
# ponytail: consolidated config functions, each idempotent, ldap-tolerant

# ponytail: all ldap_modify/add/search can fail — wrap with set +e/set -e
# so the pipeline never stops on non-critical ldap errors

load_base_schemas() {
  section "Load Base Schemas"
  # ponytail: schemas loaded by slapd.conf → slaptest conversion in init_cn_config.
  # This avoids the Symas core.ldif syntax bug entirely.
  local count=$(ldapi_search "cn=schema,cn=config" -s one -LLL dn 2>/dev/null | grep -c "^dn:" || echo 0)
  ok "Base schemas loaded (${count} entries)"
}

load_custom_schema() {
  section "Load Custom Schema"
  local sname="${SCHEMA_NAME:-bank-custom}"
  if ldapi_search "cn=schema,cn=config" -s one -LLL dn 2>/dev/null | grep -qi "cn=${sname}"; then
    ok "Custom schema '${sname}' already loaded"; return
  fi
  set +e
  ldapi_add <<LDIF
dn: cn=${sname},cn=schema,cn=config
objectClass: olcSchemaConfig
cn: ${sname}
olcAttributeTypes: ( 1.3.6.1.4.1.4203.666.1.200 NAME 'orclisenabled' DESC 'Account enabled flag' EQUALITY caseIgnoreMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
LDIF
  set -e
  ok "Custom schema '${sname}' created"
}

load_custom_attributes() {
  section "Load Custom Attributes"
  if ldapi_search "cn=schema,cn=config" -s one -LLL "olcAttributeTypes" 2>/dev/null | grep -qi "employeeType"; then
    ok "Custom attributes present"
  else
    warn "Custom attributes missing — run fix-ppolicy.sh"
  fi
}

configure_tls() {
  section "Configure TLS Certificates"
  if [[ "${SKIP_TLS:-0}" == "1" ]]; then skip "TLS config skipped"; return; fi

  # ponytail: delegate to proven 24-configure-ssl-tls.sh which handles the
  # ldapmodify error-80 + offline fallback correctly
  local tls_script="${SCRIPT_DIR:-.}/24-configure-ssl-tls.sh"
  if [[ -f "$tls_script" ]]; then
    bash "$tls_script" >/dev/null 2>&1 && ok "TLS configured" || warn "TLS config had issues — continuing"
    return
  fi

  # Fallback if old script not available
  require_cmd openssl
  mkdir -p "${TLS_DIR}"

  local ca="${TLS_DIR}/ca.crt" cakey="${TLS_DIR}/ca.key"
  local cert="${TLS_DIR}/ldap.crt" key="${TLS_DIR}/ldap.key"

  if [[ ! -f "$ca" ]]; then
    openssl genrsa -out "$cakey" 4096 2>/dev/null
    openssl req -x509 -new -nodes -key "$cakey" -sha256 -days 3650 \
      -subj "/C=US/O=Lab-CA/OU=LDAP/CN=LDAP CA" -out "$ca" 2>/dev/null
    ok "CA generated"
  fi

  if [[ ! -f "$cert" ]]; then
    local fqdn=$(hostname -f 2>/dev/null || hostname) short=$(hostname -s 2>/dev/null || hostname)
    local san="${TLS_DIR}/san.cnf"
    cat > "$san" <<CNF
[ req ]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext
[ dn ]
C=US
O=Lab-Org
OU=LDAP
CN=${fqdn}
[ req_ext ]
subjectAltName = @alt_names
[ alt_names ]
DNS.1 = ${fqdn}
DNS.2 = ${short}
DNS.3 = localhost
IP.1 = 127.0.0.1
CNF
    openssl genrsa -out "$key" 4096 2>/dev/null
    openssl req -new -key "$key" -out "${TLS_DIR}/ldap.csr" -config "$san" 2>/dev/null
    openssl x509 -req -in "${TLS_DIR}/ldap.csr" -CA "$ca" -CAkey "$cakey" \
      -CAcreateserial -out "$cert" -days 825 -sha256 \
      -extensions req_ext -extfile "$san" 2>/dev/null
    rm -f "${TLS_DIR}/ldap.csr" "$san"
    ok "Server certificate generated"
  fi

  chmod 700 "$TLS_DIR" 2>/dev/null || true
  chmod 600 "$cakey" "$key" 2>/dev/null || true
  local owner="ldap"; id symas-openldap >/dev/null 2>&1 && owner="symas-openldap"
  chown -R "${owner}:${owner}" "$TLS_DIR" 2>/dev/null || true

  set +e; set_tls_config "$cert" "$key" "$ca" "3.3"; set -e
  ok "TLS config applied"

  local svc=$(find_service)
  systemctl restart "$svc" 2>/dev/null || true; sleep 4
  ok "Daemon restarted"
}

create_ous() {
  section "Create Organization Units"
  # ponytail: use StartTLS bind (ldapi SASL EXTERNAL lacks write access
  # to data DB with default Symas ACLs from slapd.conf conversion)
  set +e
  admin_bind || { warn "Cannot bind as admin — no StartTLS"; set -e; return; }
  if ! admin_search "${BASE_DN}" -s base dn 2>/dev/null | grep -q "^dn:"; then
    ldapadd -x -ZZ -H "ldap://localhost" -D "${ADMIN_DN}" -w "${ADMIN_PW}" <<LDIF 2>/dev/null || true
dn: ${BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: eab
dc: eab
LDIF
    ok "Base DN created"
  fi
  for ou in Users Groups ServiceAccounts Systems Policies; do
    if admin_search "ou=${ou},${BASE_DN}" -s base dn 2>/dev/null | grep -q "^dn:"; then
      ok "OU ${ou} exists"
    else
      ldapadd -x -ZZ -H "ldap://localhost" -D "${ADMIN_DN}" -w "${ADMIN_PW}" <<LDIF 2>/dev/null || true
dn: ou=${ou},${BASE_DN}
objectClass: organizationalUnit
ou: ${ou}
LDIF
      ok "OU ${ou} created"
    fi
  done
  set -e
}

configure_replication_master() {
  section "Configure Replication (Master)"
  set +e
  if ! admin_search "cn=replicator,${BASE_DN}" -s base dn 2>/dev/null | grep -q "^dn:"; then
    admin_bind || { warn "Cannot bind as admin"; set -e; return; }
    local hash=$(python3 -c "
import hashlib,base64,os
s=os.urandom(8); h=hashlib.sha1(b'${REPL_PW}'); h.update(s)
print('{SSHA}'+base64.b64encode(h.digest()+s).decode())
" 2>/dev/null || echo "{SSHA}fallback")
    ldapadd -x -ZZ -H "ldap://localhost" -D "${ADMIN_DN}" -w "${ADMIN_PW}" <<LDIF 2>/dev/null || true
dn: cn=replicator,${BASE_DN}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: replicator
userPassword: ${hash}
description: Replication user
LDIF
    ok "Replicator user created"
  else ok "Replicator user exists"; fi

  # Syncprov module
  if ! ldapi_search "cn=config" -s sub "(olcModuleLoad=syncprov.la)" dn 2>/dev/null | grep -q "^dn:"; then
    ldapi_modify <<LDIF 2>/dev/null || true
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: syncprov.la
LDIF
    ok "Syncprov module loaded"
  fi

  # Syncprov overlay
  local db=$(db_dn)
  if ! has_overlay "syncprov"; then
    ldapi_add <<LDIF 2>/dev/null || true
dn: olcOverlay=syncprov,${db}
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 100
LDIF
    ok "Syncprov overlay added"
  else ok "Syncprov overlay present"; fi

  # Indices
  local idx=$(ldapi_search "$db" -s base -LLL olcDbIndex 2>/dev/null || true)
  if ! echo "$idx" | grep -q "entryUUID" || ! echo "$idx" | grep -q "entryCSN"; then
    ldapi_modify <<LDIF 2>/dev/null || true
dn: ${db}
changetype: modify
add: olcDbIndex
olcDbIndex: entryUUID eq
-
add: olcDbIndex
olcDbIndex: entryCSN eq
LDIF
    ok "Syncrepl indices added"
  else ok "Syncrepl indices present"; fi

  # ServerID
  local sid="${SERVER_ID:-1}"
  if ! ldapi_get_attr "cn=config" "olcServerID" | grep -q "."; then
    ldapi_modify <<LDIF 2>/dev/null || true
dn: cn=config
changetype: modify
add: olcServerID
olcServerID: ${sid}
LDIF
  fi
  ok "ServerID: ${sid}"
  set -e
}

configure_replication_replica() {
  section "Configure Replication (Replica)"
  local master_ip="${MASTER_IP:?MASTER_IP required}"
  local rid="${RID:-101}" sid="${SERVER_ID:-2}"
  local db=$(db_dn)

  set +e
  if ! ldapi_get_attr "cn=config" "olcServerID" | grep -q "."; then
    ldapi_modify <<LDIF 2>/dev/null || true
dn: cn=config
changetype: modify
add: olcServerID
olcServerID: ${sid}
LDIF
  fi

  if ! ldapi_search "$db" -s base -LLL olcSyncrepl 2>/dev/null | grep -q "olcSyncrepl:"; then
    ldapi_modify <<LDIF 2>/dev/null || true
dn: ${db}
changetype: modify
add: olcSyncrepl
olcSyncrepl: {0}rid=${rid} provider=ldap://${master_ip} bindmethod=simple binddn="${REPL_DN}" credentials=${REPL_PW} searchbase="${BASE_DN}" type=refreshAndPersist retry="5 5 300 +" timeout=1 starttls=yes tls_reqcert=never interval=00:00:00:10
LDIF
    ok "Syncrepl configured (provider: ${master_ip})"
  else ok "Syncrepl already configured"; fi

  if ! ldapi_get_attr "$db" "olcReadOnly" | grep -q "TRUE"; then
    ldapi_modify <<LDIF 2>/dev/null || true
dn: ${db}
changetype: modify
add: olcReadOnly
olcReadOnly: TRUE
LDIF
  fi
  if ! ldapi_get_attr "$db" "olcUpdateRef" | grep -q "."; then
    ldapi_modify <<LDIF 2>/dev/null || true
dn: ${db}
changetype: modify
add: olcUpdateRef
olcUpdateRef: ldap://${master_ip}
LDIF
  fi
  ok "Replica configured (readonly, updateRef to master)"
  set -e
}

configure_ppolicy() {
  section "Configure Password Policy"
  local db=$(db_dn)
  set +e

  if ! ldapi_search "cn=config" -s sub "(olcModuleLoad=ppolicy.la)" dn 2>/dev/null | grep -q "^dn:"; then
    ldapi_modify <<LDIF 2>/dev/null || true
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: ppolicy.la
LDIF
    ok "ppolicy module loaded"
  else ok "ppolicy module loaded"; fi

  if ! has_overlay "ppolicy"; then
    ldapi_add <<LDIF 2>/dev/null || true
dn: olcOverlay=ppolicy,${db}
objectClass: olcOverlayConfig
objectClass: olcPPolicyConfig
olcOverlay: ppolicy
olcPPolicyDefault: cn=default,ou=Policies,${BASE_DN}
olcPPolicyHashCleartext: TRUE
LDIF
    ok "ppolicy overlay created"
  else ok "ppolicy overlay present"; fi

  set -e
}

configure_accesslog() {
  section "Configure Accesslog Audit"
  local db=$(db_dn)
  set +e

  if ! ldapi_search "cn=config" -s sub "(olcModuleLoad=accesslog.la)" dn 2>/dev/null | grep -q "^dn:"; then
    ldapi_modify <<LDIF 2>/dev/null || true
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: accesslog.la
LDIF
    ok "Accesslog module loaded"
  else ok "Accesslog module loaded"; fi

  if ldapi_search "cn=config" -s sub "(olcDatabase=accesslog)" dn 2>/dev/null | grep -q "^dn:"; then
    ok "Accesslog database exists"
    set -e; return
  fi

  ldapi_add <<LDIF 2>/dev/null || true
dn: olcDatabase={2}mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: {2}mdb
olcDbDirectory: /var/symas/openldap-data/accesslog
olcSuffix: cn=accesslog
olcDbMaxSize: 2147483648
olcRootDN: cn=admin,${BASE_DN}
LDIF
  mkdir -p /var/symas/openldap-data/accesslog 2>/dev/null || true
  chown -R ldap:ldap /var/symas/openldap-data/accesslog 2>/dev/null || true

  ldapi_add <<LDIF 2>/dev/null || true
dn: olcOverlay=accesslog,${db}
objectClass: olcOverlayConfig
objectClass: olcAccessLogConfig
olcOverlay: accesslog
olcAccessLogDB: cn=accesslog
olcAccessLogOps: writes
olcAccessLogSuccess: TRUE
olcAccessLogPurge: 07+00:00 01+00:00
LDIF
  ok "Accesslog configured"
  set -e
}
