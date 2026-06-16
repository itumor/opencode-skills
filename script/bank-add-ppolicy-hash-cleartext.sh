#!/usr/bin/env bash
# bank-add-ppolicy-hash-cleartext.sh
# ====================================================================
# Adds olcPPolicyHashCleartext: TRUE to the ppolicy overlay entry
# in cn=config. This causes slapd to hash cleartext passwords
# before storing them in the database, rather than storing the
# original cleartext value.
#
# Reference: https://www.openldap.org/lists/openldap-technical/201708/msg00024.html
#
# Usage:
#   sudo bash bank-add-ppolicy-hash-cleartext.sh               # apply
#   sudo bash bank-add-ppolicy-hash-cleartext.sh --dry-run     # check only
#   sudo bash bank-add-ppolicy-hash-cleartext.sh --force       # skip confirmation
#   sudo bash bank-add-ppolicy-hash-cleartext.sh --help
# ====================================================================
set -uo pipefail

log()   { echo "[INFO]  $*"; }
ok()    { echo "[ OK ]  $*"; }
warn()  { echo "[WARN]  $*"; }
bad()   { echo "[FAIL] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }
banner(){ echo ""; echo "=== $* ==="; }

PASS=0; FAIL=0; WARN=0; CHANGES=0
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

ATTR_NAME="${ATTR_NAME:-olcPPolicyHashCleartext}"
ATTR_VALUE="${ATTR_VALUE:-TRUE}"
LDAPI_URI="${LDAPI_URI:-ldapi:///}"
BACKUP_DIR="${BACKUP_DIR:-/var/symas/openldap-data/backup}"

DRY_RUN=0
FORCE=0
RESTORE=""

usage() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Options:
  --dry-run         Check what would change — no modifications
  --force           Skip confirmation prompts (CI/automation)
  --restore FILE    Restore ppolicy overlay from a previously saved backup
  --backup-dir DIR  Override backup directory (default: $BACKUP_DIR)
  --help            Show this message

Env overrides:
  ATTR_NAME    Attribute name (default: olcPPolicyHashCleartext)
  ATTR_VALUE   Attribute value (default: TRUE)

Examples:
  sudo bash $0                          # apply changes (with backup)
  sudo bash $0 --dry-run                # preview only
  sudo bash $0 --force                  # CI mode, no prompts
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=1; shift ;;
        --force)     FORCE=1; shift ;;
        --restore)   RESTORE="$2"; shift 2 ;;
        --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        --help)      usage ;;
        *)           warn "Unknown option: $1"; usage ;;
    esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh           ]] && source /etc/profile.d/symas_env.sh 2>/dev/null || true
[[ -f /opt/symas/etc/openldap/sysmas_env.sh ]] && source /opt/symas/etc/openldap/sysmas_env.sh 2>/dev/null || true

require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found — install it first"; }
require_cmd ldapsearch
require_cmd ldapmodify

export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

LOCKFILE="/tmp/bank-add-ppolicy-hash-cleartext.lock"
cleanup() {
    local rc=$?
    rm -f "$LOCKFILE" /tmp/add-hash-cleartext.ldif 2>/dev/null || true
    exit $rc
}
trap cleanup EXIT

exec 200>"$LOCKFILE"
if ! flock -n 200; then
    fatal "Another instance is already running (lock: $LOCKFILE)"
fi

# ── Restore mode ─────────────────────────────────────────────────────
if [[ -n "$RESTORE" ]]; then
    banner "RESTORE MODE"
    [[ -f "$RESTORE" ]] || fatal "Backup file not found: $RESTORE"
    RESTORE_DN="$(awk '/^dn: /{print $2; exit}' "$RESTORE")"
    [[ -n "$RESTORE_DN" ]] || fatal "Could not find DN in backup file"
    log "Restoring ppolicy overlay from: $RESTORE"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY_RUN: would restore $RESTORE_DN from $RESTORE"
        exit 0
    fi
    ldapmodify -Y EXTERNAL -H "$LDAPI_URI" <<LDIF
dn: ${RESTORE_DN}
changetype: delete
LDIF
    ok "Deleted old ppolicy overlay entry"
    if slapadd -n 0 -F /opt/symas/etc/openldap/slapd.d -l "$RESTORE" 2>/tmp/slapadd-restore-err.log; then
        ok "Restored ppolicy overlay from backup"
    else
        bad "slapadd restore failed:"
        cat /tmp/slapadd-restore-err.log || true
        fatal "Restore failed — manual intervention required"
    fi
    ok "Restore complete"
    exit 0
fi

echo ""
echo "============================================================"
echo "  ADD olcPPolicyHashCleartext"
echo "  Server:   ${HOSTNAME}"
echo "  Attribute: ${ATTR_NAME}=${ATTR_VALUE}"
echo "  Time:     ${TIMESTAMP}"
[[ "$DRY_RUN" -eq 1 ]] && echo "  Mode:     DRY-RUN"
echo "============================================================"

# ── Pre-flight ───────────────────────────────────────────────────────
banner "Pre-flight"
SLAPD_SVC=""
for svc in symas-openldap-servers slapd; do
    if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then
        SLAPD_SVC="$svc"; break
    fi
done
[[ -z "${SLAPD_SVC:-}" ]] && pgrep -x slapd >/dev/null 2>&1 && SLAPD_SVC="slapd"
SLAPD_SVC="${SLAPD_SVC:-symas-openldap-servers}"

pgrep -x slapd >/dev/null 2>&1 || fatal "slapd is not running — start it first"
ok "slapd running (service: ${SLAPD_SVC})"

