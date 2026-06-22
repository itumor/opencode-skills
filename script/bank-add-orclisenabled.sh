#!/usr/bin/env bash
# bank-add-orclisenabled.sh
# ====================================================================
# Adds the 'orclisenabled' custom attribute (OID 1.3.6.1.4.1.55555.1.16)
# and includes it in the bankUserExtension object class MAY list.
#
# Production-ready: auto-backup before changes, --restore support,
# lock file, pre-flight validation, trap cleanup.
#
# Usage:
#   sudo bash bank-add-orclisenabled.sh               # apply changes
#   sudo bash bank-add-orclisenabled.sh --dry-run     # check only
#   sudo bash bank-add-orclisenabled.sh --force       # skip confirmation (CI)
#   sudo bash bank-add-orclisenabled.sh --restore /path/to/backup.ldif  # rollback
#   sudo bash bank-add-orclisenabled.sh --help
# ====================================================================
set -uo pipefail

# ── Logging ──────────────────────────────────────────────────────────
log()   { echo "[INFO]  $*"; }
ok()    { echo "[ OK ]  $*"; }
warn()  { echo "[WARN]  $*"; }
bad()   { echo "[FAIL] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }
banner(){ echo ""; echo "=== $* ==="; }

PASS=0; FAIL=0; WARN=0; CHANGES=0
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

# ── Config (overridable via env) ─────────────────────────────────────
ATTR_NAME="${ATTR_NAME:-orclisenabled}"
ATTR_OID="${ATTR_OID:-1.3.6.1.4.1.55555.1.16}"
SCHEMA_NAME="${SCHEMA_NAME:-bank-custom}"
OC_NAME="${OC_NAME:-bankUserExtension}"
LDAPI_URI="${LDAPI_URI:-ldapi:///}"
BACKUP_DIR="${BACKUP_DIR:-/var/symas/openldap-data/backup}"
BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
ADMIN_DN="${ADMIN_DN:-cn=admin,${BASE_DN}}"
ADMIN_PW="${ADMIN_PW:-TheN1le1}"

# ── Flags ────────────────────────────────────────────────────────────
DRY_RUN=0
FORCE=0
RESTORE=""
BACKUP_FILE_CHECK=""

usage() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Options:
  --dry-run         Check what would change — no modifications
  --force           Skip confirmation prompts (CI/automation)
  --restore FILE    Restore the schema from a previously saved backup
  --backup-dir DIR  Override backup directory (default: $BACKUP_DIR)
  --help            Show this message

Env overrides:
  ATTR_NAME    Attribute name (default: orclisenabled)
  ATTR_OID     Attribute OID (default: 1.3.6.1.4.1.55555.1.16)
  SCHEMA_NAME  Schema cn (default: bank-custom)
  BASE_DN      LDAP base DN (default: dc=eab,dc=bank,dc=local)

Examples:
  sudo bash $0                          # apply changes (with backup)
  sudo bash $0 --dry-run                # preview only
  sudo bash $0 --force                  # CI mode, no prompts
  sudo bash $0 --restore /var/symas/openldap-data/backup/bank-custom-20260611-120000.ldif
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

# ── Pre-flight ───────────────────────────────────────────────────────
[[ "${EUID:-$(id -u)}" -eq 0 ]] || fatal "Run as root"

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"
[[ -f /etc/profile.d/symas_env.sh ]]           && source /etc/profile.d/symas_env.sh 2>/dev/null || true
[[ -f /opt/symas/etc/openldap/sysmas_env.sh ]] && source /opt/symas/etc/openldap/sysmas_env.sh 2>/dev/null || true

require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found — install it first"; }
require_cmd ldapsearch
require_cmd ldapmodify

export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

# ── Lock file ────────────────────────────────────────────────────────
LOCKFILE="/tmp/bank-add-orclisenabled.lock"
cleanup() {
    local rc=$?
    if [[ -f "$LOCKFILE" ]]; then
        rm -f "$LOCKFILE" 2>/dev/null || true
    fi
    rm -f /tmp/add-orclisenabled.ldif /tmp/update-oc.ldif /tmp/update-oc2.ldif 2>/dev/null || true
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

    if [[ ! -f "$RESTORE" ]]; then
        fatal "Backup file not found: $RESTORE"
    fi

    log "Restoring schema from: $RESTORE"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY_RUN: would restore schema from $RESTORE"
        exit 0
    fi

    # Read the DN from the backup file
    RESTORE_DN="$(awk '/^dn: /{print $2; exit}' "$RESTORE")"
    if [[ -z "$RESTORE_DN" ]]; then
        fatal "Could not find DN in backup file: $RESTORE"
    fi
    log "Schema DN in backup: $RESTORE_DN"

    # Delete existing then re-add from backup
    cat >/tmp/add-orclisenabled.ldif <<LDIFF
dn: ${RESTORE_DN}
changetype: delete
LDIFF

    ldapmodify -Y EXTERNAL -H "$LDAPI_URI" -f /tmp/add-orclisenabled.ldif 2>/dev/null \
        && ok "Deleted old schema entry" \
        || { warn "Delete schema entry failed (may not exist yet — continuing)"; }

    if slapadd -n 0 -F /opt/symas/etc/openldap/slapd.d -l "$RESTORE" 2>/tmp/slapadd-restore-err.log; then
        ok "Restored schema from backup"
        rm -f /tmp/slapadd-restore-err.log
    else
        bad "slapadd restore failed:"
        cat /tmp/slapadd-restore-err.log 2>/dev/null || true
        rm -f /tmp/slapadd-restore-err.log
        fatal "Restore failed — manual intervention required"
    fi

    banner "Verify restore"
    if ldapi_verify_orclisenabled; then
        ok "Restore verified — orclisenabled attribute present"
    else
        bad "Restore verification failed — orclisenabled NOT found"
        exit 1
    fi

    echo ""
    echo "============================================================"
    echo "  RESTORE COMPLETE"
    echo "============================================================"
    exit 0
fi

# ── Header ───────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  ADD orclisenabled ATTRIBUTE"
echo "  Server:   ${HOSTNAME}"
echo "  OID:      ${ATTR_OID}"
echo "  Schema:   ${SCHEMA_NAME}"
echo "  Time:     ${TIMESTAMP}"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  Mode:     DRY-RUN"
fi
echo "============================================================"

# ── Pre-flight: slapd status ────────────────────────────────────────
banner "Pre-flight"
SLAPD_SVC=""
for svc in symas-openldap-servers slapd; do
    if systemctl list-units --type=service 2>/dev/null | grep -qF "$svc"; then
        SLAPD_SVC="$svc"
        break
    fi
done
if [[ -z "${SLAPD_SVC:-}" ]] && pgrep -x slapd >/dev/null 2>&1; then
    SLAPD_SVC="slapd"
fi
SLAPD_SVC="${SLAPD_SVC:-symas-openldap-servers}"

if ! pgrep -x slapd >/dev/null 2>&1; then
    fatal "slapd is not running — start it first: systemctl start ${SLAPD_SVC}"
fi
ok "slapd running (service: ${SLAPD_SVC})"

if ldapwhoami -Y EXTERNAL -H "$LDAPI_URI" >/dev/null 2>&1; then
    ok "LDAPI EXTERNAL access works"
else
    fatal "LDAPI EXTERNAL failed — cannot modify schema"
fi

# ── Helpers ──────────────────────────────────────────────────────────
ldapi_search() {
    ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" "$@" 2>/dev/null
}

ldapi_modify() {
    ldapmodify -Y EXTERNAL -H "$LDAPI_URI" "$@"
}

ldapi_verify_orclisenabled() {
    local v
    v="$(ldapi_search -b "$SCHEMA_DN" -s base -LLL olcAttributeTypes 2>/dev/null)"
    echo "$v" | grep -q "NAME '${ATTR_NAME}'"
}

ldapi_verify_in_oc() {
    local v
    v="$(ldapi_search -b "$SCHEMA_DN" -s base -LLL olcObjectClasses 2>/dev/null)"
    echo "$v" | grep -q "${ATTR_NAME}"
}

# ── Create backup dir ────────────────────────────────────────────────
mkdir -p "$BACKUP_DIR" 2>/dev/null || true

# ── Step 1: Locate schema ───────────────────────────────────────────
banner "Step 1: Locate schema"
SCHEMA_DN="$(ldapi_search -b "cn=schema,cn=config" \
    -LLL "(&(objectClass=olcSchemaConfig)(|(cn=${SCHEMA_NAME})(cn=*${SCHEMA_NAME})))" dn \
    | awk '/^dn: /{print $2; exit}')"

if [[ -z "$SCHEMA_DN" ]]; then
    fatal "Schema ${SCHEMA_NAME} not found in cn=config. Run 12-Create_custom_schema.sh first."
fi
ok "Schema DN: ${SCHEMA_DN}"

# ── Step 2: Backup current schema ────────────────────────────────────
BACKUP_FILE="${BACKUP_DIR}/${SCHEMA_NAME}-${TIMESTAMP}.ldif"
banner "Step 2: Backup current schema"
log "Backing up to: ${BACKUP_FILE}"

if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY_RUN: would backup ${SCHEMA_DN} to ${BACKUP_FILE}"
else
    if ldapi_search -b "$SCHEMA_DN" -s base -LLL >"$BACKUP_FILE"; then
        ok "Backup saved: ${BACKUP_FILE}"
        BACKUP_FILE_CHECK="$BACKUP_FILE"
    else
        fatal "Failed to backup schema ${SCHEMA_DN}"
    fi
fi

# ── Step 3: Check current state ─────────────────────────────────────
banner "Step 3: Check current state"
schema_dump="$(ldapi_search -b "$SCHEMA_DN" -s base -LLL olcAttributeTypes olcObjectClasses || true)"

attr_exists="$(echo "$schema_dump" | grep "olcAttributeTypes:" | grep -c "NAME '${ATTR_NAME}'" || true)"
oc_has_attr="$(echo "$schema_dump" | grep "olcObjectClasses:" | grep -c "${ATTR_NAME}" || true)"

ATTR_NEEDS_FIX=0
ATTR_BOOL_VAL=""
if [[ "$attr_exists" -gt 0 ]]; then
    # Check if it's Boolean syntax (needs conversion to Directory String)
    ATTR_BOOL_LINE="$(echo "$schema_dump" | grep "olcAttributeTypes:" | grep "NAME '${ATTR_NAME}'" | grep "SYNTAX 1.3.6.1.4.1.1466.115.121.1.7" || true)"
    if [[ -n "$ATTR_BOOL_LINE" ]]; then
        warn "Attribute '${ATTR_NAME}' exists as Boolean — will convert to Directory String"
        ATTR_DONE=0
        ATTR_NEEDS_FIX=1
        ATTR_BOOL_VAL="${ATTR_BOOL_LINE#olcAttributeTypes: }"
    else
        ok "Attribute '${ATTR_NAME}' already exists in schema"; ATTR_DONE=1
    fi
else
    log "Attribute '${ATTR_NAME}' not found — will add"; ATTR_DONE=0
fi

if [[ "$oc_has_attr" -gt 0 ]]; then
    ok "'${ATTR_NAME}' already in ${OC_NAME} MAY list"; OC_DONE=1
else
    log "'${ATTR_NAME}' not in ${OC_NAME} MAY list — will add"; OC_DONE=0
fi

if [[ "$ATTR_DONE" -eq 1 && "$OC_DONE" -eq 1 ]]; then
    ok "Nothing to do — orclisenabled already fully configured"
    SKIP_ADD=1
else
    SKIP_ADD=0
fi

# ── Confirmation (unless --force or nothing to do) ──────────────────
if [[ "$DRY_RUN" -eq 0 && "$FORCE" -eq 0 && "$SKIP_ADD" -eq 0 ]]; then
    echo ""
    warn "About to modify schema ${SCHEMA_NAME} on ${HOSTNAME}"
    log "Backup saved at: ${BACKUP_FILE}"
    log "To rollback: sudo bash $0 --restore ${BACKUP_FILE}"
    read -r -p "Continue? [y/N] " yn
    case "$yn" in
        [yY]|[yY][eE][sS]) ;;
        *) fatal "Aborted by user" ;;
    esac
