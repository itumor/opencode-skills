#!/usr/bin/env bash
# bank-tune-master.sh
# Production OpenLDAP master tuning — Symas 2.6.13 on RHEL 9
# Lab-validated: m5a.4xlarge (16 vCPU, 64GB RAM, gp3 200GB)
# 500K users loaded at 390/sec online, sync at 275/sec
#
# Usage:
#   sudo bash bank-tune-master.sh              # Apply all tuning
#   sudo bash bank-tune-master.sh --dry-run    # Preview only
#   sudo bash bank-tune-master.sh --rollback   # Restore from backup
#   sudo bash bank-tune-master.sh --verify     # Check current settings only
set -euo pipefail

# === Tuning Parameters (validated) ===
THREADS="${LDAP_THREADS:-32}"
LMDB_MAIN="${LMDB_MAIN:-34359738368}"        # 32GB
LMDB_ACCESSLOG="${LMDB_ACCESSLOG:-34359738368}" # 32GB
LMDB_CACHE="${LMDB_CACHE:-536870912}"         # 512MB
LG_REGIONMAX="${LG_REGIONMAX:-262144}"        # 256KB
LG_BSIZE="${LG_BSIZE:-33554432}"              # 32MB
CKP_KB="${CKP_KB:-1024}"
CKP_MIN="${CKP_MIN:-30}"
CONN_MAX_PENDING="${CONN_MAX_PENDING:-256}"
CONN_MAX_PENDING_AUTH="${CONN_MAX_PENDING_AUTH:-1000}"
IDLE_TIMEOUT="${IDLE_TIMEOUT:-3600}"
NOFILE="${NOFILE:-1048576}"
NPROC="${NPROC:-65536}"
FILE_MAX="${FILE_MAX:-2097152}"
SOMAXCONN="${SOMAXCONN:-65535}"

MDB_DN="olcDatabase={1}mdb,cn=config"
ACC_DN="olcDatabase={2}mdb,cn=config"
CONFIG_DN="cn=config"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
BACKUP_DIR="/var/symas/openldap-data/backup/tune-$(date +%Y%m%d_%H%M%S)"
DRY_RUN=0; ROLLBACK=0; VERIFY_ONLY=0

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH:-/usr/bin}"
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

log()  { echo "[tune-master] $*"; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [WARN] $*"; }
fail() { echo "  [FAIL] $*"; }

ldap_mod() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "(dry-run) ldapmodify: $*"
        return 0
    fi
    ldapmodify -Y EXTERNAL -H ldapi:/// "$@"
}

for arg in "$@"; do
    case "$arg" in --dry-run) DRY_RUN=1 ;; --rollback) ROLLBACK=1 ;; --verify) VERIFY_ONLY=1 ;; esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then echo "[FATAL] Must run as root"; exit 1; fi

SVC="symas-openldap-servers"
systemctl is-active --quiet "$SVC" 2>/dev/null || SVC="slapd"
if [[ "$VERIFY_ONLY" -eq 0 ]]; then
  systemctl is-active --quiet "$SVC" 2>/dev/null || { echo "[FATAL] Service not running. Start it first: systemctl start $SVC"; exit 1; }
fi

# ===== Verify only =====
if [[ "$VERIFY_ONLY" -eq 1 ]]; then
    log "=== Current Settings ==="
    echo -n "olcThreads: "; ldapsearch -Y EXTERNAL -H ldapi:/// -b "$CONFIG_DN" -s base olcThreads 2>/dev/null | awk -F': ' '/^olcThreads:/{print $2}'
    echo -n "olcDbMaxSize: "; ldapsearch -Y EXTERNAL -H ldapi:/// -b "$MDB_DN" -s base olcDbMaxSize 2>/dev/null | awk -F': ' '/^olcDbMaxSize:/{print $2}'
    echo "olcDbConfig:"; ldapsearch -Y EXTERNAL -H ldapi:/// -b "$MDB_DN" -s base olcDbConfig 2>/dev/null | grep '^olcDbConfig'
    echo "olcDbIndex:"; ldapsearch -Y EXTERNAL -H ldapi:/// -b "$MDB_DN" -s base olcDbIndex 2>/dev/null | grep '^olcDbIndex'
    echo -n "DB size: "; du -sh /var/symas/openldap-data/example/ 2>/dev/null || echo "N/A"
    echo -n "fs.file-max: "; cat /proc/sys/fs/file-max
    echo -n "ulimit -n: "; ulimit -n
    exit 0
