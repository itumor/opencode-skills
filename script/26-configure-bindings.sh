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
require_cmd ldapadd
require_cmd ldapmodify
require_cmd ldapwhoami
require_cmd slappasswd

LDAPI_URI="${LDAPI_URI:-ldapi:///}"
LDAP_URI="${LDAP_URI:-ldap://localhost}"
VERIFY_STARTTLS="${VERIFY_STARTTLS:-1}"
LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"

BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"
TARGET_DB_DN="${TARGET_DB_DN:-}"
ADMIN_DN="${ADMIN_DN:-cn=admin,${BASE_DN}}"
ADMIN_PW="${ADMIN_PW:-}"

REPL_CN="${REPL_CN:-replicator}"
REPL_DN="${REPL_DN:-cn=${REPL_CN},${BASE_DN}}"
REPL_PW="${REPL_PW:-replpass}"
UPDATE_REPL_PW="${UPDATE_REPL_PW:-0}"

APPLY_REPL_USER="${APPLY_REPL_USER:-1}"
APPLY_REPL_ACL="${APPLY_REPL_ACL:-1}"
APPLY_SYNCPROV="${APPLY_SYNCPROV:-1}"
APPLY_SERVER_ID="${APPLY_SERVER_ID:-1}"
MASTER_SERVER_ID="${MASTER_SERVER_ID:-1}"
VERIFY_BINDS="${VERIFY_BINDS:-1}"

ldapsearch_attr() {
  local dn="$1"
  local attr="$2"
  ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" -b "$dn" -s base -LLL "$attr" 2>/dev/null \
    | awk -F': ' -v a="$attr" '$1==a {print $2; exit}'
}

detect_example_password() {
  local candidates=(
    "/opt/symas/share/symas/exampledb.sh"
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Exampledb/exampledb.sh"
  )
  local file pw
  for file in "${candidates[@]}"; do
    if [[ -f "$file" ]]; then
      pw=$(awk 'tolower($1) ~ /^(rootpw|olcrootpw:)$/ {print $2; exit}' "$file")
      if [[ -n "$pw" ]]; then
        echo "$pw"
        return 0
      fi
    fi
  done
  return 1
}

detect_db_dn() {
  ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -LLL "(&(objectClass=olcMdbConfig)(olcSuffix=${BASE_DN}))" dn 2>/dev/null \
    | awk '/^dn: /{print $2; exit}'
}

strip_olcaccess_index() {
  # Input: value part (after "olcAccess: "). Output: rule with any "{N}" prefix removed.
  awk '{sub(/^[[:space:]]*[{][0-9]+[}][[:space:]]*/, "", $0); print}'
}

check_cn_config() {
  if ! ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -s base -LLL dn >/dev/null 2>&1; then
    fatal "Cannot access cn=config using ${LDAPI_URI}"
  fi
}

ensure_repl_entry() {
  local pw_hash="$1"
  local admin_pw="${ADMIN_PW}"
  if [[ -z "$admin_pw" ]]; then
    admin_pw="$(detect_example_password || true)"
  fi
  [[ -n "$admin_pw" ]] || fatal "ADMIN_PW not set and could not detect password from exampledb.sh"

  # Build admin bind args - always use StartTLS when the server requires it.
  # We detect this by checking olcRequires on cn=config (needs EXTERNAL access).
  local requires_tls=0
  if ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -LLL '(objectClass=olcGlobal)' olcRequires 2>/dev/null \
       | grep -qi 'olcRequires.*tls\|olcRequires.*\bbind\b'; then
    requires_tls=1
  fi

  local ldap_args=( -x -H "$LDAP_URI" -D "$ADMIN_DN" -w "$admin_pw" )
  if [[ "$requires_tls" == "1" || "${VERIFY_STARTTLS:-1}" == "1" ]]; then
    ldap_args+=( -ZZ )
    export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-never}"
  fi

  # Use SASL EXTERNAL (ldapi) for existence check - avoids plain bind TLS requirement.
  if ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "$REPL_DN" -s base -LLL dn >/dev/null 2>&1; then
    log "Replication bind entry already exists: ${REPL_DN}"
    if [[ "$UPDATE_REPL_PW" == "1" ]]; then
      ldapmodify "${ldap_args[@]}" <<LDIF
dn: ${REPL_DN}
changetype: modify
replace: userPassword
userPassword: ${pw_hash}
LDIF
      log "Updated replication bind password on ${REPL_DN}"
    fi
    return 0
  fi

  ldapadd "${ldap_args[@]}" <<LDIF
dn: ${REPL_DN}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: ${REPL_CN}
userPassword: ${pw_hash}
description: Replication bind user
LDIF
  log "Created replication bind entry: ${REPL_DN}"
}

ensure_repl_acl() {
  local db_dn="$1"
  local want="to * by dn.exact=\"${REPL_DN}\" read by * break"

  current="$(ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" -b "$db_dn" -s base -LLL olcAccess 2>/dev/null || true)"
  if echo "$current" | grep -Eq "dn\\.exact=\\\"${REPL_DN//\//\\/}\\\"[[:space:]]+read"; then
    log "Replication ACL already present on ${db_dn}"
    return 0
  fi

  # Rebuild olcAccess list with the replicator rule first (index 0), preserving the remaining rules.
  mapfile -t old_rules < <(
    echo "$current" \
      | awk -F': ' '/^olcAccess: /{print $2}' \
      | strip_olcaccess_index \
      | sed '/^[[:space:]]*$/d' \
      | grep -Ev "dn\\.exact=\\\"${REPL_DN//\//\\/}\\\"" || true
  )

  new_rules=("$want")
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
  log "Configured replication read ACL on ${db_dn} for ${REPL_DN}"
}