fi

# ── Step 4: Add attribute type ──────────────────────────────────────
banner "Step 4: Add attribute type"
ATTR_DEF="( ${ATTR_OID} NAME '${ATTR_NAME}' DESC 'Oracle enabled flag' EQUALITY caseIgnoreMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )"

if [[ "$ATTR_DONE" -eq 1 ]]; then
    log "Attribute already present — skipping"
elif [[ "$ATTR_NEEDS_FIX" -eq 1 ]]; then
    # Replace Boolean with Directory String (delete old + add new)
    log "Replacing Boolean orclisenabled with Directory String..."
    ldapi_modify -f <(cat <<LDIFEOF
dn: ${SCHEMA_DN}
changetype: modify
delete: olcAttributeTypes
olcAttributeTypes: ${ATTR_BOOL_VAL}
-
add: olcAttributeTypes
olcAttributeTypes: ${ATTR_DEF}
LDIFEOF
    ) && { ok "Converted ${ATTR_NAME} from Boolean → Directory String"; PASS=$((PASS+1)); CHANGES=$((CHANGES+1)); ATTR_DONE=1; } \
      || { bad "Failed to update ${ATTR_NAME} syntax"; FAIL=$((FAIL+1)); }
elif [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY_RUN: would add: ${ATTR_DEF}"
else
    {
        echo "dn: ${SCHEMA_DN}"
        echo "changetype: modify"
        echo "add: olcAttributeTypes"
        echo "olcAttributeTypes: ${ATTR_DEF}"
    } >/tmp/add-orclisenabled.ldif

    if ldapi_modify -f /tmp/add-orclisenabled.ldif; then
        ok "Added attribute type: ${ATTR_NAME} (${ATTR_OID})"
        PASS=$((PASS+1)); CHANGES=$((CHANGES+1))
    else
        bad "Failed to add attribute type — check schema DN and server logs"
        FAIL=$((FAIL+1))
        fatal "Rollback: restore from backup: sudo bash $0 --restore ${BACKUP_FILE_CHECK:-$BACKUP_FILE}"
    fi
fi

# ── Step 5: Update bankUserExtension MAY list ──────────────────────
banner "Step 5: Update ${OC_NAME} MAY list"

if [[ "$OC_DONE" -eq 1 ]]; then
    log "${OC_NAME} already includes ${ATTR_NAME} — skipping"
elif [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY_RUN: would add ${ATTR_NAME} to ${OC_NAME} MAY list"
else
    # Re-fetch current OC in case state changed after Step 4
    schema_dump="$(ldapi_search -b "$SCHEMA_DN" -s base -LLL olcAttributeTypes olcObjectClasses || true)"
    current_oc="$(echo "$schema_dump" | grep "^olcObjectClasses:" | head -1)"

    if [[ -z "$current_oc" ]]; then
        fatal "${OC_NAME} object class not found in schema dump"
    fi

    # Try format: ... ) )$  → ... $ attr ) )
    NEW_OC="$(echo "$current_oc" | sed "s/ ) )$/ \$ ${ATTR_NAME} ) )/")"
    OC_VAL="${current_oc#olcObjectClasses: }"
    NEW_VAL="${NEW_OC#olcObjectClasses: }"

    log "Adding ${ATTR_NAME} to ${OC_NAME} MAY list..."

    {
        echo "dn: ${SCHEMA_DN}"
        echo "changetype: modify"
        echo "delete: olcObjectClasses"
        echo "olcObjectClasses: ${OC_VAL}"
        echo "-"
        echo "add: olcObjectClasses"
        echo "olcObjectClasses: ${NEW_VAL}"
    } >/tmp/update-oc.ldif

    OC_OK=0
    if ldapi_modify -f /tmp/update-oc.ldif 2>/tmp/update-oc-err.log; then
        ok "Updated ${OC_NAME} MAY list — added ${ATTR_NAME}"
        PASS=$((PASS+1)); CHANGES=$((CHANGES+1)); OC_OK=1
    else
        warn "Failed to update object class (format 1) — trying alternative format"

        # Alternative: single ) at end
        NEW_OC2="$(echo "$current_oc" | sed "s/ )$/ \$ ${ATTR_NAME} )/")"
        NEW_VAL2="${NEW_OC2#olcObjectClasses: }"

        {
            echo "dn: ${SCHEMA_DN}"
            echo "changetype: modify"
            echo "delete: olcObjectClasses"
            echo "olcObjectClasses: ${OC_VAL}"
            echo "-"
            echo "add: olcObjectClasses"
            echo "olcObjectClasses: ${NEW_VAL2}"
        } >/tmp/update-oc2.ldif

        if ldapi_modify -f /tmp/update-oc2.ldif; then
            ok "Updated ${OC_NAME} MAY list (alt format) — added ${ATTR_NAME}"
            PASS=$((PASS+1)); CHANGES=$((CHANGES+1)); OC_OK=1
        else
            bad "Could not update object class — both formats failed"
            FAIL=$((FAIL+1))
            warn "Manual check needed: ldapsearch -Y EXTERNAL -H ldapi:/// -b '${SCHEMA_DN}' -s base olcObjectClasses"
        fi
    fi