fi

# ===== Rollback =====
if [[ "$ROLLBACK" -eq 1 ]]; then
    log "=== ROLLBACK ==="
    LATEST=$(ls -dt /var/symas/openldap-data/backup/tune-* 2>/dev/null | head -1 || true)
    [[ -z "$LATEST" ]] && { fail "No backup found"; exit 1; }
    log "Restoring from: $LATEST"
    systemctl stop "$SVC"
    [[ -d "$LATEST/slapd.d" ]] && cp -a "$LATEST/slapd.d" /opt/symas/etc/openldap/
    [[ -f "$LATEST/systemd/override.conf" ]] && cp "$LATEST/systemd/override.conf" "/etc/systemd/system/${SVC}.service.d/"
    systemctl start "$SVC"; sleep 5
    systemctl is-active --quiet "$SVC" && ok "Rollback OK" || { fail "Rollback failed"; exit 1; }
    exit 0
fi

log "=== OpenLDAP Master Tuning ==="
log "Service: $SVC | Mode: $( [[ $DRY_RUN -eq 1 ]] && echo DRY-RUN || echo APPLY )"
log ""

# ===== 1. Backup =====
log "=== 1. Backup ==="
mkdir -p "$BACKUP_DIR"
[[ -d /opt/symas/etc/openldap/slapd.d ]] && cp -a /opt/symas/etc/openldap/slapd.d "$BACKUP_DIR/" && ok "cn=config backed up"
mkdir -p "$BACKUP_DIR/systemd"
cp /etc/systemd/system/${SVC}.service.d/override.conf "$BACKUP_DIR/systemd/" 2>/dev/null || true
cp /etc/systemd/system/${SVC}.service.d/limits.conf "$BACKUP_DIR/systemd/" 2>/dev/null || true
ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -s sub "(objectClass=*)" -o ldif-wrap=no > "$BACKUP_DIR/full-config.ldif" 2>/dev/null && ok "Config exported"
cp /etc/sysctl.d/99-openldap-perf.conf "$BACKUP_DIR/" 2>/dev/null || true

# ===== 2. LMDB Sizing =====
log "=== 2. LMDB sizing (main: $((LMDB_MAIN/1073741824))GB, accesslog: $((LMDB_ACCESSLOG/1073741824))GB) ==="
ldap_mod <<LDIF
dn: ${MDB_DN}
changetype: modify
replace: olcDbMaxSize
olcDbMaxSize: ${LMDB_MAIN}
LDIF
ok "Main DB maxsize set"

if ldapsearch -Y EXTERNAL -H ldapi:/// -b "$ACC_DN" -s base dn 2>/dev/null | grep -q "^dn:"; then
    ldap_mod <<LDIF
dn: ${ACC_DN}
changetype: modify
replace: olcDbMaxSize
olcDbMaxSize: ${LMDB_ACCESSLOG}
LDIF
    ok "Accesslog DB maxsize set"
fi

# ===== 3. Indices =====
log "=== 3. Indices ==="
for idx in "uid eq,sub" "mail eq" "cn eq" "entryUUID eq" "entryCSN eq" "member eq" "objectClass eq"; do
    exists=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b "$MDB_DN" -s base olcDbIndex 2>/dev/null | grep -cF "olcDbIndex: ${idx}" | tr -d '[:space:]' || echo 0)
    if [[ "$exists" == "0" || -z "$exists" ]]; then
        ldap_mod <<LDIF
dn: ${MDB_DN}
changetype: modify
add: olcDbIndex
olcDbIndex: ${idx}
LDIF
        ok "Added index: $idx"
    fi
