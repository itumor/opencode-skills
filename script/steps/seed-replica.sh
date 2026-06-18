#!/usr/bin/env bash
# steps/seed-replica.sh — Seed empty replica DB from master
# Usage: sudo MASTER_IP=10.0.0.1 ADMIN_PW=secret REPL_PW=replpass bash steps/seed-replica.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/ldap-ops.sh"
require_root; setup_path
: "${MASTER_IP:?MASTER_IP required}" "${ADMIN_PW:?ADMIN_PW required}"
banner "Seed Replica DB from Master"

section "Pull data from master"
export_ldif="/tmp/master-export-$(date +%Y%m%d).ldif"
LDAPTLS_REQCERT=never ldapsearch -o ldif-wrap=no -x -ZZ \
  -H "ldap://${MASTER_IP}" -D "${REPL_DN}" -w "${REPL_PW}" \
  -b "${BASE_DN}" -s sub "(objectClass=*)" '*' '+' > "$export_ldif" 2>/dev/null
count=$(grep -c "^dn:" "$export_ldif" || echo 0)
ok "Pulled ${count} entries from master"

section "Stop slapd and wipe DB"
svc=$(find_service)
systemctl stop "$svc"
sleep 2
dbdir="/var/symas/openldap-data/example"
rm -f "${dbdir}/data.mdb" "${dbdir}/lock.mdb" 2>/dev/null || true
ok "DB wiped"

section "Import data"
slapadd -b "${BASE_DN}" -l "$export_ldif" 2>/dev/null && ok "slapadd successful" || bad "slapadd failed"
owner="ldap"; id symas-openldap >/dev/null 2>&1 && owner="symas-openldap"
chown -R "${owner}:${owner}" "$dbdir" 2>/dev/null || true
rm -f "$export_ldif"

section "Start slapd"
systemctl start "$svc"
sleep 3
systemctl is-active --quiet "$svc" && ok "$svc started" || bad "$svc failed"

summary
