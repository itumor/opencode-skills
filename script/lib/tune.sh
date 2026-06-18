#!/usr/bin/env bash
# lib/tune.sh — performance tuning (NOFILE, indices, db sizing)

tune() {
  section "Performance Tuning"
  if [[ "${SKIP_TUNE:-0}" == "1" ]]; then skip "Tuning skipped"; return; fi

  local svc=$(find_service)
  local db=$(db_dn)
  set +e

  # NOFILE limit
  local dropin="/etc/systemd/system/${svc}.service.d/override.conf"
  mkdir -p "$(dirname "$dropin")" 2>/dev/null
  cat > "$dropin" <<EOF 2>/dev/null
[Service]
LimitNOFILE=65536
EOF
  systemctl daemon-reload 2>/dev/null
  ok "NOFILE=65536 configured"

  # Syncrepl indices
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
  fi
  ok "Syncrepl indices present"

  # DB maxsize
  local max="${DB_MAXSIZE_GB:-32}"
  local bytes=$((max * 1073741824))
  ldapi_modify <<LDIF 2>/dev/null || true
dn: ${db}
changetype: modify
replace: olcDbMaxSize
olcDbMaxSize: ${bytes}
LDIF
  ok "DB maxsize set to ${max}GB"

  # SLAPD_URLS
  local defs="/etc/default/symas-openldap"
  if [[ -f "$defs" ]] && ! grep -q "ldaps:///" "$defs"; then
    sed -i 's|SLAPD_URLS="ldap:///|SLAPD_URLS="ldap:/// ldaps:///|' "$defs" 2>/dev/null || true
    ok "ldaps:// added to SLAPD_URLS"
  fi

  systemctl daemon-reload 2>/dev/null
  systemctl restart "$svc" 2>/dev/null || true
  sleep 3
  ok "Service restarted after tuning"
  set -e
}