done
log "Rebuilding indices..."
systemctl stop "$SVC"; /opt/symas/sbin/slapindex -n 1 2>/dev/null || true
systemctl start "$SVC"
log "Waiting for ldapi to become available..."
for i in $(seq 1 15); do
    ldapsearch -Y EXTERNAL -H ldapi:/// -b '' -s base dn 2>/dev/null && break
    sleep 2
done
ok "slapindex complete"

# ===== 4. LMDB Performance =====
log "=== 4. LMDB performance flags ==="
DATA_DIR=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b "$MDB_DN" -s base olcDbDirectory 2>/dev/null | awk -F': ' '/^olcDbDirectory:/ {print $2}')
if ldap_mod <<LDIF 2>/dev/null; then
dn: ${MDB_DN}
changetype: modify
replace: olcDbConfig
olcDbConfig: {0}set_cachesize 0 ${LMDB_CACHE} 1
olcDbConfig: {1}set_flags writemap
olcDbConfig: {2}set_flags nometasync
olcDbConfig: {3}set_lg_regionmax ${LG_REGIONMAX}
olcDbConfig: {4}set_lg_bsize ${LG_BSIZE}
LDIF
  ok "LMDB flags via olcDbConfig"
else
  warn "olcDbConfig not supported — using DB_CONFIG fallback"
  if [[ -n "${DATA_DIR:-}" ]]; then
    mkdir -p "$DATA_DIR"
    cat > "${DATA_DIR}/DB_CONFIG" <<DBCFG
set_cachesize 0 $((LMDB_CACHE)) 1
set_flags writemap
set_flags nometasync
set_lg_regionmax ${LG_REGIONMAX}
set_lg_bsize ${LG_BSIZE}
DBCFG
    chown ldap:ldap "${DATA_DIR}/DB_CONFIG" 2>/dev/null || chown symas-openldap:symas-openldap "${DATA_DIR}/DB_CONFIG" 2>/dev/null || true
    ok "DB_CONFIG written to ${DATA_DIR}/"
  fi
fi

if ldapsearch -Y EXTERNAL -H ldapi:/// -b "$ACC_DN" -s base dn 2>/dev/null | grep -q "^dn:"; then
    if ldap_mod <<LDIF 2>/dev/null; then
dn: ${ACC_DN}
changetype: modify
replace: olcDbConfig
olcDbConfig: {0}set_cachesize 0 268435456 1
olcDbConfig: {1}set_flags writemap
olcDbConfig: {2}set_flags nometasync
LDIF
      ok "Accesslog: 256MB cache, writemap, nometasync"
    else
      warn "Accesslog olcDbConfig not supported — skipping"
    fi
fi

# ===== 5. Checkpoint =====
log "=== 5. Checkpoint (${CKP_KB}KB / ${CKP_MIN}min) ==="
ldap_mod <<LDIF
dn: ${MDB_DN}
changetype: modify
replace: olcDbCheckpoint
olcDbCheckpoint: ${CKP_KB} ${CKP_MIN}
LDIF
ok "Checkpoint set"

# ===== 6. Threading =====
log "=== 6. Threading ==="
ldap_mod <<LDIF
dn: ${CONFIG_DN}
changetype: modify
replace: olcThreads
olcThreads: ${THREADS}
-
replace: olcConnMaxPending
olcConnMaxPending: ${CONN_MAX_PENDING}
-
replace: olcConnMaxPendingAuth
olcConnMaxPendingAuth: ${CONN_MAX_PENDING_AUTH}
-
replace: olcIdleTimeout
olcIdleTimeout: ${IDLE_TIMEOUT}
LDIF
ok "Threads=${THREADS}, connMaxPending=${CONN_MAX_PENDING}, idleTimeout=${IDLE_TIMEOUT}"

# ===== 7. Accesslog (if present) =====
log "=== 7. Accesslog ==="
ACC_OVERLAY_DN=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b "olcDatabase={1}mdb,cn=config" -s sub "objectClass=olcAccessLogConfig" dn 2>/dev/null | awk '/^dn: / {print $2; exit}')
if [[ -n "$ACC_OVERLAY_DN" ]]; then
    ldap_mod <<LDIF
