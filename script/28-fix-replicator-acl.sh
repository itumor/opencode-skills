#!/usr/bin/env bash
# 28-fix-replicator-acl.sh
# Post-install fix: replace all olcAccess rules on the primary database
# with production ACLs that include the replicator read access.
# This is executed AFTER installation on the replica to fix ACLs.
#
# ACL Rules:
#   {0} userPassword: admin write, ldapi write, mw write, self write, anon auth
#   {1} *: admin write, ldapi write, replicator read
#   {2} Users subtree: mw write
#   {3} *: self read, mw read, replicator read

set -euo pipefail

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH:-/usr/bin}"
[[ -f /etc/profile.d/symas_env.sh ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true

BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
LDAPI_URI="${LDAPI_URI:-ldapi:///}"

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "[FATAL] Must be run as root" >&2; exit 1; }

ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -s base dn >/dev/null 2>&1 \
  || { echo "[FATAL] Cannot access cn=config via ${LDAPI_URI}" >&2; exit 1; }

log "Applying production ACLs for cn=replicator user on olcDatabase={1}mdb,cn=config"

ldapmodify -Y EXTERNAL -H "$LDAPI_URI" <<'EOF'
dn: olcDatabase={1}mdb,cn=config
changetype: modify
delete: olcAccess
-
add: olcAccess
olcAccess: {0}to attrs=userPassword by dn.exact="cn=admin,dc=eab,dc=bank,dc=local" write by sockurl.exact="ldapi:///" write by dn.exact="uid=mw,ou=ServiceAccounts,ou=Systems,dc=eab,dc=bank,dc=local" write by self write by anonymous auth by * none
olcAccess: {1}to * by dn.exact="cn=admin,dc=eab,dc=bank,dc=local" write by sockurl.exact="ldapi:///" write by dn.exact="cn=replicator,dc=eab,dc=bank,dc=local" read by * break
olcAccess: {2}to dn.subtree="ou=Users,dc=eab,dc=bank,dc=local" by dn.exact="uid=mw,ou=ServiceAccounts,ou=Systems,dc=eab,dc=bank,dc=local" write by * break
olcAccess: {3}to * by self read by dn.exact="uid=mw,ou=ServiceAccounts,ou=Systems,dc=eab,dc=bank,dc=local" read by dn.exact="cn=replicator,dc=eab,dc=bank,dc=local" read by * none
EOF

log "Production ACLs applied. cn=replicator now has read access."

# Verify
if ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" \
    -b "olcDatabase={1}mdb,cn=config" -s base -LLL olcAccess 2>/dev/null | grep -q "replicator"; then
  log "Verification: replicator ACL present"
else
  warn "Verification: replicator ACL NOT found — check cn=config"
fi
