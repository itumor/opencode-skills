#!/usr/bin/env bash
# scripts/openldap-fix/monitor-openldap-logs.sh
# Watches Symas OpenLDAP logs for N minutes, detects errors, writes report.
# Usage: sudo bash monitor-openldap-logs.sh [--minutes N] [--report]
set -euo pipefail

log() { echo "[MON] $*"; }
TS=$(date +%Y%m%d-%H%M%S)
HOSTNAME="${HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
MON_MINUTES="${MON_MINUTES:-30}"
REPORT_MODE=0
REPORT_FILE="reports/openldap-monitoring-${HOSTNAME}-${TS}.txt"

for arg in "$@"; do
  case "$arg" in
    --minutes) MON_MINUTES="${2:-30}"; shift 2>/dev/null || true ;;
    --minutes=*) MON_MINUTES="${arg#*=}" ;;
    --report) REPORT_MODE=1 ;;
    *) ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "[FATAL] Run as root (for journalctl)" >&2; exit 1; }

detect_service() {
  for s in symas-openldap-servers slapd; do
    systemctl list-units --type=service 2>/dev/null | grep -qF "$s" && { echo "$s"; return; }
  done
  pgrep -x slapd >/dev/null 2>&1 && echo "slapd" || echo "symas-openldap-servers"
}
SLAPD_SVC=$(detect_service)

PATTERNS=(
  "TLS negotiation failure|TLS error:|ldap_start_tls failed|CERTIFICATE_VERIFY_FAILED"
  "do_syncrepl.*rc=|do_syncrep2.*Size limit exceeded|retrying|refreshDelete"
  "err=50|permission denied|no write access"
  "err=49|invalid cred|Invalid credentials"
  "err=13|confidentiality required|Confidentiality"
  "MDB_MAP_FULL|MDB_READERS_FULL|mdb_put failed"
  "objectClass: value.*invalid per syntax|schema_check failed"
  "checksum error|ldif_read_file.*checksum"
  "connection refused|Connection reset"
  "certificate.*expired|certificate.*invalid"
)
LABELS=(
  "TLS_ERROR" "REPL_ERROR" "PERM_DENIED" "BIND_ERROR"
  "CONFIDENTIALITY" "DB_ERROR" "SCHEMA_ERROR" "CONFIG_ERROR"
  "CONN_REFUSED" "CERT_ERROR"
)

declare -A COUNTS
for tag in "${LABELS[@]}"; do COUNTS[$tag]=0; done

TMPDIR="/tmp/monitor-${TS}"
mkdir -p "$TMPDIR"
LOG_RAW="${TMPDIR}/journal.raw"  # ponytail: raw log collector for report

banner() { echo ""; echo "=== $* ==="; }
banner "OpenLDAP Log Monitor — ${MON_MINUTES} minutes — ${SLAPD_SVC}"
log "Host: ${HOSTNAME}"
log "PID: $$"
log "Start: $(date -Iseconds)"

# Background: tail journal
END_TS=$((SECONDS + MON_MINUTES * 60))
journalctl -u "$SLAPD_SVC" -f --no-pager 2>/dev/null > "$LOG_RAW" &
JOURNAL_PID=$!

trap_cleanup() {
  log "Shutting down monitor..."
  kill "$JOURNAL_PID" 2>/dev/null || true
  wait "$JOURNAL_PID" 2>/dev/null || true
  echo "" >> "$LOG_RAW"
}
trap trap_cleanup EXIT SIGINT SIGTERM

# Monitor loop
log "Monitoring for ${MON_MINUTES} minutes (${END_TS}s)..."

last_line=0
while [[ $SECONDS -lt $END_TS ]]; do
  sleep 2
  # Read new lines from raw log
  new_lines=$(tail -n +$((last_line + 1)) "$LOG_RAW" 2>/dev/null || true)
  if [[ -n "$new_lines" ]]; then
    echo "$new_lines" | while IFS= read -r line; do
      for i in "${!LABELS[@]}"; do
        if echo "$line" | grep -qiE "${PATTERNS[$i]}"; then
          sev="WARN"
          case "${LABELS[$i]}" in
            DB_ERROR|REPL_ERROR|CERT_ERROR|CONFIDENTIALITY) sev="ERROR" ;;
            BIND_ERROR) sev="WARN" ;;
            TLS_ERROR) sev="ERROR" ;;
            CONFIG_ERROR) sev="WARN" ;;
          esac
          echo "[$sev][${LABELS[$i]}] $(echo "$line" | cut -c1-160)"
          COUNTS[${LABELS[$i]}]=$((COUNTS[${LABELS[$i]}] + 1))
          break
        fi
      done
    done
    last_line=$(wc -l < "$LOG_RAW" 2>/dev/null || echo "$last_line")
  fi
done

kill "$JOURNAL_PID" 2>/dev/null || true
wait "$JOURNAL_PID" 2>/dev/null || true

# ── Summary ──
banner "Monitoring Summary (${MON_MINUTES} minutes)"
echo ""
printf "%-20s %8s  %s\n" "Error Type" "Count" "Severity"
echo "-------------------------------------------"
for i in "${!LABELS[@]}"; do
  c=${COUNTS[${LABELS[$i]}]}
  sev="WARN"
  case "${LABELS[$i]}" in
    DB_ERROR|REPL_ERROR|CERT_ERROR|CONFIDENTIALITY|TLS_ERROR) sev="ERROR" ;;
  esac
  [[ "$c" -gt 0 ]] && printf "%-20s %8d  %s\n" "${LABELS[$i]}" "$c" "$sev"
done
echo ""

CRITICAL_COUNT=$(( COUNTS[DB_ERROR] + COUNTS[REPL_ERROR] + COUNTS[CERT_ERROR] + COUNTS[CONFIDENTIALITY] + COUNTS[TLS_ERROR] ))
log "Critical errors in monitoring period: ${CRITICAL_COUNT}"

# ── Report ──
if [[ "$REPORT_MODE" -eq 1 ]]; then
  mkdir -p reports
  {
    echo "# OpenLDAP Log Monitoring Report"
    echo "Host: ${HOSTNAME}"
    echo "Duration: ${MON_MINUTES} minutes"
    echo "Start: $(date -d "@$(( $(date +%s) - MON_MINUTES * 60 ))" -Iseconds 2>/dev/null || echo "unknown")"
    echo "End: $(date -Iseconds)"
    echo ""
    echo "## Error Summary"
    for i in "${!LABELS[@]}"; do
      echo "- ${LABELS[$i]}: ${COUNTS[${LABELS[$i]}]}"
    done
    echo ""
    echo "Critical errors total: ${CRITICAL_COUNT}"
    echo ""
    echo "## Error Log Lines"
    echo '```'
    grep -iE "$(IFS='|'; echo "${PATTERNS[*]}")" "$LOG_RAW" 2>/dev/null | head -500 || echo "No error lines found"
    echo '```'
  } > "$REPORT_FILE"
  log "Report: $REPORT_FILE"
  rm -rf "$TMPDIR"
else
  log "Raw log: $LOG_RAW"
fi

[[ "$CRITICAL_COUNT" -gt 0 ]] && exit 1 || exit 0
