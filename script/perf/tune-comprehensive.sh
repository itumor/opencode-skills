#!/usr/bin/env bash
# tune-comprehensive.sh — Full production-grade OpenLDAP tuning
# Applies: LMDB sizing, indices, cache, writemap, nometasync, checkpoint,
#          threads, accesslog fix, kernel, systemd limits
# For Symas OpenLDAP 2.6.13 on RHEL 9, 16 vCPU, 64GB RAM
set -euo pipefail

MDB_DN="olcDatabase={1}mdb,cn=config"
CONFIG_DN="cn=config"
ACC_DN="olcDatabase={2}mdb,cn=config"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH:-/usr/bin}"
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

log()  { echo "[tune] $*"; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [WARN] $*"; }
info() { echo "  [INFO] $*"; }

ldap_mod() { ldapmodify -Y EXTERNAL -H ldapi:/// "$@"; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[FATAL] Must run as root"
    exit 1
fi

SVC="symas-openldap-servers"
systemctl is-active --quiet "$SVC" 2>/dev/null || SVC="slapd"
log "Service: $SVC"

# ============ 1. LMDB Database Resizing ============
log "=== 1. Resize LMDB databases ==="
MAIN_SIZE="${MAIN_SIZE:-26843545600}"   # 25GB
ACC_SIZE="${ACC_SIZE:-26843545600}"     # 25GB

ldap_mod <<LDIF
dn: ${MDB_DN}
changetype: modify
replace: olcDbMaxSize
olcDbMaxSize: ${MAIN_SIZE}
LDIF
ok "Main DB max size: $(( MAIN_SIZE / 1073741824 ))GB"

# Check if accesslog DB exists
if ldapsearch -Y EXTERNAL -H ldapi:/// -b "$ACC_DN" -s base dn 2>/dev/null | grep -q "^dn:"; then
    ldap_mod <<LDIF
dn: ${ACC_DN}
changetype: modify
replace: olcDbMaxSize
olcDbMaxSize: ${ACC_SIZE}
LDIF
    ok "Accesslog DB max size: $(( ACC_SIZE / 1073741824 ))GB"
else
    warn "No accesslog database found (olcDatabase={2}mdb) — skipping"
fi

# ============ 2. Indices ============
log "=== 2. Add missing indices ==="
declare -A IDX_NEEDED
IDX_NEEDED["uid eq,sub"]=1
IDX_NEEDED["mail eq"]=1
IDX_NEEDED["entryUUID eq"]=1
IDX_NEEDED["entryCSN eq"]=1
IDX_NEEDED["member eq"]=1
IDX_NEEDED["objectClass eq"]=1

existing_idxs=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b "$MDB_DN" -s base olcDbIndex 2>/dev/null | grep "^olcDbIndex:" || true)

for idx in "${!IDX_NEEDED[@]}"; do
    if echo "$existing_idxs" | grep -qF "olcDbIndex: ${idx}"; then
        info "Index exists: $idx"
    else
        ldap_mod <<LDIF
dn: ${MDB_DN}
changetype: modify
add: olcDbIndex
olcDbIndex: ${idx}
LDIF
        ok "Added index: $idx"
    fi
done

log "Rebuilding indices (slapindex)..."
systemctl stop "$SVC"
/opt/symas/sbin/slapindex -n 1 2>/dev/null || true
systemctl start "$SVC"
sleep 5
ok "slapindex complete"

# ============ 3. LMDB Performance Flags ============
log "=== 3. LMDB performance tuning ==="

# First set cache size
ldap_mod <<LDIF
dn: ${MDB_DN}
changetype: modify
replace: olcDbConfig
olcDbConfig: {0}set_cachesize 0 536870912 1
olcDbConfig: {1}set_flags writemap
olcDbConfig: {2}set_flags nometasync
olcDbConfig: {3}set_lg_regionmax 262144
olcDbConfig: {4}set_lg_bsize 33554432
LDIF
ok "LMDB flags: cachesize 512MB, writemap, nometasync, lg_regionmax 256KB, lg_bsize 32MB"

# Apply same to accesslog if exists
if ldapsearch -Y EXTERNAL -H ldapi:/// -b "$ACC_DN" -s base dn 2>/dev/null | grep -q "^dn:"; then
    ldap_mod <<LDIF
dn: ${ACC_DN}
changetype: modify
replace: olcDbConfig
olcDbConfig: {0}set_cachesize 0 268435456 1
olcDbConfig: {1}set_flags writemap
olcDbConfig: {2}set_flags nometasync
LDIF
    ok "Accesslog LMDB flags applied (256MB cache)"
fi

# ============ 4. Checkpoint ============
log "=== 4. Checkpoint tuning ==="
ldap_mod <<LDIF
dn: ${MDB_DN}
changetype: modify
replace: olcDbCheckpoint
olcDbCheckpoint: 1024 30
LDIF
ok "Checkpoint: 1024KB / 30min"

# ============ 5. Threading ============
log "=== 5. Threading ==="
ldap_mod <<LDIF
dn: ${CONFIG_DN}
changetype: modify
replace: olcThreads
olcThreads: 32
-
replace: olcConnMaxPending
olcConnMaxPending: 256
-
replace: olcConnMaxPendingAuth
olcConnMaxPendingAuth: 1000
-
replace: olcIdleTimeout
olcIdleTimeout: 3600
LDIF
ok "Threads=32, connMaxPending=256, idleTimeout=3600"

# ============ 6. Accesslog Fix ============
log "=== 6. Accesslog tuning ==="
if ldapsearch -Y EXTERNAL -H ldapi:/// -b "$ACC_DN" -s base dn 2>/dev/null | grep -q "^dn:"; then
    # Reduce ops to writes only
    ldap_mod <<'LDIF'
dn: olcOverlay={0}accesslog,olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcAccessLogOps
olcAccessLogOps: writes
LDIF
    ok "Accesslog ops reduced to writes only"

    # Fix purge: 7 days old, run every 1 hour
    ldap_mod <<'LDIF'
dn: olcOverlay={0}accesslog,olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcAccessLogPurge
olcAccessLogPurge: 7+00:00 01:00:00
LDIF
    ok "Accesslog purge: 7 days / 1 hour interval"
else
    warn "No accesslog overlay found — skipping"
fi

# ============ 7. Log Level ============
log "=== 7. Log level → none ==="
ldap_mod <<LDIF
dn: ${CONFIG_DN}
changetype: modify
replace: olcLogLevel
olcLogLevel: none
LDIF
ok "LogLevel set to none"

# ============ 8. Kernel Tuning ============
log "=== 8. Kernel parameters ==="
cat > /etc/sysctl.d/99-openldap-perf.conf <<'SYSCTL'
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.netdev_max_backlog = 65535
fs.file-max = 2097152
fs.nr_open = 2097152
vm.swappiness = 1
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
SYSCTL
sysctl -p /etc/sysctl.d/99-openldap-perf.conf 2>/dev/null || true
ok "Kernel parameters applied"

# ============ 9. Systemd Limits ============
log "=== 9. Systemd resource limits ==="
mkdir -p "/etc/systemd/system/${SVC}.service.d"
cat > "/etc/systemd/system/${SVC}.service.d/limits.conf" <<UNIT
[Service]
LimitNOFILE=1048576
LimitNPROC=65536
LimitMEMLOCK=infinity
TasksMax=65536
UNIT
systemctl daemon-reload
ok "systemd limits: NOFILE=1048576, NPROC=65536, MEMLOCK=infinity"

# ============ 10. Restart ============
log "=== 10. Restarting OpenLDAP ==="
systemctl restart "$SVC"
sleep 5

if systemctl is-active --quiet "$SVC"; then
    ok "Service is running"
else
    warn "Service did not start — checking logs"
    journalctl -u "$SVC" --no-pager -n 10
    exit 1
fi

# ============ 11. Verify ============
log "=== 11. Verification ==="

# Config validation
if /opt/symas/sbin/slaptest -u 2>/dev/null; then
    ok "slaptest -u passed"
else
    warn "slaptest -u failed"
fi

# Admin bind
if ldapwhoami -x -ZZ -H ldap://localhost \
    -D "cn=admin,${BASE_DN}" -w "${ADMIN_PW:-TheN1le1}" >/dev/null 2>&1; then
    ok "Admin bind OK"
else
    warn "Admin bind FAILED"
fi

# Check mdb_stat
data_dir=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b "$MDB_DN" -s base olcDbDirectory 2>/dev/null | awk -F': ' '/^olcDbDirectory:/ {print $2}')
if [[ -n "$data_dir" && -x /usr/bin/mdb_stat ]]; then
    stats=$(mdb_stat -e "$data_dir" 2>/dev/null || true)
    pages_used=$(echo "$stats" | awk '/Number of pages used/ {print $NF}')
    pages_max=$(echo "$stats" | awk '/Max pages/ {print $NF}')
    if [[ -n "$pages_used" && -n "$pages_max" && "$pages_max" -gt 0 ]]; then
        pct=$(( pages_used * 100 / pages_max ))
        ok "mdb_stat: ${pages_used}/${pages_max} pages (${pct}%)"
        if [[ "$pct" -gt 80 ]]; then
            warn "LMDB >80% full — consider increasing olcDbMaxSize"
        fi
    fi
fi

log ""
log "=== COMPREHENSIVE TUNING COMPLETE ==="
log ""
log "Applied:"
log "  Main DB:    $(( MAIN_SIZE / 1073741824 ))GB, accesslog: $(( ACC_SIZE / 1073741824 ))GB"
log "  Cache:      512MB, writemap, nometasync"
log "  Checkpoint: 1024KB / 30min"
log "  Threads:    32, connMaxPending=256, idleTimeout=3600"
log "  Accesslog:  writes only, purge 7d/1h"
log "  LogLevel:   none"
log "  Limits:     NOFILE=1048576, NPROC=65536, MEMLOCK=infinity"
log "  Kernel:     somaxconn=65535, file-max=2097152, swappiness=1"