ldapwhoami -Y EXTERNAL -H "$LDAPI_URI" >/dev/null 2>&1 && ok "LDAPI EXTERNAL access works" \
    || fatal "LDAPI EXTERNAL failed — cannot modify cn=config"

ldapi_search()  { ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" "$@" 2>/dev/null; }
ldapi_modify()  { ldapmodify -Y EXTERNAL -H "$LDAPI_URI" "$@"; }

mkdir -p "$BACKUP_DIR" 2>/dev/null || true

# ── Step 1: Locate ppolicy overlay ───────────────────────────────────
banner "Step 1: Locate ppolicy overlay entry"

PPOLICY_DN="$(ldapi_search -b cn=config -s sub "(olcOverlay=ppolicy)" dn \
    | awk '/^dn: /{print $2; exit}')"

if [[ -z "$PPOLICY_DN" ]]; then
    fatal "ppolicy overlay not found in cn=config. Apply ppolicy overlay first."
fi
ok "ppolicy overlay DN: ${PPOLICY_DN}"

# ── Step 2: Backup ───────────────────────────────────────────────────
BACKUP_FILE="${BACKUP_DIR}/ppolicy-overlay-${TIMESTAMP}.ldif"
banner "Step 2: Backup ppolicy overlay"
log "Backing up to: ${BACKUP_FILE}"

if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY_RUN: would backup ${PPOLICY_DN} to ${BACKUP_FILE}"
else
    ldapi_search -b "$PPOLICY_DN" -s base -LLL >"$BACKUP_FILE" && ok "Backup saved: ${BACKUP_FILE}" \
        || fatal "Failed to backup ${PPOLICY_DN}"
fi

# ── Step 3: Check current state ─────────────────────────────────────
banner "Step 3: Check current state"

CURRENT_VAL="$(ldapi_search -b "$PPOLICY_DN" -s base -LLL "${ATTR_NAME}" \
    | awk -F': ' -v attr="${ATTR_NAME}" '$1 == attr {print $2; exit}')"

if [[ "${CURRENT_VAL^^}" == "TRUE" ]]; then
    ok "${ATTR_NAME} already TRUE — nothing to do"
    SKIP=1
elif [[ -n "$CURRENT_VAL" ]]; then
    warn "${ATTR_NAME} currently '${CURRENT_VAL}' — will change to TRUE"
    SKIP=0
else
    log "${ATTR_NAME} not set — will add"
    SKIP=0
fi

# ── Confirmation ─────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 0 && "$FORCE" -eq 0 && "$SKIP" -eq 0 ]]; then
    echo ""
    warn "About to modify ${PPOLICY_DN} on ${HOSTNAME}"
    log "Backup saved at: ${BACKUP_FILE}"
    log "To rollback: sudo bash $0 --restore ${BACKUP_FILE}"
    read -r -p "Continue? [y/N] " yn
    case "$yn" in
        [yY]|[yY][eE][sS]) ;;
        *) fatal "Aborted by user" ;;
    esac
fi

# ── Step 4: Apply ────────────────────────────────────────────────────
banner "Step 4: Apply ${ATTR_NAME}=${ATTR_VALUE}"

if [[ "$SKIP" -eq 1 ]]; then
    ok "Already configured — skipping"
elif [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY_RUN: would ldapmodify ${ATTR_NAME}=${ATTR_VALUE} on ${PPOLICY_DN}"
else
    OP="replace"
    [[ -z "$CURRENT_VAL" ]] && OP="add"

    cat >/tmp/add-hash-cleartext.ldif <<LDIF
dn: ${PPOLICY_DN}
changetype: modify
${OP}: ${ATTR_NAME}
${ATTR_NAME}: ${ATTR_VALUE}
LDIF

    if ldapi_modify -f /tmp/add-hash-cleartext.ldif; then
        ok "Set ${ATTR_NAME}=${ATTR_VALUE} on ${PPOLICY_DN}"
        PASS=$((PASS+1)); CHANGES=$((CHANGES+1))
    else
        bad "Failed to set ${ATTR_NAME}"
        FAIL=$((FAIL+1))
        fatal "Rollback: sudo bash $0 --restore ${BACKUP_FILE}"
    fi
fi

# ── Step 5: Verify ────────────────────────────────────────────────────
banner "Step 5: Verify"

if [[ "$DRY_RUN" -eq 1 ]]; then
    ok "DRY_RUN: skipping verification"
else
    VERIFY_VAL="$(ldapi_search -b "$PPOLICY_DN" -s base -LLL "${ATTR_NAME}" \
        | awk -F': ' -v attr="${ATTR_NAME}" '$1 == attr {print $2; exit}')"
    if [[ "${VERIFY_VAL^^}" == "TRUE" ]]; then
        ok "${ATTR_NAME}=${VERIFY_VAL} — verified"
        PASS=$((PASS+1))
    else
        bad "${ATTR_NAME}=${VERIFY_VAL:-not found} — verification failed"
        FAIL=$((FAIL+1))
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  ADD olcPPolicyHashCleartext — Complete"
echo "============================================================"
echo ""
echo "  Overlay DN:   ${PPOLICY_DN}"
echo "  Attribute:    ${ATTR_NAME}=${ATTR_VALUE}"
echo "  Backup:       ${BACKUP_FILE}"
echo "  Changes:      ${CHANGES}"
echo "  Pass: ${PASS}  Fail: ${FAIL}  Warn: ${WARN}"
echo ""
[[ -n "$BACKUP_FILE" ]] && echo "  To rollback:"
[[ -n "$BACKUP_FILE" ]] && echo "    sudo bash $0 --restore ${BACKUP_FILE}"
echo ""

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
