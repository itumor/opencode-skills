#!/usr/bin/env bash
# scripts/openldap-fix/bank-one-click-fix.sh
# ====================================================================
# SINGLE SCRIPT — Bank deployment all-in-one fix.
# Auto-detects master/replica role and applies ALL fixes,
# verification, diagnostics, and produces a readiness report.
#
# Usage (copy to master AND replica, run on each):
#   sudo bash bank-one-click-fix.sh
#   sudo MASTER_IP=172.23.11.236 bash bank-one-click-fix.sh   # on replica
#
# What it does:
#   1. Auto-detects role (master / replica)
#   2. Runs fix-master.sh or fix-replica.sh
#   3. Runs verify-openldap.sh
#   4. Runs diagnose-openldap.sh → report
#   5. Runs coverage report (validate-bank-issues.sh)
#   6. Prints final summary
#
# Safe to run multiple times — all sub-scripts are idempotent.
# ====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS=$(date +%Y%m%d-%H%M%S)
HOSTNAME="${HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
REPORT_DIR="${REPORT_DIR:-reports}"
FINAL_REPORT="${REPORT_DIR}/bank-fix-report-${HOSTNAME}-${TS}.txt"

# ── Config (env-overridable) ───────────────────────────────────────
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_PW="${ADMIN_PW:-TheN1le1}"
REPL_PW="${REPL_PW:-replpass}"
MASTER_IP="${MASTER_IP:-}"
ACCESSLOG_GB="${ACCESSLOG_GB:-50}"
RETENTION_DAYS="${RETENTION_DAYS:-360}"
DB_MAXSIZE_GB="${DB_MAXSIZE_GB:-32}"
OPENLDAP_HARDEN="${OPENLDAP_HARDEN:-no}"
export BASE_DN ADMIN_PW REPL_PW MASTER_IP ACCESSLOG_GB RETENTION_DAYS DB_MAXSIZE_GB OPENLDAP_HARDEN

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "[FATAL] Must run as root (sudo bash bank-one-click-fix.sh)" >&2; exit 1; }

mkdir -p "$REPORT_DIR"

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$FINAL_REPORT"; }
ok()   { echo "  ✓ $*" | tee -a "$FINAL_REPORT"; }
bad()  { echo "  ✗ $*" | tee -a "$FINAL_REPORT"; }
banner() { echo ""; echo "════════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════════"; } >> "$FINAL_REPORT"

# ── Header ─────────────────────────────────────────────────────────
{
  echo "OpenLDAP Bank Fix Report"
  echo "========================"
  echo "Host:      ${HOSTNAME}"
  echo "Timestamp: $(date -Iseconds)"
  echo "Script:    bank-one-click-fix.sh"
  echo ""
} > "$FINAL_REPORT"

# ═══════════════════════════════════════════════════════════════════════
# Step 1: Role detection
# ═══════════════════════════════════════════════════════════════════════
log "Step 1: Detecting OpenLDAP role..."

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

for svc in symas-openldap-servers slapd; do
  if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then SLAPD_SVC="$svc"; break; fi
done
SLAPD_SVC="${SLAPD_SVC:-symas-openldap-servers}"

if ! systemctl is-active --quiet "$SLAPD_SVC" 2>/dev/null && ! pgrep -x slapd >/dev/null 2>&1; then
  log "Service not running — starting ${SLAPD_SVC}..."
  systemctl start "$SLAPD_SVC" 2>/dev/null || { bad "Cannot start service"; exit 1; }
  sleep 2
fi

DB_DN=$(ldapsearch -o ldif-wrap=no -Y EXTERNAL -H ldapi:/// -b cn=config -LLL \
  '(&(objectClass=olcMdbConfig)(olcSuffix=*))' dn 2>/dev/null | awk '/^dn: /{print $2; exit}')
HAS_SYNCREPL=$(ldapsearch -o ldif-wrap=no -Y EXTERNAL -H ldapi:/// -b "${DB_DN:-cn=config}" \
  -s base -LLL olcSyncrepl 2>/dev/null | grep -ci olcSyncrepl || true)

if [[ "$HAS_SYNCREPL" -gt 0 ]]; then
  ROLE="replica"
  log "Role: REPLICA (syncrepl detected)"
  [[ -z "${MASTER_IP:-}" ]] && {
    MASTER_IP=$(ldapsearch -o ldif-wrap=no -Y EXTERNAL -H ldapi:/// -b "$DB_DN" -s base -LLL \
      olcSyncrepl 2>/dev/null | grep -oP 'provider=ldap://\K[^: ]+' | head -1 || echo "")
    [[ -n "${MASTER_IP:-}" ]] && log "Auto-detected master IP: ${MASTER_IP}" && export MASTER_IP
  }
