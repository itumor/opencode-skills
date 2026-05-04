#!/usr/bin/env bash
set -euo pipefail

# Ensure Symas tools are on PATH so ldapsearch is found.
if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
  PATH="/opt/symas/bin:${PATH}"
fi

LDAPSEARCH="${LDAPSEARCH:-$(command -v ldapsearch || true)}"
if [[ -z "$LDAPSEARCH" ]]; then
  echo "[FATAL] ldapsearch not found in PATH" >&2
  exit 1
fi

LDAPI_URI="${LDAPI_URI:-ldapi:///}"
ACCESSLOG_SUFFIX="${ACCESSLOG_SUFFIX:-cn=accesslog}"

db_dn="$($LDAPSEARCH -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -LLL "(&(objectClass=olcMdbConfig)(olcSuffix=${ACCESSLOG_SUFFIX}))" dn | awk '/^dn: /{print $2; exit}')"
if [[ -z "$db_dn" ]]; then
  echo "[FAIL] Accesslog database not found for suffix ${ACCESSLOG_SUFFIX}" >&2
  exit 1
fi
echo "[PASS] Accesslog database exists at ${db_dn}"

overlay_dn="$($LDAPSEARCH -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -LLL '(olcOverlay=accesslog)' dn | awk '/^dn: /{print $2; exit}')"
if [[ -z "$overlay_dn" ]]; then
  echo "[FAIL] Accesslog overlay not found under cn=config" >&2
  exit 1
fi
echo "[PASS] Accesslog overlay exists at ${overlay_dn}"

overlay_dump="$($LDAPSEARCH -Y EXTERNAL -H "$LDAPI_URI" -b "$overlay_dn" -s base -LLL olcAccessLogOps olcAccessLogDB)"
if ! echo "$overlay_dump" | grep -q "^olcAccessLogDB: ${ACCESSLOG_SUFFIX}$"; then
  echo "[FAIL] Accesslog overlay is not writing to ${ACCESSLOG_SUFFIX}" >&2
  exit 1
fi

for op in writes reads session; do
  if ! echo "$overlay_dump" | grep -q "^olcAccessLogOps: ${op}$"; then
    echo "[FAIL] Missing accesslog op: ${op}" >&2
    exit 1
  fi
done

echo "[SUCCESS] Accesslog audit configuration verification completed"