fi

# ── Step 6: Verify ──────────────────────────────────────────────────
banner "Step 6: Verify"

VERIFY_PASS=0
if [[ "$DRY_RUN" -eq 1 ]]; then
    ok "DRY_RUN: skipping verification"
    VERIFY_PASS=2
else
    if ldapi_verify_orclisenabled; then
        ok "Attribute '${ATTR_NAME}' present in schema"; VERIFY_PASS=1
    else
        bad "Attribute '${ATTR_NAME}' NOT found — check manually"
    fi

    if ldapi_verify_in_oc; then
        ok "'${ATTR_NAME}' referenced in object class"; VERIFY_PASS=$((VERIFY_PASS+1))
    else
        bad "'${ATTR_NAME}' NOT in object class MAY list"
    fi
fi

# ── Step 7: Functional test (create/read/delete with STARTTLS) ─────
banner "Step 7: Functional test"
TEST_DN="cn=test-orclisenabled-${TIMESTAMP},${BASE_DN}"

if [[ "$DRY_RUN" -eq 1 ]]; then
    ok "DRY_RUN: would create/verify/delete test entry ${TEST_DN}"
    FUNC_TEST_OK=1
elif [[ -z "${ADMIN_PW:-}" ]]; then
    warn "ADMIN_PW not set — skipping functional test"
    warn "Set ADMIN_PW to enable: sudo ADMIN_PW='...' bash $0 --force"
    FUNC_TEST_OK=1
