#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  fatal "Run as root (required for ldapi:/// SASL/EXTERNAL)"
fi

ensure_symas_env() {
  local prof="/etc/profile.d/symas_env.sh"
  if [[ -f "$prof" ]]; then
    # shellcheck source=/etc/profile.d/symas_env.sh
    source "$prof"
  fi
  [[ ":${PATH}:" == *":/opt/symas/bin:"* ]] || PATH="/opt/symas/bin:${PATH}"
  [[ ":${PATH}:" == *":/opt/symas/sbin:"* ]] || PATH="/opt/symas/sbin:${PATH}"
  export PATH
  [[ -n "${LDAPCONF:-}" ]] || export LDAPCONF="/opt/symas/etc/openldap/ldap.conf"
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }

ensure_symas_env
require_cmd ldapsearch
require_cmd ldapmodify

LDAPI_URI="${LDAPI_URI:-ldapi:///}"

BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
USERS_OU_DN="${USERS_OU_DN:-ou=Users,${BASE_DN}}"
MW_DN="${MW_DN:-uid=mw,ou=ServiceAccounts,ou=Systems,${BASE_DN}}"

detect_db_dn() {
  ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -LLL "(&(objectClass=olcMdbConfig)(olcSuffix=${BASE_DN}))" dn 2>/dev/null \
    | awk '/^dn: /{print $2; exit}'
}

strip_olcaccess_index() {
  # Input: value part (after "olcAccess: "). Output: rule with any "{N}" prefix removed.
  awk '{sub(/^[[:space:]]*[{][0-9]+[}][[:space:]]*/, "", $0); print}'
}

db_dn="${TARGET_DB_DN:-}"
if [[ -z "$db_dn" ]]; then
  db_dn="$(detect_db_dn || true)"
fi
[[ -n "$db_dn" ]] || fatal "Could not locate target database DN for suffix ${BASE_DN}. Set TARGET_DB_DN to override."

want_rule="to dn.subtree=\"${USERS_OU_DN}\" by dn.exact=\"${MW_DN}\" write by * break"

current="$(
  ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" -b "$db_dn" -s base -LLL olcAccess 2>/dev/null || true
)"

if echo "$current" | grep -Eq "dn\\.exact=\\\"${MW_DN//\//\\/}\\\"[[:space:]]+write"; then
  log "MW write ACL already present on ${db_dn}"
  exit 0
fi

mapfile -t old_rules < <(
  echo "$current" \
    | awk -F': ' '/^olcAccess: /{print $2}' \
    | strip_olcaccess_index \
    | sed '/^[[:space:]]*$/d' \
    | grep -Ev "dn\\.exact=\\\"${MW_DN//\//\\/}\\\"" || true
)

new_rules=("$want_rule")
for r in "${old_rules[@]}"; do
  new_rules+=("$r")
done

ldif="dn: ${db_dn}"$'\n'"changetype: modify"$'\n'"replace: olcAccess"
idx=0
for r in "${new_rules[@]}"; do
  ldif+=$'\n'"olcAccess: {${idx}}${r}"
  idx=$((idx + 1))
done

echo "$ldif" | ldapmodify -Y EXTERNAL -H "$LDAPI_URI" >/dev/null
log "Configured MW write ACL on ${db_dn} for subtree ${USERS_OU_DN} (mw=${MW_DN})"
