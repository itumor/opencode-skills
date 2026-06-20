#!/usr/bin/env bash
# bank-monitor-ldap.sh — Real-time OpenLDAP + system performance monitor
# Usage: bash bank-monitor-ldap.sh [interval_sec] [output_csv]
# Default: 5-second interval, output to /tmp/ldap-monitor.csv
set -euo pipefail

INTERVAL="${1:-5}"
OUTPUT="${2:-/tmp/ldap-monitor.csv}"
ADMIN_DN="${ADMIN_DN:-cn=admin,dc=eab,dc=bank,dc=local}"
ADMIN_PW="${ADMIN_PW:-TheN1le1}"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH:-/usr/bin}"
export LDAPTLS_REQCERT=never

now() { date +%s; }

echo "timestamp,connections_current,connections_total,ops_completed,ops_initiating,bind_ops,search_ops,add_ops,modify_ops,delete_ops,threads_active,threads_max,read_waiters,write_waiters,ldap_entries,cpu_pct,mem_used_pct,disk_await_ms" > "$OUTPUT"

log() { printf '[monitor] %s\n' "$*" >&2; }

get_ldap_metric() {
    local base="$1" attr="$2"
    local val
    val=$(ldapsearch -x -H ldaps://localhost:636 \
        -D "$ADMIN_DN" -w "$ADMIN_PW" \
        -b "$base" -s base "$attr" -o ldif-wrap=no 2>/dev/null | \
        awk -F': ' "/^${attr}:/ {print \$2}" | head -1)
    echo "${val:-0}"
}

get_ldap_count() {
    local base="$1" filter="$2"
    local val
    val=$(ldapsearch -x -H ldaps://localhost:636 \
        -D "$ADMIN_DN" -w "$ADMIN_PW" \
        -b "$base" -s sub "$filter" dn -o ldif-wrap=no 2>/dev/null | \
        grep -c "^dn:")
    echo "${val:-0}"
}

log "Starting LDAP monitor, interval=${INTERVAL}s, output=${OUTPUT}"
log "Press Ctrl+C to stop."

while true; do
    ts=$(now)

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
    ldap_entries=$(get_ldap_count "$BASE_DN" "(objectClass=inetOrgPerson)")

    cpu_pct=$(top -bn1 2>/dev/null | awk '/^%Cpu/ {print 100-$8}' || echo 0)
    mem_used_pct=$(free 2>/dev/null | awk '/^Mem:/ {printf "%.1f", $3/$2*100}' || echo 0)
    disk_await_ms=$(iostat -xz 1 1 2>/dev/null | awk '/nvme|sd|xvd/ {print $10}' | head -1 || echo 0)

    echo "${ts},${connections_current},${connections_total},${ops_completed},${ops_initiating},${bind_ops},${search_ops},${add_ops},${modify_ops},${delete_ops},${threads_active},${threads_max},${read_waiters},${write_waiters},${ldap_entries},${cpu_pct},${mem_used_pct},${disk_await_ms}" >> "$OUTPUT"

    sleep "$INTERVAL"
done
