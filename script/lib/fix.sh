#!/usr/bin/env bash
# lib/fix.sh — self-healing functions

fix() {
  section "Auto-Fix"
  local role="$1"
  fix_checksums
  fix_syncrepl_tls "$role"
  fix_ppolicy
  fix_indices
  fix_syncprov "$role"
  fix_readonly "$role"
}

fix_checksums() {
  section "Fix: Checksums"
  local svc=$(find_service)
  local chk=$(journalctl -u "$svc" --no-pager --since "2 minutes ago" 2>/dev/null | grep -ci "checksum error" || true)
  if [[ "$chk" -eq 0 ]]; then ok "No checksum errors — skipping"; return; fi
  warn "${chk} checksum error(s) — rebuilding cn=config"

  set +e
  local slapd_d="/opt/symas/etc/openldap/slapd.d"
  local ts=$(date +%Y%m%d-%H%M%S)
  local export_ldif="/tmp/cn-config-${ts}.ldif" backup="${slapd_d}.fix-${ts}"

  cp -a "$slapd_d" "$backup" 2>/dev/null
  slapcat -n 0 -l "$export_ldif" 2>/dev/null || { bad "slapcat export failed"; set -e; return; }
  systemctl stop "$svc" 2>/dev/null; sleep 2
  find "$slapd_d" -mindepth 1 -delete 2>/dev/null
  slapadd -n 0 -F "$slapd_d" -l "$export_ldif" 2>/dev/null || { bad "slapadd failed"; cp -a "$backup" "$slapd_d"; systemctl start "$svc"; set -e; return; }
  local owner="ldap"; id symas-openldap >/dev/null 2>&1 && owner="symas-openldap"
  chown -R "${owner}:${owner}" "$slapd_d" 2>/dev/null; restorecon -Rv "$slapd_d" 2>/dev/null
  systemctl start "$svc" 2>/dev/null; sleep 3
  rm -f "$export_ldif"
  ok "Checksums rebuilt (backup at ${backup})"
  set -e
}

fix_syncrepl_tls() {
  local role="$1"
  [[ "$role" != "replica" ]] && { skip "Not replica — skipping syncrepl fix"; return; }
  section "Fix: Syncrepl TLS"
  set +e
  local db=$(db_dn)
  local cfg=$(ldapi_search "$db" -s base -LLL olcSyncrepl 2>/dev/null | tr -d '\n' || true)
  if echo "$cfg" | grep -qi "starttls=yes"; then ok "Syncrepl already uses StartTLS"; set -e; return; fi
  warn "Syncrepl missing starttls=yes — fixing"
  local provider=$(echo "$cfg" | grep -oP 'provider=\K[^ ]+' | head -1 || echo "ldap://${MASTER_IP:-master}")
  local binddn=$(echo "$cfg" | grep -oP 'binddn="\K[^"]+' | head -1 || echo "${REPL_DN}")
  local creds=$(echo "$cfg" | grep -oP 'credentials="?\K[^" ]+' | head -1 || echo "${REPL_PW}")
  local base=$(echo "$cfg" | grep -oP 'searchbase="\K[^"]+' | head -1 || echo "${BASE_DN}")
  local rid=$(echo "$cfg" | grep -oP 'rid=\K[0-9]+' | head -1 || echo "101")
  ldapi_modify <<LDIF 2>/dev/null || true
dn: ${db}
changetype: modify
replace: olcSyncrepl
olcSyncrepl: {0}rid=${rid} provider=${provider} bindmethod=simple binddn="${binddn}" credentials=${creds} searchbase="${base}" type=refreshAndPersist retry="5 5 300 +" timeout=1 starttls=yes tls_reqcert=never interval=00:00:00:10
LDIF
  ok "Syncrepl updated to StartTLS"
  systemctl restart "$(find_service)" 2>/dev/null; sleep 3
  set -e
}

fix_ppolicy() {
  section "Fix: Password Policy"
  set +e
  if ! ldapi_search "cn=config" -s sub "(olcModuleLoad=ppolicy.la)" dn 2>/dev/null | grep -q "^dn:"; then
    ldapi_modify <<LDIF 2>/dev/null || true
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: ppolicy.la
LDIF
  fi
  if ! has_overlay "ppolicy"; then
    ldapi_add <<LDIF 2>/dev/null || true
dn: olcOverlay=ppolicy,$(db_dn)
objectClass: olcOverlayConfig
objectClass: olcPPolicyConfig
olcOverlay: ppolicy
olcPPolicyDefault: cn=default,ou=Policies,${BASE_DN}
olcPPolicyHashCleartext: TRUE
LDIF
  fi
  ok "ppolicy fixed"
  set -e
}

fix_indices() {
  section "Fix: Syncrepl Indices"
  set +e
  local db=$(db_dn) idx=$(ldapi_search "$db" -s base -LLL olcDbIndex 2>/dev/null || true)
  if echo "$idx" | grep -q "entryUUID" && echo "$idx" | grep -q "entryCSN"; then
    ok "Indices present"; set -e; return
  fi
  ldapi_modify <<LDIF 2>/dev/null || true
dn: ${db}
changetype: modify
add: olcDbIndex
olcDbIndex: entryUUID eq
-
add: olcDbIndex
olcDbIndex: entryCSN eq
LDIF
  ok "Indices added"
  set -e
}

fix_syncprov() {
  local role="$1"
  [[ "$role" != "master" ]] && { skip "Not master — skipping syncprov"; return; }
  section "Fix: Syncprov Overlay"
  set +e
  if ! ldapi_search "cn=config" -s sub "(olcModuleLoad=syncprov.la)" dn 2>/dev/null | grep -q "^dn:"; then
    ldapi_modify <<LDIF 2>/dev/null || true
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: syncprov.la
LDIF
  fi
  if ! has_overlay "syncprov"; then
    ldapi_add <<LDIF 2>/dev/null || true
dn: olcOverlay=syncprov,$(db_dn)
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 100
LDIF
  fi
  ok "Syncprov fixed"
  set -e
}

fix_readonly() {
  local role="$1"
  [[ "$role" != "replica" ]] && { skip "Not replica — skipping readonly"; return; }
  section "Fix: Readonly + UpdateRef"
  set +e
  local db=$(db_dn)
  ldapi_modify <<LDIF 2>/dev/null || true
dn: ${db}
changetype: modify
replace: olcReadOnly
olcReadOnly: TRUE
LDIF
  ldapi_modify <<LDIF 2>/dev/null || true
dn: ${db}
changetype: modify
replace: olcUpdateRef
olcUpdateRef: ldap://${MASTER_IP:-master}
LDIF
  ok "Replica readonly fixed"
  set -e
}

fix_accesslog_size() {
  local role="$1"
  [[ "$role" != "master" ]] && { skip "Not master — skipping accesslog fix"; return; }
  section "Fix: Accesslog DB Size"
  set +e
  local adb=$(ldapi_search "cn=config" -s sub "(olcDatabase=accesslog)" dn 2>/dev/null | awk '/^dn: /{print $2; exit}')
  [[ -z "$adb" ]] && { skip "No accesslog DB"; set -e; return; }
  ldapi_modify <<LDIF 2>/dev/null || true
dn: ${adb}
changetype: modify
replace: olcDbMaxSize
olcDbMaxSize: 2147483648
LDIF
  ok "Accesslog DB maxsize set to 2GB"
  set -e
}