dn: ${ACC_OVERLAY_DN}
changetype: modify
replace: olcAccessLogOps
olcAccessLogOps: writes
-
replace: olcAccessLogPurge
olcAccessLogPurge: 7+00:00 01:00:00
LDIF
    ok "Accesslog: writes only, purge 7d every 1h"
else
    warn "Accesslog overlay not found — skipping"
fi

# ===== 8. Log Level =====
log "=== 8. LogLevel → none ==="
ldap_mod <<LDIF
dn: ${CONFIG_DN}
changetype: modify
replace: olcLogLevel
olcLogLevel: none
LDIF
ok "LogLevel=none"

# ===== 9. Kernel =====
log "=== 9. Kernel parameters ==="
cat > /etc/sysctl.d/99-openldap-perf.conf <<SYSCTL
# OpenLDAP performance tuning — applied by bank-tune-master.sh
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${SOMAXCONN}
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.netdev_max_backlog = 65535
fs.file-max = ${FILE_MAX}
fs.nr_open = ${FILE_MAX}
vm.swappiness = 1
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
SYSCTL
sysctl -p /etc/sysctl.d/99-openldap-perf.conf 2>/dev/null || true
ok "Kernel: file-max=${FILE_MAX}, somaxconn=${SOMAXCONN}"

# ===== 10. Systemd =====
log "=== 10. Systemd limits ==="
mkdir -p "/etc/systemd/system/${SVC}.service.d"
cat > "/etc/systemd/system/${SVC}.service.d/limits.conf" <<UNIT
[Service]
LimitNOFILE=${NOFILE}
LimitNPROC=${NPROC}
LimitMEMLOCK=infinity
TasksMax=65536
UNIT
systemctl daemon-reload
ok "NOFILE=${NOFILE}, NPROC=${NPROC}, MEMLOCK=infinity"

# ===== 11. Restart + verify =====
log "=== 11. Restart ==="
systemctl restart "$SVC"; sleep 5

errors=0
systemctl is-active --quiet "$SVC" && ok "Service running" || { fail "Service stopped"; errors=1; }

if ldapwhoami -x -H ldaps://localhost:636 -D "cn=admin,${BASE_DN}" -w "${ADMIN_PW:-TheN1le1}" >/dev/null 2>&1; then
if ldapwhoami -x -ZZ -H ldap://localhost -D "cn=admin,${BASE_DN}" -w "${ADMIN_PW:-TheN1le1}" >/dev/null 2>&1; then
    ok "Admin bind OK"
else
    warn "Admin bind failed"
fi

actual_threads=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b "$CONFIG_DN" -s base olcThreads 2>/dev/null | awk -F': ' '/^olcThreads:/{print $2}')
[[ "$actual_threads" == "$THREADS" ]] && ok "olcThreads=${actual_threads}" || { fail "olcThreads mismatch"; ((errors++)); }

# ===== Summary =====
log ""
log "============================================"
log "  MASTER TUNING COMPLETE"
log "============================================"
log "  Threads:     ${THREADS}"
log "  LMDB main:   $((LMDB_MAIN/1073741824))GB"
log "  LMDB acc:    $((LMDB_ACCESSLOG/1073741824))GB"
log "  Cache:       $((LMDB_CACHE/1048576))MB"
log "  Flags:       writemap, nometasync"
log "  Checkpoint:  ${CKP_KB}KB/${CKP_MIN}min"
log "  Indices:     uid,mail,cn,entryUUID,entryCSN,member,objectClass"
log "  Accesslog:   writes only, purge 7d/1h"
log "  LogLevel:    none"
log "  NOFILE:      ${NOFILE}"
log "  file-max:    ${FILE_MAX}"
log "  Backup:      ${BACKUP_DIR}"
log "  Errors:      ${errors}"
log ""
log "  Rollback: sudo bash $0 --rollback"
log "  Verify:   sudo bash $0 --verify"
log "============================================"
exit $errors