else
  ROLE="master"
  log "Role: MASTER (no syncrepl detected)"
fi

export ROLE
echo "Role: ${ROLE}" >> "$FINAL_REPORT"
echo "" >> "$FINAL_REPORT"

# ═══════════════════════════════════════════════════════════════════════
# Step 2: Run fix
# ═══════════════════════════════════════════════════════════════════════
log "Step 2: Running fix scripts..."

if [[ "$ROLE" == "master" ]]; then
  if [[ -f "${SCRIPT_DIR}/fix-master.sh" ]]; then
    bash "${SCRIPT_DIR}/fix-master.sh" 2>&1 | tee -a "$FINAL_REPORT"
    FIX_EXIT=${PIPESTATUS[0]}
  else
    bad "fix-master.sh not found at ${SCRIPT_DIR}/fix-master.sh"
    FIX_EXIT=1
  fi
else
  if [[ -f "${SCRIPT_DIR}/fix-replica.sh" ]]; then
    bash "${SCRIPT_DIR}/fix-replica.sh" 2>&1 | tee -a "$FINAL_REPORT"
    FIX_EXIT=${PIPESTATUS[0]}
  else
    bad "fix-replica.sh not found at ${SCRIPT_DIR}/fix-replica.sh"
    FIX_EXIT=1
  fi
fi

[[ "$FIX_EXIT" -eq 0 ]] && ok "Fix phase PASSED" || bad "Fix phase had errors"

# ═══════════════════════════════════════════════════════════════════════
# Step 3: Verify
# ═══════════════════════════════════════════════════════════════════════
log "Step 3: Running verification..."
if [[ -f "${SCRIPT_DIR}/verify-openldap.sh" ]]; then
  bash "${SCRIPT_DIR}/verify-openldap.sh" 2>&1 | tee -a "$FINAL_REPORT"
  VERIFY_EXIT=${PIPESTATUS[0]}
else
  bad "verify-openldap.sh not found"
  VERIFY_EXIT=1
fi

[[ "$VERIFY_EXIT" -eq 0 ]] && ok "Verify phase PASSED" || bad "Verify phase had errors"

# ═══════════════════════════════════════════════════════════════════════
# Step 4: Diagnose
# ═══════════════════════════════════════════════════════════════════════
log "Step 4: Running diagnostics..."
if [[ -f "${SCRIPT_DIR}/diagnose-openldap.sh" ]]; then
  DIAG_FILE=$(bash "${SCRIPT_DIR}/diagnose-openldap.sh" 2>/dev/null | tail -1)
  [[ -f "${DIAG_FILE:-}" ]] && ok "Diagnosis: ${DIAG_FILE}" || warn "Diagnosis completed (see report)" 
else
  warn "diagnose-openldap.sh not found — skipping"
fi

# ═══════════════════════════════════════════════════════════════════════
# Step 5: Coverage validation
# ═══════════════════════════════════════════════════════════════════════
log "Step 5: Coverage validation..."
if [[ -f "${SCRIPT_DIR}/validate-bank-issues.sh" ]]; then
  COV_FILE=$(bash "${SCRIPT_DIR}/validate-bank-issues.sh" 2>/dev/null | tail -1 | sed 's/Report: //')
  if [[ -f "${COV_FILE:-}" ]]; then
    ok "Coverage: ${COV_FILE}"
    echo "" >> "$FINAL_REPORT"
    echo "── Coverage Report ──" >> "$FINAL_REPORT"
    cat "$COV_FILE" >> "$FINAL_REPORT"
  fi
else
  warn "validate-bank-issues.sh not found — skipping"
fi

# ═══════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════════════
{
  echo ""
  echo "════════════════════════════════════════════"
  echo "  BANK FIX — FINAL STATUS"
  echo "════════════════════════════════════════════"
  echo "  Host:       ${HOSTNAME}"
  echo "  Role:       ${ROLE}"
  echo "  Timestamp:  $(date -Iseconds)"
  echo "  Fix exit:   ${FIX_EXIT:-?}"
  echo "  Verify exit: ${VERIFY_EXIT:-?}"
  echo ""
  if [[ "${FIX_EXIT:-0}" -eq 0 && "${VERIFY_EXIT:-0}" -eq 0 ]]; then
    echo "  Status: ALL CHECKS PASSED"
  else
    echo "  Status: REVIEW REQUIRED — some checks failed"
  fi
  echo "  Report: ${FINAL_REPORT}"
  echo ""
} | tee -a "$FINAL_REPORT"

echo ""
log "Report saved to: ${FINAL_REPORT}"
echo ""

if [[ "${FIX_EXIT:-0}" -eq 0 && "${VERIFY_EXIT:-0}" -eq 0 ]]; then
  exit 0
else
  exit 1
fi
