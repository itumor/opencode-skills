#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-}"
if [[ -z "$SERVICE_NAME" ]]; then
  if systemctl list-unit-files --type=service --no-pager --no-legend 'symas-openldap-servers.service' 2>/dev/null | awk '{print $1}' | grep -qx 'symas-openldap-servers.service'; then
    SERVICE_NAME="symas-openldap-servers"
  elif systemctl list-unit-files --type=service --no-pager --no-legend 'slapd.service' 2>/dev/null | awk '{print $1}' | grep -qx 'slapd.service'; then
    SERVICE_NAME="slapd"
  elif systemctl status symas-openldap-servers >/dev/null 2>&1; then
    SERVICE_NAME="symas-openldap-servers"
  elif systemctl status slapd >/dev/null 2>&1; then
    SERVICE_NAME="slapd"
  else
    echo "[FATAL] Could not detect service name; set SERVICE_NAME" >&2
    exit 1
  fi
fi

LIMIT_NOFILE_EXPECTED="${LIMIT_NOFILE:-524288}"
DEFAULTS_FILE="${DEFAULTS_FILE:-/etc/default/symas-openldap}"
DROPIN_FILE="/etc/systemd/system/${SERVICE_NAME}.service.d/override.conf"

echo "[INFO] Checking systemd drop-in: $DROPIN_FILE"
if [[ ! -f "$DROPIN_FILE" ]]; then
  echo "[FAIL] Missing $DROPIN_FILE" >&2
  exit 1
fi

if grep -q "^LimitNOFILE=${LIMIT_NOFILE_EXPECTED}$" "$DROPIN_FILE"; then
  echo "[PASS] LimitNOFILE set to $LIMIT_NOFILE_EXPECTED"
else
  echo "[FAIL] LimitNOFILE not set to $LIMIT_NOFILE_EXPECTED" >&2
  exit 1
fi

if [[ -n "${SLAPD_URLS:-}" ]]; then
  if [[ ! -f "$DEFAULTS_FILE" ]]; then
    echo "[FAIL] Missing $DEFAULTS_FILE while SLAPD_URLS was set" >&2
    exit 1
  fi

  if grep -q "^SLAPD_URLS=\"${SLAPD_URLS}\"$" "$DEFAULTS_FILE"; then
    echo "[PASS] SLAPD_URLS matches $DEFAULTS_FILE"
  else
    echo "[FAIL] SLAPD_URLS does not match $DEFAULTS_FILE" >&2
    exit 1
  fi
else
  echo "[INFO] SLAPD_URLS not provided; skipping check"
fi

if [[ -n "${SLAPD_OPTIONS:-}" ]]; then
  if [[ ! -f "$DEFAULTS_FILE" ]]; then
    echo "[FAIL] Missing $DEFAULTS_FILE while SLAPD_OPTIONS was set" >&2
    exit 1
  fi

  if grep -q "^SLAPD_OPTIONS=\"${SLAPD_OPTIONS}\"$" "$DEFAULTS_FILE"; then
    echo "[PASS] SLAPD_OPTIONS matches $DEFAULTS_FILE"
  else
    echo "[FAIL] SLAPD_OPTIONS does not match $DEFAULTS_FILE" >&2
    exit 1
  fi
else
  echo "[INFO] SLAPD_OPTIONS not provided; skipping check"
fi

echo "[SUCCESS] Tuning verification completed"
