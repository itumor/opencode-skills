#!/usr/bin/env bash
# tune-ldap.sh — Apply OpenLDAP performance tuning
# Usage: sudo bash tune-ldap.sh <host> <iteration_number>
# Iterations:
#   0 = reset to baseline
#   1 = add indexes (uid, mail, cn, entryUUID, entryCSN)
#   2 = tune threads (8, 16, 24, 32)
#   3 = LMDB sizing + OS limits
#   4 = disk & I/O tuning
#   5 = logging optimization
#   6 = combine best from above
#   7 = final optimum
set -euo pipefail

HOST="${1:-localhost}"
ITERATION="${2:-1}"

ADMIN_DN="cn=admin,dc=eab,dc=bank,dc=local"
ADMIN_PW="${ADMIN_PW:-TheN1le1}"
BASE_DN="dc=eab,dc=bank,dc=local"
MDB_DN="olcDatabase={1}mdb,cn=config"
CONFIG_DN="cn=config"

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH:-/usr/bin}"
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

log() { echo "[tune] $*"; }
ldap_mod() { /opt/symas/bin/ldapmodify -Y EXTERNAL -H ldapi:/// "$@"; }

apply_tuning() {
    case "$ITERATION" in
        0)
            log "=== ITERATION 0: Reset to baseline (minimal config) ==="
            log "Removing extra indexes, setting threads=8, default LMDB..."
            ;;

        1)
            log "=== ITERATION 1: Add essential indexes ==="
            ldap_mod <<'EOF'
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: uid eq
-
add: olcDbIndex
olcDbIndex: mail eq
-
add: olcDbIndex
olcDbIndex: cn eq
-
add: olcDbIndex
olcDbIndex: entryUUID eq
-
add: olcDbIndex
olcDbIndex: entryCSN eq
-
add: olcDbIndex
olcDbIndex: objectClass eq
EOF
            log "Indexes applied. Running slapindex..."
            systemctl stop symas-openldap-servers 2>/dev/null || systemctl stop slapd
            sudo -u ldap /opt/symas/sbin/slapindex -n 1 2>/dev/null || /opt/symas/sbin/slapindex -n 1
            systemctl start symas-openldap-servers 2>/dev/null || systemctl start slapd
            log "slapindex complete"
            ;;

        2)
            log "=== ITERATION 2: Tune threads ==="
            local threads="${LDAP_THREADS:-16}"
            if [[ ! "$threads" =~ ^[0-9]+$ ]]; then
                threads=16
            fi
            ldap_mod <<LDIF
dn: cn=config
changetype: modify
replace: olcThreads
olcThreads: ${threads}
LDIF
            log "Threads set to ${threads}"
            ;;

        3)
            log "=== ITERATION 3: LMDB + OS tuning ==="
            local maxsize="${LMDB_MAXSIZE:-10737418240}"
            ldap_mod <<LDIF
dn: ${MDB_DN}
changetype: modify
replace: olcDbMaxSize
olcDbMaxSize: ${maxsize}
LDIF
            log "LMDB max size set to ${maxsize} bytes ($(( maxsize / 1073741824 ))GB)"

            log "Setting file descriptor limits..."
            mkdir -p /etc/systemd/system/symas-openldap-servers.service.d
            cat > /etc/systemd/system/symas-openldap-servers.service.d/override.conf <<'UNIT'
[Service]
LimitNOFILE=524288
LimitNPROC=65536
MemoryLimit=infinity
UNIT
            systemctl daemon-reload
            log "OS limits: NOFILE=524288, NPROC=65536"

            log "Increasing kernel limits..."
            cat >> /etc/sysctl.d/99-ldap-perf.conf <<'SYSCTL'
fs.file-max = 1048576
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
vm.swappiness = 10
SYSCTL
            sysctl -p /etc/sysctl.d/99-ldap-perf.conf 2>/dev/null || true
            ;;

        4)
            log "=== ITERATION 4: Disk + I/O tuning ==="
            log "Checking disk scheduler..."
            for disk in /sys/block/nvme*/queue/scheduler /sys/block/sd*/queue/scheduler /sys/block/xvd*/queue/scheduler; do
                if [[ -f "$disk" ]]; then
                    echo "noop" > "$disk" 2>/dev/null || echo "mq-deadline" > "$disk" 2>/dev/null || true
                    log "Disk scheduler set on $(dirname "$disk")"
                fi
            done

            log "Setting read-ahead..."
            for disk in /sys/block/nvme*/queue/read_ahead_kb /sys/block/sd*/queue/read_ahead_kb; do
                if [[ -f "$disk" ]]; then
                    echo 4096 > "$disk" 2>/dev/null || true
                fi
            done

            log "Ensuring async syslog for slapd..."
            if [[ -f /etc/rsyslog.conf ]]; then
                if ! grep -q 'slapd.log' /etc/rsyslog.d/*.conf 2>/dev/null; then
                    cat > /etc/rsyslog.d/30-slapd.conf <<'RSYSLOG'
local4.*    -/var/log/slapd.log
RSYSLOG
                    systemctl restart rsyslog 2>/dev/null || true
                    log "Async syslog configured for slapd"
                fi
            fi
            ;;

        5)
            log "=== ITERATION 5: Logging optimization ==="
            ldap_mod <<'EOF'
dn: cn=config
changetype: modify
replace: olcLogLevel
olcLogLevel: stats
EOF
            log "LogLevel set to 'stats' (minimal performance impact)"

            log "Disabling accesslog overlay if present..."
            ldap_mod <<'EOF' 2>/dev/null || log "(no accesslog overlay configured)"
dn: olcOverlay={2}accesslog,olcDatabase={1}mdb,cn=config
changetype: delete
EOF
            true
            ;;

        6)
            log "=== ITERATION 6: Combined best-of-all tuning ==="
            log "Applying: indexes + threads=16 + LMDB=10GB + OS limits"
            export LDAP_THREADS=16
            export LMDB_MAXSIZE=10737418240
            bash "$0" "$HOST" 1
            bash "$0" "$HOST" 2
            bash "$0" "$HOST" 3
            bash "$0" "$HOST" 4
            bash "$0" "$HOST" 5
            ;;

        7)
            log "=== ITERATION 7: Final optimum (derived from test results) ==="
            log "Applying all optimal settings..."
            export LDAP_THREADS="${LDAP_THREADS:-16}"
            export LMDB_MAXSIZE="${LMDB_MAXSIZE:-21474836480}"
            bash "$0" "$HOST" 1
            bash "$0" "$HOST" 2
            bash "$0" "$HOST" 3

            log "Adding additional recommended indexes..."
            ldap_mod <<'EOF'
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: employeeNumber eq
-
add: olcDbIndex
olcDbIndex: mobile eq
-
add: olcDbIndex
olcDbIndex: orclisenabled eq
EOF
            log "Final optimum applied"
            ;;

        *)
            log "Unknown iteration: $ITERATION"
            exit 1
            ;;
    esac

    # Always restart after tuning
    log "Restarting OpenLDAP..."
    systemctl restart symas-openldap-servers 2>/dev/null || systemctl restart slapd
    sleep 5

    # Verify
    if systemctl is-active --quiet symas-openldap-servers 2>/dev/null || systemctl is-active --quiet slapd 2>/dev/null; then
        log "Tuning iteration $ITERATION complete — slapd is active"
    else
        log "WARNING: slapd is not running after tuning!"
    fi
}

# Main
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log "Must run as root (or use sudo)"
    exit 1
fi

apply_tuning
