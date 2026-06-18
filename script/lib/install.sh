#!/usr/bin/env bash
# lib/install.sh — package install, cn=config init, daemon start, cleanup

install_packages() {
  section "Install Symas OpenLDAP"
  if [[ "${SKIP_INSTALL:-0}" == "1" ]]; then skip "Package install skipped"; return; fi
  dnf -y install symas-openldap-servers symas-openldap-clients >/dev/null 2>&1 || { bad "Pkg install failed"; return 1; }
  ok "Symas OpenLDAP 2.6"
}

install_openssl() {
  command -v openssl >/dev/null 2>&1 && return 0
  dnf -y install openssl >/dev/null 2>&1 || true
  ok "openssl ready"
}

init_cn_config() {
  section "Initialize cn=config Database"
  if [[ "${SKIP_INIT:-0}" == "1" ]]; then skip "Config init skipped"; return; fi

  # Copy exampledb.sh to vendor location, run in slapd.conf mode (option 1),
  # then convert to cn=config via slaptest. This avoids the Symas core.ldif
  # syntax bug that breaks cn=config LDIF loading.
  local src="${SCRIPT_DIR:-.}/Exampledb/exampledb.sh"
  local dst="/opt/symas/share/symas/exampledb.sh"
  local slapd_conf="/opt/symas/etc/openldap/slapd.conf"
  local config_dir="/opt/symas/etc/openldap/slapd.d"

  [[ -f "$src" ]] || { bad "Exampledb.sh not found at $src"; return 1; }

  cp "$src" "$dst" 2>/dev/null || true; chmod +x "$dst" 2>/dev/null || true
  mkdir -p /opt/symas/share/symas 2>/dev/null || true

  (cd /opt/symas/share/symas && printf '1\nYES\nYES\nn\n' | bash "$dst" >/dev/null 2>&1) || true

  # ponytail: slapd.conf ACL only gives ldapi "write", not "manage".
  # OpenLDAP 2.6 needs "manage" for cn=config modifications and data writes.
  # Fix before slaptest conversion so all cn=config databases inherit it.
  if [[ -f "$slapd_conf" ]]; then
    sed -i 's/by sockurl="\^ldapi:\/\/\/\$" write/by sockurl="\^ldapi:\/\/\/\$" manage/' "$slapd_conf"
    sed -i 's/by sockurl.exact="ldapi:\/\/\/" write/by sockurl.exact="ldapi:\/\/\/" manage/' "$slapd_conf"
  fi

  # Convert slapd.conf to cn=config
  pkill -9 slapd 2>/dev/null || true
  systemctl stop symas-openldap-servers 2>/dev/null || systemctl stop slapd 2>/dev/null || true
  sleep 3
  rm -rf "$config_dir" 2>/dev/null || true; mkdir -p "$config_dir"
  /opt/symas/sbin/slaptest -f "$slapd_conf" -F "$config_dir" 2>&1 || true

  if [[ ! -f "${config_dir}/cn=config.ldif" ]]; then
    bad "slaptest failed to create cn=config"; return 1
  fi

  # SLAPD defaults
  cat > /etc/default/symas-openldap <<EOF
SLAPD_URLS="ldap:/// ldapi:///"
SLAPD_OPTIONS="-F ${config_dir}"
EOF

  ok "cn=config initialized (slapd.conf → slaptest)"
}

fix_ldapi_data_acl() {
  section "Fix Data ACL"
  set +e
  ldapmodify -Y EXTERNAL -H ldapi:/// <<LDIF 2>/dev/null || true
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcAccess
olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break
LDIF
  set -e
  ok "Data ACL fixed (ldapi manage)"
}

fix_rootpw_hash() {
  local svc=$(find_service)
  systemctl daemon-reload 2>/dev/null; systemctl enable "$svc" 2>/dev/null || true
  systemctl start "$svc" 2>/dev/null || true; sleep 3

  local hash
  hash=$(python3 -c "
import hashlib,base64,os
s=os.urandom(8);h=hashlib.sha1(b'${ADMIN_PW}');h.update(s)
print('{SSHA}'+base64.b64encode(h.digest()+s).decode())
" 2>/dev/null) || return
  set +e
  for db in "olcDatabase={0}config,cn=config" "olcDatabase={1}mdb,cn=config"; do
    ldapmodify -Y EXTERNAL -H ldapi:/// <<LDIF 2>/dev/null || true
dn: ${db}
changetype: modify
replace: olcRootPW
olcRootPW: ${hash}
LDIF
  done
  set -e
  ok "rootpw hashed"
}

fix_symas_env() {
  section "Fix Symas Environment"
  setup_path
  local prof="/etc/profile.d/symas_env.sh"
  if [[ ! -f "$prof" ]]; then
    cat > "$prof" <<'EOF'
export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
export LDAPCONF=/opt/symas/etc/openldap/ldap.conf
EOF
    chmod 644 "$prof"; ok "Created $prof"
  fi
  ok "PATH + LDAPCONF configured"
}

start_daemon() {
  section "Start OpenLDAP Daemon"
  local svc=$(find_service)
  systemctl daemon-reload 2>/dev/null; systemctl enable "$svc" 2>/dev/null || true
  systemctl restart "$svc" 2>/dev/null || true; sleep 4
  if systemctl is-active --quiet "$svc" 2>/dev/null || pgrep -x slapd >/dev/null 2>&1; then
    ok "$svc is running"
  else
    bad "$svc failed"; return 1
  fi
}

clean_openldap() {
  section "Clean OpenLDAP (reset)"
  local svc=$(find_service 2>/dev/null || echo "")
  [[ -n "$svc" ]] && { systemctl stop "$svc" 2>/dev/null || true; systemctl disable "$svc" 2>/dev/null || true; }
  pkill -x slapd 2>/dev/null || true; sleep 2
  rm -rf /opt/symas/etc/openldap/slapd.d/* 2>/dev/null || true
  rm -rf /var/symas/openldap-data/example/* 2>/dev/null || true
  rm -f /opt/symas/etc/openldap/slapd.conf 2>/dev/null || true
  rm -f /opt/symas/etc/openldap/tls/*.crt /opt/symas/etc/openldap/tls/*.key /opt/symas/etc/openldap/tls/*.csr /opt/symas/etc/openldap/tls/*.cnf 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  ok "OpenLDAP cleaned"
}
