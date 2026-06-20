#!/usr/bin/env bash
# bank-bulk-load.sh — Generate & bulk-load users into bank OpenLDAP master
# Usage: sudo bash bank-bulk-load.sh [user_count] [password]
# Default: 100000 users with password "Test123!"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_COUNT="${1:-100000}"
PASSWORD="${2:-Test123!}"
BASE_DN="dc=eab,dc=bank,dc=local"
ADMIN_PW="TheN1le1"
MASTER="${MASTER_IP:-172.23.11.236}"
REPLICA="${REPLICA_IP:-172.23.11.237}"

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH:-/usr/bin}"
export LDAPTLS_REQCERT=never

log()  { echo "[$(date +%H:%M:%S)] $*"; }
err()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Must run as root (sudo). Needed for slapadd, chown, systemctl."
    exit 1
fi

log "=== Bank Bulk Load: ${USER_COUNT} users ==="

# ============================================================
# Step 1: Generate LDIF locally
# ============================================================
log "Step 1: Generating ${USER_COUNT}-user LDIF..."
python3 "${SCRIPT_DIR}/bank-gen-ldif.py" "${USER_COUNT}" "${PASSWORD}" "${BASE_DN}" > /tmp/bank-users.ldif
SIZE=$(wc -c < /tmp/bank-users.ldif)
ENTRIES=$(grep -c '^dn: ' /tmp/bank-users.ldif || true)
log "LDIF: ${ENTRIES} entries, $(( SIZE / 1048576 ))MB"

# ============================================================
# Step 2: Stop LDAP
# ============================================================
log "Step 2: Stopping slapd..."
systemctl stop symas-openldap-servers 2>/dev/null || systemctl stop slapd 2>/dev/null || true
sleep 3

# ============================================================
# Step 3: Bulk import via slapadd
# ============================================================
log "Step 3: Running slapadd..."
/opt/symas/sbin/slapadd -n 1 -l /tmp/bank-users.ldif || err "slapadd failed"

# ============================================================
# Step 4: Rebuild indices
# ============================================================
log "Step 4: Running slapindex..."
/opt/symas/sbin/slapindex -n 1 || err "slapindex failed"

# ============================================================
# Step 5: Fix permissions
# ============================================================
log "Step 5: Fixing permissions..."
chown -R ldap:ldap /var/symas/openldap-data/example/ 2>/dev/null || \
    chown -R symas-openldap:symas-openldap /var/symas/openldap-data/example/ 2>/dev/null || true
restorecon -Rv /var/symas/openldap-data/example/ 2>/dev/null || true

# ============================================================
# Step 6: Start LDAP
# ============================================================
log "Step 6: Starting slapd..."
systemctl start symas-openldap-servers 2>/dev/null || systemctl start slapd 2>/dev/null || true
sleep 10

# ============================================================
# Step 7: Verify
# ============================================================
log "Step 7: Verifying..."
COUNT=$(ldapsearch -x -H ldaps://localhost:636 \
    -D "cn=admin,${BASE_DN}" -w "${ADMIN_PW}" \
    -b "${BASE_DN}" -s sub '(objectClass=inetOrgPerson)' dn -o ldif-wrap=no 2>/dev/null | \
    grep -c '^dn: ' || echo 0)
log "Directory has ${COUNT} inetOrgPerson entries"

log "=== Bulk load complete ==="
log "LDIF kept at /tmp/bank-users.ldif (can delete after verification)"
log ""
log "To cleanup: sudo bash bank-cleanup-users.sh"