verify_binds() {
  log "Verifying replication bind (${REPL_DN}) against ${LDAP_URI}"
  bind_args=( -x -H "$LDAP_URI" -D "$REPL_DN" -w "$REPL_PW" )
  if [[ "$VERIFY_STARTTLS" == "1" ]]; then
    bind_args+=( -ZZ )
    export LDAPTLS_REQCERT
  fi

  if ! ldapwhoami "${bind_args[@]}" >/dev/null 2>&1; then
    fatal "Replication bind failed for ${REPL_DN} (check REPL_DN/REPL_PW and ACLs)"
  fi

  if ! ldapsearch "${bind_args[@]}" -b "$BASE_DN" -s base -LLL dn >/dev/null 2>&1; then
    fatal "Replication bind can authenticate but cannot read ${BASE_DN} (check olcAccess ordering)"
  fi

  log "Replication bind verification passed"
}

check_cn_config

if [[ -z "$TARGET_DB_DN" ]]; then
  TARGET_DB_DN="$(detect_db_dn || true)"
fi
if [[ -z "$TARGET_DB_DN" ]]; then
  fatal "Could not locate target database DN for suffix ${BASE_DN}. Set TARGET_DB_DN to override."
fi

pw_hash="$(slappasswd -s "$REPL_PW")"

if [[ "$APPLY_REPL_USER" == "1" ]]; then
  ensure_repl_entry "$pw_hash"
else
  log "Skipping replication bind user creation (APPLY_REPL_USER=0)"
fi

if [[ "$APPLY_REPL_ACL" == "1" ]]; then
  ensure_repl_acl "$TARGET_DB_DN"
else
  log "Skipping replication ACL configuration (APPLY_REPL_ACL=0)"
fi

# ---------------------------------------------------------------------------
# olcServerID — set on master so replicas can identify the provider
# ---------------------------------------------------------------------------
if [[ "$APPLY_SERVER_ID" == "1" ]]; then
  current_sid="$(ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" \
    -b cn=config -s base -LLL olcServerID 2>/dev/null \
    | awk '/^olcServerID:/{print $2; exit}')"
  if [[ "$current_sid" == "$MASTER_SERVER_ID" ]]; then
    log "olcServerID already set to ${MASTER_SERVER_ID}"
  else
    op="replace"; [[ -z "$current_sid" ]] && op="add"
    ldapmodify -Y EXTERNAL -H "$LDAPI_URI" >/dev/null <<LDIF
dn: cn=config
changetype: modify
${op}: olcServerID
olcServerID: ${MASTER_SERVER_ID}
LDIF
    log "Set olcServerID to ${MASTER_SERVER_ID}"
  fi
else
  log "Skipping olcServerID configuration (APPLY_SERVER_ID=0)"
fi

# ---------------------------------------------------------------------------
# syncprov module + overlay — makes this node a replication provider
# ---------------------------------------------------------------------------
if [[ "$APPLY_SYNCPROV" == "1" ]]; then
  # Load syncprov module if not already loaded
  module_dn="$(ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" \
    -b cn=config -LLL '(objectClass=olcModuleList)' dn 2>/dev/null \
    | awk '/^dn:/{print $2; exit}')"
  if [[ -n "$module_dn" ]]; then
    existing_mods="$(ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" \
      -b "$module_dn" -s base -LLL olcModuleLoad 2>/dev/null || true)"
    if echo "$existing_mods" | grep -qi "syncprov"; then
      log "syncprov module already loaded"
    else
      ldapmodify -Y EXTERNAL -H "$LDAPI_URI" >/dev/null <<LDIF
dn: ${module_dn}
changetype: modify
add: olcModuleLoad
olcModuleLoad: syncprov.la
LDIF
      log "Loaded syncprov module in ${module_dn}"
    fi
  else
    warn "No olcModuleList found — skipping syncprov module load"
  fi

  # Add syncprov overlay to main database if not present
  existing_overlay="$(ldapsearch -o ldif-wrap=no -Y EXTERNAL -H "$LDAPI_URI" \
    -b "$TARGET_DB_DN" -s one -LLL '(objectClass=olcSyncProvConfig)' dn 2>/dev/null | grep '^dn:' || true)"
  if [[ -n "$existing_overlay" ]]; then
    log "syncprov overlay already present on ${TARGET_DB_DN}"
  else
    ldapadd -Y EXTERNAL -H "$LDAPI_URI" >/dev/null <<LDIF
dn: olcOverlay=syncprov,${TARGET_DB_DN}
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 100
LDIF
    log "Added syncprov overlay to ${TARGET_DB_DN}"
  fi
else
  log "Skipping syncprov configuration (APPLY_SYNCPROV=0)"
fi

if [[ "$VERIFY_BINDS" == "1" ]]; then
  verify_binds
else
  log "Skipping bind verification (VERIFY_BINDS=0)"
fi

log "Bindings configuration complete"
