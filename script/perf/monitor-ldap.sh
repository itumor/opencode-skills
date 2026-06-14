#!/usr/bin/env bash
# monitor-ldap.sh — Real-time OpenLDAP + OS performance monitor
# Usage: bash monitor-ldap.sh <host> <interval_sec> <output_csv>
set -euo pipefail

HOST="${1:-localhost}"
INTERVAL="${2:-5}"
OUTPUT="${3:-/tmp/ldap-monitor.csv}"
ADMIN_DN="${ADMIN_DN:-cn=admin,dc=eab,dc=bank,dc=local}"
ADMIN_PW="${ADMIN_PW:-TheN1le1}"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH:-/usr/bin}"
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

now() { date +%s; }

echo "timestamp,connections_current,connections_total,ops_completed,ops_initiating,bind_ops,search_ops,add_ops,modify_ops,delete_ops,threads_active,threads_max,read_waiters,write_waiters,ldap_entries,cpu_pct,mem_used_pct,disk_await_ms,replica_csn,replica_lag_sec" > "$OUTPUT"

log() { printf '[monitor] %s\n' "$*" >&2; }

get_ldap_metric() {
    local base="$1" attr="$2"
    local val
    val=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H "ldap://${HOST}" \
        -D "$ADMIN_DN" -w "$ADMIN_PW" \
        -b "$base" -s base "$attr" -o ldif-wrap=no 2>/dev/null | \
        awk -F': ' "/^${attr}:/ {print \$2}" | head -1)
    echo "${val:-0}"
}

get_ldap_count() {
    local base="$1" filter="$2"
    local val
    val=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H "ldap://${HOST}" \
        -D "$ADMIN_DN" -w "$ADMIN_PW" \
        -b "$base" -s sub "$filter" dn -o ldif-wrap=no 2>/dev/null | \
        grep -c "^dn:")
    echo "${val:-0}"
}

log "Starting LDAP monitor on ${HOST}, interval=${INTERVAL}s, output=${OUTPUT}"

# Get CSN from master for lag calculation (optional MASTER_IP)
MASTER_IP="${MASTER_IP:-}"
if [[ -n "$MASTER_IP" ]]; then
    log "Monitoring replication lag against master ${MASTER_IP}"
fi

while true; do
    ts=$(now)

    # LDAP cn=Monitor metrics
    connections_current=$(get_ldap_metric "cn=Current,cn=Connections,cn=Monitor" "monitorCounter")
    connections_total=$(get_ldap_metric "cn=Total,cn=Connections,cn=Monitor" "monitorCounter")
    ops_completed=$(get_ldap_metric "cn=Operations,cn=Monitor" "monitorOpCompleted")
    ops_initiating=$(get_ldap_metric "cn=Operations,cn=Monitor" "monitorOpInitiated")
    bind_ops=$(get_ldap_metric "cn=Bind,cn=Operations,cn=Monitor" "monitorOpCompleted")
    search_ops=$(get_ldap_metric "cn=Search,cn=Operations,cn=Monitor" "monitorOpCompleted")
    add_ops=$(get_ldap_metric "cn=Add,cn=Operations,cn=Monitor" "monitorOpCompleted")
    modify_ops=$(get_ldap_metric "cn=Modify,cn=Operations,cn=Monitor" "monitorOpCompleted")
    delete_ops=$(get_ldap_metric "cn=Delete,cn=Operations,cn=Monitor" "monitorOpCompleted")
    threads_active=$(get_ldap_metric "cn=Threads,cn=Monitor" "monitorCounter")
    threads_max=$(get_ldap_metric "cn=Max,cn=Threads,cn=Monitor" "monitorCounter")
    read_waiters=$(get_ldap_metric "cn=Read,cn=Waiters,cn=Monitor" "monitorCounter")
    write_waiters=$(get_ldap_metric "cn=Write,cn=Waiters,cn=Monitor" "monitorCounter")

    # LDAP entry count
    ldap_entries=$(get_ldap_count "$BASE_DN" "(objectClass=inetOrgPerson)")

    # OS metrics
    cpu_pct=$(top -bn1 2>/dev/null | awk '/^%Cpu/ {print 100-$8}' || echo 0)
    mem_used_pct=$(free 2>/dev/null | awk '/^Mem:/ {printf "%.1f", $3/$2*100}' || echo 0)
    disk_await_ms=$(iostat -xz 1 1 2>/dev/null | awk '/nvme|sd|xvd/ {print $10}' | head -1 || echo 0)

    # Replication contextCSN + lag
    replica_csn=""
    replica_lag_sec=0
    if [[ -n "$MASTER_IP" ]]; then
        master_csn=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H "ldap://${MASTER_IP}" \
            -D "$ADMIN_DN" -w "$ADMIN_PW" \
            -b "$BASE_DN" -s base contextCSN -o ldif-wrap=no 2>/dev/null | \
            awk -F': ' '/^contextCSN:/ {print $2}')
        replica_csn=$(LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H "ldap://${HOST}" \
            -D "$ADMIN_DN" -w "$ADMIN_PW" \
            -b "$BASE_DN" -s base contextCSN -o ldif-wrap=no 2>/dev/null | \
            awk -F': ' '/^contextCSN:/ {print $2}')
        if [[ -n "$master_csn" && -n "$replica_csn" ]]; then
            master_ts=$(echo "$master_csn" | sed 's/Z.*//; s/\./ /' | awk '{print $1" "$2}')
            replica_ts=$(echo "$replica_csn" | sed 's/Z.*//; s/\./ /' | awk '{print $1" "$2}')
            if command -v python3 >/dev/null 2>&1; then
                replica_lag_sec=$(python3 -c "
from datetime import datetime
try:
    m=datetime.strptime('$master_ts','%Y%m%d%H%M%S %f')
    r=datetime.strptime('$replica_ts','%Y%m%d%H%M%S %f')
    print(int((m-r).total_seconds()))
except: print(0)
" 2>/dev/null || echo 0)
            fi
        fi
    fi

    echo "${ts},${connections_current},${connections_total},${ops_completed},${ops_initiating},${bind_ops},${search_ops},${add_ops},${modify_ops},${delete_ops},${threads_active},${threads_max},${read_waiters},${write_waiters},${ldap_entries},${cpu_pct},${mem_used_pct},${disk_await_ms},${replica_csn},${replica_lag_sec}" >> "$OUTPUT"

    sleep "$INTERVAL"
done