else
    log "Creating test entry: ${TEST_DN}"

    cat >/tmp/test-orclisenabled.ldif <<LDIFF
dn: ${TEST_DN}
objectClass: organizationalRole
objectClass: bankUserExtension
cn: test-orclisenabled-${TIMESTAMP}
orclisenabled: TRUE
LDIFF

    add_output="$(LDAPTLS_REQCERT=never ldapadd -x -ZZ -D "${ADMIN_DN}" -w "${ADMIN_PW}" -f /tmp/test-orclisenabled.ldif 2>&1)"
    add_rc=$?

    if [[ "$add_rc" -eq 0 ]]; then
        ok "Created test entry"

        if LDAPTLS_REQCERT=never ldapsearch -x -ZZ -o ldif-wrap=no -D "${ADMIN_DN}" -w "${ADMIN_PW}" \
            -b "${TEST_DN}" -s base -LLL orclisenabled 2>/dev/null | grep -q "orclisenabled: TRUE"; then
            ok "Verified orclisenabled: TRUE in test entry"
            FUNC_TEST_OK=1; PASS=$((PASS+1))
        else
            bad "Could not read orclisenabled from test entry"
            FUNC_TEST_OK=0; FAIL=$((FAIL+1))
        fi

        if LDAPTLS_REQCERT=never ldapdelete -x -ZZ -D "${ADMIN_DN}" -w "${ADMIN_PW}" "${TEST_DN}" >/dev/null 2>&1; then
            ok "Cleaned up test entry"
        else
            warn "Could not delete test entry ${TEST_DN} — remove manually"
            WARN=$((WARN+1))
        fi

        rm -f /tmp/test-orclisenabled.ldif
    elif echo "$add_output" | grep -q "Referral\|referral\|read-only\|shadow context\|shadowServer"; then
        warn "Replica is read-only — referral to master (schema OK, can't write test entry)"
        FUNC_TEST_OK=1; WARN=$((WARN+1))
        rm -f /tmp/test-orclisenabled.ldif
    else
        bad "Failed to create test entry — check admin credentials and TLS"
        FAIL=$((FAIL+1))
        FUNC_TEST_OK=0
        rm -f /tmp/test-orclisenabled.ldif
    fi
