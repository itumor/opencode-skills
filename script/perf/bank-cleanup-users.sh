#!/usr/bin/env bash
# bank-cleanup-users.sh — Remove bulk-loaded users after perf testing
# Deletes all users matching uid=userNNNNNNN and uid=churnNNNNNNN under ou=Users
# Usage: bash bank-cleanup-users.sh
#   --dry-run   Preview only (count users, show commands)
#   --yes       Skip confirmation prompt
#
# Requires simple_bind with TLS: server has olcSecurity: simple_bind=128
# Uses ldaps://localhost:636. No root required.
set -euo pipefail

BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_PW="${BANK_ADMIN_PW:-TheN1le1}"
ADMIN_DN="cn=admin,${BASE_DN}"
URI="ldaps://localhost:636"

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH:-/usr/bin}"
export LDAPTLS_REQCERT=never

DRY_RUN=0
SKIP_CONFIRM=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --yes|-y) SKIP_CONFIRM=1 ;;
    esac
done

log()  { echo "[cleanup] $*"; }

ldap_query() {
    ldapsearch -x -H "${URI}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" \
        -b "ou=Users,${BASE_DN}" -s sub \
        '(|(uid=user*)(uid=churn*))' dn -o ldif-wrap=no "$@" 2>/dev/null
}

count_dns() { grep '^dn: ' | wc -l | tr -d ' '; }

# ============================================================
# Count current users
# ============================================================
log "Counting users matching perf test pattern..."
PERF_USERS=$(ldap_query | count_dns)
TOTAL=$(ldapsearch -x -H "${URI}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" \
    -b "ou=Users,${BASE_DN}" -s sub '(objectClass=inetOrgPerson)' dn -o ldif-wrap=no 2>/dev/null | count_dns)

log "Total users under ou=Users: ${TOTAL}"
log "Perf-test users (uid=user*/uid=churn*): ${PERF_USERS}"

if [[ "${PERF_USERS}" -eq 0 ]]; then
    log "No perf test users found. Nothing to clean up."
    exit 0
fi

# ============================================================
# Preview / confirm
# ============================================================
if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "=== DRY RUN — no users will be deleted ==="
    log "Would delete ${PERF_USERS} users."
    log "Exact DNs that would be deleted:"
    ldap_query 2>/dev/null | awk '/^dn: / {print "  " $2}'
    log ""
    log "To actually delete: bash bank-cleanup-users.sh"
    exit 0
fi

echo ""
echo "WARNING: About to delete ${PERF_USERS} perf-test users from ou=Users,${BASE_DN}"
echo "This will remove users matching uid=user* and uid=churn* patterns."
echo "Non-perf users (with different uid patterns) will NOT be affected."
echo ""

if [[ "${SKIP_CONFIRM}" -eq 0 ]]; then
    read -rp "Type 'yes' to confirm: " CONFIRM
    if [[ "${CONFIRM}" != "yes" ]]; then
        log "Aborted by user."
        exit 0
    fi
fi

# ============================================================
# Delete via ldapdelete
# ============================================================
log "Deleting ${PERF_USERS} entries..."

DN_LIST=$(ldap_query | awk '/^dn: / {print $2}')
DELETED=0
FAILED=0

while IFS= read -r dn; do
    [[ -z "${dn}" ]] && continue
    if ldapdelete -x -H "${URI}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" "${dn}" 2>&1; then
        DELETED=$((DELETED + 1))
    else
        FAILED=$((FAILED + 1))
        log "  FAILED to delete: ${dn}"
    fi
    if [[ $((DELETED % 100)) -eq 0 ]] && [[ "${DELETED}" -gt 0 ]]; then
        log "  Progress: ${DELETED}/${PERF_USERS} deleted..."
    fi
done <<< "${DN_LIST}"

log "=== Cleanup complete ==="
log "Deleted: ${DELETED}, Failed: ${FAILED}"

# ============================================================
# Verify
# ============================================================
REMAINING=$(ldap_query | grep -c '^dn: ' || echo 0)
REMAINING=$(ldap_query | count_dns)
log "Remaining perf users: ${REMAINING}"
if [[ "${REMAINING}" -eq 0 ]]; then
    log "All perf users cleaned up!"
else
    log "Some users remain — re-run cleanup or check manually."
    ldap_query 2>/dev/null | awk '/^dn: / {print "  " $2}'
fi
