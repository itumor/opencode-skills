#!/usr/bin/env bash
# scripts/openldap-fix/cleanup-openldap.sh
# Safe cleanup for Symas OpenLDAP on RHEL 9.
# Supports: --stop, --purge-db, --purge-config, --remove-pkgs, --all, --dry-run, --keep-data, --force
set -euo pipefail

log() { echo "[INFO]  $*"; }
warn_banner() {
  echo ""
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "  WARNING: DESTRUCTIVE ACTION — $*"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo ""
}

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "[FATAL] Run as root" >&2; exit 1; }

STOP=0; PURGE_DB=0; PURGE_CFG=0; REMOVE_PKGS=0; DRY_RUN=0; KEEP_DATA=0; FORCE=0

for arg in "$@"; do
  case "$arg" in
    --stop) STOP=1 ;;
    --purge-db) PURGE_DB=1 ;;
    --purge-config) PURGE_CFG=1 ;;
    --remove-pkgs) REMOVE_PKGS=1 ;;
    --all) STOP=1; PURGE_DB=1; PURGE_CFG=1; REMOVE_PKGS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --keep-data) KEEP_DATA=1 ;;
    --force) FORCE=1 ;;
    *) echo "Unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if [[ $((STOP + PURGE_DB + PURGE_CFG + REMOVE_PKGS)) -eq 0 ]]; then
  echo "Usage: $0 [--stop] [--purge-db] [--purge-config] [--remove-pkgs] [--all] [--dry-run] [--keep-data] [--force]" >&2
  exit 1
fi

detect_service() {
  for s in symas-openldap-servers slapd; do
    systemctl list-units --type=service 2>/dev/null | grep -qF "$s" && { echo "$s"; return; }
  done
  pgrep -x slapd >/dev/null 2>&1 && echo "slapd" || echo "symas-openldap-servers"
}
SLAPD_SVC=$(detect_service)
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="/tmp/openldap-cleanup-backup-${TS}.tar.gz"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY RUN — no changes will be made"
fi

# ── Backup before any destruction ──
if [[ "$PURGE_DB" -eq 1 || "$PURGE_CFG" -eq 1 || "$REMOVE_PKGS" -eq 1 ]]; then
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p /tmp/openldap-backup-${TS}
    [[ -d /opt/symas/etc/openldap/slapd.d ]] && cp -a /opt/symas/etc/openldap/slapd.d /tmp/openldap-backup-${TS}/slapd.d 2>/dev/null || true
    [[ -d /opt/symas/etc/openldap/tls ]] && cp -a /opt/symas/etc/openldap/tls /tmp/openldap-backup-${TS}/tls 2>/dev/null || true
    [[ -f /opt/symas/etc/openldap/slapd.conf ]] && cp /opt/symas/etc/openldap/slapd.conf /tmp/openldap-backup-${TS}/ 2>/dev/null || true
    tar czf "$BACKUP" -C /tmp "openldap-backup-${TS}" 2>/dev/null
    rm -rf "/tmp/openldap-backup-${TS}"
    if [[ -f "$BACKUP" ]]; then
      log "Backup: $BACKUP ($(du -h "$BACKUP" 2>/dev/null | cut -f1))"
    fi
  fi
fi

# ── Countdown ──
if [[ "$FORCE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
  warn_banner "About to perform destructive actions on ${SLAPD_SVC}"
  for i in 5 4 3 2 1; do echo "Continuing in $i..."; sleep 1; done
fi

# ── Stop service ──
if [[ "$STOP" -eq 1 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "(dry-run) Would stop ${SLAPD_SVC}"
  else
    systemctl stop "$SLAPD_SVC" 2>/dev/null && log "Stopped ${SLAPD_SVC}" || log "Service already stopped"
    systemctl disable "$SLAPD_SVC" 2>/dev/null || true
    log "Service disabled"
  fi
fi

# ── Purge database ──
if [[ "$PURGE_DB" -eq 1 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "(dry-run) Would wipe /var/symas/openldap-data/example/"
  else
    systemctl stop "$SLAPD_SVC" 2>/dev/null || true
    sleep 1
    rm -f /var/symas/openldap-data/example/data.mdb /var/symas/openldap-data/example/lock.mdb 2>/dev/null || true
    log "Wiped database files"
  fi
fi

# ── Purge config ──
if [[ "$PURGE_CFG" -eq 1 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "(dry-run) Would wipe /opt/symas/etc/openldap/slapd.d/"
  else
    systemctl stop "$SLAPD_SVC" 2>/dev/null || true; sleep 1
    rm -rf /opt/symas/etc/openldap/slapd.d/* 2>/dev/null || true
    log "Wiped cn=config directory"
    [[ "$KEEP_DATA" -eq 1 ]] || {
      rm -f /opt/symas/etc/openldap/slapd.conf /opt/symas/etc/openldap/ldap.conf 2>/dev/null || true
      log "Wiped slapd.conf/ldap.conf"
    }
  fi
fi

# ── Remove packages ──
if [[ "$REMOVE_PKGS" -eq 1 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "(dry-run) Would dnf remove symas-openldap-clients symas-openldap-servers"
  else
    systemctl stop "$SLAPD_SVC" 2>/dev/null || true; sleep 1
    dnf remove -y symas-openldap-clients symas-openldap-servers 2>/dev/null && \
      log "Symas packages removed" || log "Packages already removed or not installed"
  fi
fi

echo ""
echo "============================================================"
echo "  CLEANUP COMPLETE"
echo "  Backup: ${BACKUP}"
echo "  Rollback: tar xzf ${BACKUP} -C /opt/symas/etc/openldap/"
echo "============================================================"
