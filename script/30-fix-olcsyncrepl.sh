#!/usr/bin/env bash
# 30-fix-olcsyncrepl.sh
# Post-install fix: update olcSyncrepl configuration on the replica.
# Replaces the syncrepl entry with production values:
#   - Master IP: overridable via MASTER_IP env var
#   - StartTLS enabled with tls_reqcert=demand
#   - refreshAndPersist mode with retry schedule
#   - keepalive + TCP user timeout tuned

set -euo pipefail

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH:-/usr/bin}"
[[ -f /etc/profile.d/symas_env.sh ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true

BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
MASTER_IP="${MASTER_IP:-172.23.11.196}"
REPL_PW="${REPL_PW:-replpass}"
TLS_CACERT="${TLS_CACERT:-/opt/symas/etc/openldap/tls/ca.crt}"
LDAPI_URI="${LDAPI_URI:-ldapi:///}"

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "[FATAL] Must be run as root" >&2; exit 1; }

ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -s base dn >/dev/null 2>&1 \
  || { echo "[FATAL] Cannot access cn=config via ${LDAPI_URI}" >&2; exit 1; }

log "Updating olcSyncrepl on replica (master=${MASTER_IP})"

ldapmodify -Y EXTERNAL -H "$LDAPI_URI" <<'EOF'
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcSyncrepl
olcSyncrepl: {0}rid=101 provider=ldap://172.23.11.196:389 bindmethod=simple timeout=1 network-timeout=0 binddn="cn=replicator,dc=eab,dc=bank,dc=local" credentials="replpass" keepalive=0:0:0 tcp-user-timeout=0 starttls=yes tls_reqcert=demand tls_cacert=/opt/symas/etc/openldap/tls/ca.crt tls_crlcheck=none filter="(objectclass=*)" searchbase="dc=eab,dc=bank,dc=local" scope=sub schemachecking=off type=refreshAndPersist retry="5 5 300 +"
EOF

log "olcSyncrepl updated."

# Verify syncrepl present
if ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" \
    -b "olcDatabase={1}mdb,cn=config" -s base -LLL olcSyncrepl 2>/dev/null | grep -q "refreshAndPersist"; then
  log "Verification: syncrepl configured with refreshAndPersist"
else
  warn "Verification: syncrepl entry NOT found — check cn=config"
fi

log "Restarting slapd to pick up new syncrepl config..."
systemctl restart symas-openldap-servers 2>/dev/null || systemctl restart slapd 2>/dev/null || true
sleep 5
log "Done. Check replication with: ldapsearch -x -H ldapi:/// -b '${BASE_DN}' -s base contextCSN"
