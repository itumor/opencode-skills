#!/usr/bin/env bash
# scripts/openldap-fix/run-openldap-fix.sh
# ====================================================================
# Orchestrator for the OpenLDAP Master/Replica fix and validation suite.
#
# Usage:
#   sudo bash run-openldap-fix.sh --role master|replica|both \
#     [--dry-run] [--backup] [--install] [--verify] [--e2e] [--cleanup] \
#     [--monitor-minutes 30] [--report]
#
# Order: backup → install(fix) → verify → e2e → monitor → report
# ====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${SCRIPT_DIR}/../../reports"
REPORT_FILE=""

# ── defaults ──
ROLE=""
DRY_RUN=0; DO_BACKUP=0; DO_INSTALL=0; DO_VERIFY=0; DO_E2E=0
DO_CLEANUP=0; DO_MONITOR=0; DO_REPORT=0
MON_MINUTES=30
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ── parse args ──
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --role=*) ROLE="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --backup) DO_BACKUP=1; shift ;;
    --install) DO_INSTALL=1; shift ;;
    --verify) DO_VERIFY=1; shift ;;
    --e2e) DO_E2E=1; shift ;;
    --cleanup) DO_CLEANUP=1; shift ;;
    --monitor-minutes) MON_MINUTES="${2:-30}"; shift 2 ;;
    --monitor-minutes=*) MON_MINUTES="${1#*=}"; shift ;;
    --report) DO_REPORT=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── validate ──
[[ "$ROLE" =~ ^(master|replica|both)$ ]] || { echo "Usage: $0 --role master|replica|both [flags]" >&2; exit 1; }
[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "[FATAL] Run as root" >&2; exit 1; }

# ── export for sub-scripts ──
export DRY_RUN
export TIMESTAMP

log()  { echo ""; echo "════════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════════"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

log "OpenLDAP Fix Suite — Role: ${ROLE} — ${TIMESTAMP}"

# ── check sub-scripts exist ──
for s in fix-master.sh fix-replica.sh diagnose-openldap.sh verify-openldap.sh \
         e2e-openldap-test.sh cleanup-openldap.sh monitor-openldap-logs.sh; do
  [[ -f "${SCRIPT_DIR}/${s}" ]] || fail "Missing: ${SCRIPT_DIR}/${s}"
done

mkdir -p "$REPORT_DIR"

# ═══════════════════════════════════════════════════════════════════════
# CLEANUP (run first if requested — stops service, wipes config/DB)
# ═══════════════════════════════════════════════════════════════════════
if [[ "$DO_CLEANUP" -eq 1 ]]; then
  log "PHASE: Cleanup"
  bash "${SCRIPT_DIR}/cleanup-openldap.sh" --all --force
fi

# ═══════════════════════════════════════════════════════════════════════
# BACKUP
# ═══════════════════════════════════════════════════════════════════════
if [[ "$DO_BACKUP" -eq 1 ]]; then
  log "PHASE: Backup"
  BACKUP="/tmp/openldap-backup-${TIMESTAMP}.tar.gz"
  mkdir -p "/tmp/openldap-bk-${TIMESTAMP}"
  [[ -d /opt/symas/etc/openldap/slapd.d ]] && cp -a /opt/symas/etc/openldap/slapd.d "/tmp/openldap-bk-${TIMESTAMP}/slapd.d" 2>/dev/null || true
  [[ -d /var/symas/openldap-data ]] && cp -a /var/symas/openldap-data "/tmp/openldap-bk-${TIMESTAMP}/openldap-data" 2>/dev/null || true
  tar czf "$BACKUP" -C "/tmp" "openldap-bk-${TIMESTAMP}" 2>/dev/null
  rm -rf "/tmp/openldap-bk-${TIMESTAMP}"
  echo "[INFO] Backup: $BACKUP ($(du -h "$BACKUP" 2>/dev/null | cut -f1))"
fi

# ═══════════════════════════════════════════════════════════════════════
# INSTALL / FIX
# ═══════════════════════════════════════════════════════════════════════
if [[ "$DO_INSTALL" -eq 1 ]]; then
  log "PHASE: Install/Fix"

  if [[ "$ROLE" == "master" || "$ROLE" == "both" ]]; then
    bash "${SCRIPT_DIR}/fix-master.sh" || fail "Master fix failed"
  fi

  if [[ "$ROLE" == "replica" || "$ROLE" == "both" ]]; then
    bash "${SCRIPT_DIR}/fix-replica.sh" || fail "Replica fix failed"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════
# VERIFY
# ═══════════════════════════════════════════════════════════════════════
if [[ "$DO_VERIFY" -eq 1 ]]; then
  log "PHASE: Verify"
  bash "${SCRIPT_DIR}/verify-openldap.sh" || fail "Verification failed"
fi

# ═══════════════════════════════════════════════════════════════════════
# E2E TEST
# ═══════════════════════════════════════════════════════════════════════
if [[ "$DO_E2E" -eq 1 ]]; then
  log "PHASE: E2E Test"
  bash "${SCRIPT_DIR}/e2e-openldap-test.sh" --role "$ROLE" || fail "E2E test failed"
fi

# ═══════════════════════════════════════════════════════════════════════
# MONITOR
# ═══════════════════════════════════════════════════════════════════════
if [[ "$DO_MONITOR" -eq 1 ]]; then
  log "PHASE: Monitor (${MON_MINUTES} min)"
  bash "${SCRIPT_DIR}/monitor-openldap-logs.sh" --minutes "$MON_MINUTES" --report || true
fi

# ═══════════════════════════════════════════════════════════════════════
# REPORT
# ═══════════════════════════════════════════════════════════════════════
if [[ "$DO_REPORT" -eq 1 ]]; then
  log "PHASE: Report"
  REPORT_FILE="${REPORT_DIR}/openldap-fix-report-${TIMESTAMP}.md"
  HOSTNAME="${HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
  {
    echo "# OpenLDAP Fix Report"
    echo "Host: ${HOSTNAME}"
    echo "Role: ${ROLE}"
    echo "Timestamp: $(date -Iseconds)"
    echo ""
    echo "## Phase Results"
    echo "- Backup:  $([[ "$DO_BACKUP" -eq 1 ]] && echo RUN || echo SKIP)"
    echo "- Install: $([[ "$DO_INSTALL" -eq 1 ]] && echo RUN || echo SKIP)"
    echo "- Verify:  $([[ "$DO_VERIFY" -eq 1 ]] && echo RUN || echo SKIP)"
    echo "- E2E:     $([[ "$DO_E2E" -eq 1 ]] && echo RUN || echo SKIP)"
    echo "- Monitor: $([[ "$DO_MONITOR" -eq 1 ]] && echo "${MON_MINUTES} min" || echo SKIP)"
    echo "- Cleanup: $([[ "$DO_CLEANUP" -eq 1 ]] && echo RUN || echo SKIP)"
    echo ""
    echo "## Notes"
    echo "Scripts used from: ${SCRIPT_DIR}/"
    echo "Report directory: ${REPORT_DIR}/"
  } > "$REPORT_FILE"
  echo "[INFO] Report: $REPORT_FILE"
fi

echo ""
echo "============================================================"
echo "  ALL PHASES COMPLETE"
echo "  Role: ${ROLE}"
echo "  Time: ${TIMESTAMP}"
echo "============================================================"