fi

# Clean up stale test entries from any previous failed runs
for stale_dn in $(ldapi_search -b "${BASE_DN}" -s one -LLL "(cn=test-orclisenabled-*)" dn 2>/dev/null | awk '/^dn: /{print $2}'); do
    if [[ -n "${ADMIN_PW:-}" ]]; then
        LDAPTLS_REQCERT=never ldapdelete -x -ZZ -D "${ADMIN_DN}" -w "${ADMIN_PW}" "$stale_dn" >/dev/null 2>&1 || true
    fi
done

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  ADD orclisenabled — Complete"
echo "============================================================"
echo ""
echo "  Attribute:     ${ATTR_NAME} (${ATTR_OID})"
echo "  Schema:        ${SCHEMA_NAME}"
echo "  ObjectClass:   ${OC_NAME}"
echo "  Backup:        ${BACKUP_FILE_CHECK:-${BACKUP_FILE}}"
echo "  Changes made:  ${CHANGES}"
echo "  Pass: ${PASS}  Fail: ${FAIL}  Warn: ${WARN}"
echo ""

if [[ "$DRY_RUN" -eq 0 && -n "${BACKUP_FILE_CHECK:-}" ]]; then
    echo "  To rollback:"
    echo "    sudo bash $0 --restore ${BACKUP_FILE_CHECK}"
    echo ""
fi

echo "  To test:"
echo "    ldapsearch -Y EXTERNAL -H ldapi:/// -b '${SCHEMA_DN}' -s base olcAttributeTypes | grep ${ATTR_NAME}"
echo ""
echo "============================================================"

if [[ "${VERIFY_PASS:-0}" -lt 2 ]]; then
    exit 1
fi
exit 0
