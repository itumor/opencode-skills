#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
fatal() { echo "[FATAL] $*" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  fatal "Run as root"
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"
}

apply_ldif() {
  local ldif="$1"
  local file
  file="$(mktemp /tmp/accesslog.XXXXXX.ldif)"
  printf '%s\n' "$ldif" >"$file"
  ldapmodify -Y EXTERNAL -H "$LDAPI_URI" -f "$file"
  rm -f "$file"
}

ensure_symas_env
require_cmd ldapsearch
require_cmd ldapadd
require_cmd ldapmodify

LDAPI_URI="${LDAPI_URI:-ldapi:///}"
ACCESSLOG_SUFFIX="${ACCESSLOG_SUFFIX:-cn=accesslog}"
ACCESSLOG_DB_DIR="${ACCESSLOG_DB_DIR:-/opt/symas/var/openldap-accesslog}"
ACCESSLOG_DB_MAXSIZE="${ACCESSLOG_DB_MAXSIZE:-1073741824}"
ACCESSLOG_PURGE="${ACCESSLOG_PURGE:-30+00:00 01+00:00}"
ACCESSLOG_OPS="${ACCESSLOG_OPS:-writes reads session}"
TARGET_SUFFIX="${TARGET_SUFFIX:-}"
TARGET_DB_DN="${TARGET_DB_DN:-}"

if ! ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -s base -LLL dn >/dev/null 2>&1; then
  fatal "Cannot access cn=config using ${LDAPI_URI}"
fi

module_dn="$(
  ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -LLL '(objectClass=olcModuleList)' dn \
    | awk '/^dn: /{print $2; exit}'
)"
if [[ -z "$module_dn" ]]; then
  fatal "Could not locate module list in cn=config"
fi

module_dump="$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "$module_dn" -s base -LLL olcModuleLoad || true)"
if ! echo "$module_dump" | grep -Eiq '^olcModuleLoad: (.*\/)?accesslog(\.la)?$'; then
  apply_ldif "$(cat <<EOF
dn: ${module_dn}
changetype: modify
add: olcModuleLoad
olcModuleLoad: accesslog
EOF
)"
  log "Loaded accesslog module in ${module_dn}"
else
  log "accesslog module already loaded in ${module_dn}"
fi

accesslog_db_dn="$(
  ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -LLL "(&(objectClass=olcMdbConfig)(olcSuffix=${ACCESSLOG_SUFFIX}))" dn \
    | awk '/^dn: /{print $2; exit}'
)"

if [[ -z "$accesslog_db_dn" ]]; then
  mkdir -p "$ACCESSLOG_DB_DIR"
  chmod 700 "$ACCESSLOG_DB_DIR"

  # slapd runs as ldap:ldap; ensure it can access the database directory.
  if id ldap >/dev/null 2>&1; then
    chown -R ldap:ldap "$ACCESSLOG_DB_DIR"
  fi

  # Best-effort SELinux labeling (non-fatal if tools are missing).
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -RF "$ACCESSLOG_DB_DIR" >/dev/null 2>&1 || true
  fi
  if command -v chcon >/dev/null 2>&1; then
    chcon -Rt slapd_db_t "$ACCESSLOG_DB_DIR" >/dev/null 2>&1 || true
  fi

    next_index="$(
      ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -LLL '(objectClass=olcMdbConfig)' dn \
      | awk '
          match($0, /^dn: olcDatabase=[{]([0-9]+)[}]mdb,cn=config$/, m) { print m[1] }
        ' \
      | sort -n \
      | tail -n 1
  )"
  [[ -n "$next_index" ]] || next_index=0
  next_index=$((next_index + 1))
  accesslog_db_dn="olcDatabase={${next_index}}mdb,cn=config"

  ldapadd -Y EXTERNAL -H "$LDAPI_URI" -f /dev/stdin <<EOF
dn: ${accesslog_db_dn}
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: {${next_index}}mdb
olcSuffix: ${ACCESSLOG_SUFFIX}
olcRootDN: cn=accesslog-admin,${ACCESSLOG_SUFFIX}
olcDbDirectory: ${ACCESSLOG_DB_DIR}
olcDbMaxSize: ${ACCESSLOG_DB_MAXSIZE}
olcDbIndex: reqStart eq
olcDbIndex: reqEnd eq
olcDbIndex: reqResult eq
olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * none
EOF
  log "Created accesslog database at ${accesslog_db_dn}"
else
  log "Accesslog database already exists at ${accesslog_db_dn}"
fi

if [[ -z "$TARGET_DB_DN" ]]; then
  if [[ -n "$TARGET_SUFFIX" ]]; then
    TARGET_DB_DN="$(
      ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -LLL "(&(objectClass=olcMdbConfig)(olcSuffix=${TARGET_SUFFIX}))" dn \
        | awk '/^dn: /{print $2; exit}'
    )"
  else
    TARGET_DB_DN="$(
      ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b cn=config -LLL '(objectClass=olcMdbConfig)' dn olcSuffix \
        | awk -v access_suffix="$ACCESSLOG_SUFFIX" '
            /^dn: / {dn=$2}
            /^olcSuffix: / {
              if ($2 != access_suffix) {
                print dn
                exit
              }
            }'
    )"
  fi
fi

if [[ -z "$TARGET_DB_DN" ]]; then
  fatal "Could not locate target user database. Set TARGET_DB_DN or TARGET_SUFFIX and retry."
fi

overlay_dn="$(
  ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "$TARGET_DB_DN" -LLL '(olcOverlay=accesslog)' dn \
    | awk '/^dn: /{print $2; exit}'
)"

if [[ -z "$overlay_dn" ]]; then
  requested_dn="olcOverlay=accesslog,${TARGET_DB_DN}"
  ldapadd -Y EXTERNAL -H "$LDAPI_URI" -f /dev/stdin <<EOF
dn: ${requested_dn}
objectClass: olcOverlayConfig
objectClass: olcAccessLogConfig
olcOverlay: accesslog
olcAccessLogDB: ${ACCESSLOG_SUFFIX}
olcAccessLogPurge: ${ACCESSLOG_PURGE}
EOF
  # OpenLDAP may rewrite overlay DNs to include an ordering prefix like "{0}".
  overlay_dn="$(
    ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "$TARGET_DB_DN" -LLL '(olcOverlay=accesslog)' dn \
      | awk '/^dn: /{print $2; exit}'
  )"
  [[ -n "$overlay_dn" ]] || fatal "Accesslog overlay creation succeeded but DN could not be discovered (requested: ${requested_dn})"
  log "Created accesslog overlay on ${TARGET_DB_DN}"
else
  log "Accesslog overlay already exists on ${TARGET_DB_DN}"
fi

ops_ldif="$(cat <<EOF
dn: ${overlay_dn}
changetype: modify
replace: olcAccessLogDB
olcAccessLogDB: ${ACCESSLOG_SUFFIX}
-
replace: olcAccessLogPurge
olcAccessLogPurge: ${ACCESSLOG_PURGE}
-
replace: olcAccessLogOps
EOF
)"

for op in $ACCESSLOG_OPS; do
  ops_ldif="${ops_ldif}"$'\n'"olcAccessLogOps: ${op}"
done

apply_ldif "$ops_ldif"

log "Configured accesslog ops: ${ACCESSLOG_OPS}"
log "Audit overlay setup complete"
