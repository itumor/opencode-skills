#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LDIF_DIR="${LDIF_DIR:-$ROOT/ldif}"

ADMIN_DN="${ADMIN_DN:-cn=admin,dc=cae,dc=local}"
ADMIN_PW="${ADMIN_PW:-admin}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1"
    exit 1
  }
}

need_cmd docker

require_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "Missing LDIF: $file"
    exit 1
  fi
}

apply_ldif() {
  local container="$1"
  local path="$2"
  shift 2
  require_file "$path"
  echo "Applying $(basename "$path") to ${container}"
  docker exec -i "$container" "$@" < "$path"
}

apply_ldif_idempotent() {
  local container="$1"
  local path="$2"
  shift 2
  require_file "$path"
  echo "Applying $(basename "$path") to ${container} (idempotent)"
  local out
  if ! out="$(docker exec -i "$container" "$@" < "$path" 2>&1)"; then
    if grep -qiE 'already exists|value #[0-9]+ already exists' <<<"$out"; then
      echo "  Skipping (already applied)"
      return 0
    fi
    echo "$out" >&2
    return 1
  fi
}

echo "Applying replication LDIFs from ${LDIF_DIR}"

apply_ldif_idempotent ldap-master-a "$LDIF_DIR/01-replicator.ldif" \
  ldapadd -x -H ldap://localhost:389 -D "$ADMIN_DN" -w "$ADMIN_PW"
apply_ldif_idempotent ldap-master-b "$LDIF_DIR/01-replicator.ldif" \
  ldapadd -x -H ldap://localhost:389 -D "$ADMIN_DN" -w "$ADMIN_PW"

apply_ldif ldap-master-a "$LDIF_DIR/02-replicator-acl.ldif" \
  ldapmodify -Y EXTERNAL -H ldapi:///
apply_ldif ldap-master-b "$LDIF_DIR/02-replicator-acl.ldif" \
  ldapmodify -Y EXTERNAL -H ldapi:///

apply_ldif ldap-master-a "$LDIF_DIR/10-serverid-master-a.ldif" \
  ldapmodify -Y EXTERNAL -H ldapi:///
apply_ldif ldap-master-b "$LDIF_DIR/11-serverid-master-b.ldif" \
  ldapmodify -Y EXTERNAL -H ldapi:///
apply_ldif ldap-replica-a "$LDIF_DIR/12-serverid-replica-a.ldif" \
  ldapmodify -Y EXTERNAL -H ldapi:///
apply_ldif ldap-replica-b "$LDIF_DIR/13-serverid-replica-b.ldif" \
  ldapmodify -Y EXTERNAL -H ldapi:///

apply_ldif_idempotent ldap-master-a "$LDIF_DIR/19-load-syncprov.ldif" \
  ldapmodify -Y EXTERNAL -H ldapi:///
apply_ldif_idempotent ldap-master-b "$LDIF_DIR/19-load-syncprov.ldif" \
  ldapmodify -Y EXTERNAL -H ldapi:///

apply_ldif_idempotent ldap-master-a "$LDIF_DIR/20-syncprov-master.ldif" \
  ldapadd -Y EXTERNAL -H ldapi:///
apply_ldif_idempotent ldap-master-b "$LDIF_DIR/20-syncprov-master.ldif" \
  ldapadd -Y EXTERNAL -H ldapi:///

apply_ldif ldap-master-a "$LDIF_DIR/21-mirrormode-master-a.ldif" \
  ldapmodify -Y EXTERNAL -H ldapi:///
apply_ldif ldap-master-b "$LDIF_DIR/22-mirrormode-master-b.ldif" \
  ldapmodify -Y EXTERNAL -H ldapi:///

apply_ldif ldap-replica-a "$LDIF_DIR/30-replica-consumer.ldif" \
  ldapmodify -Y EXTERNAL -H ldapi:///
apply_ldif ldap-replica-b "$LDIF_DIR/30-replica-consumer.ldif" \
  ldapmodify -Y EXTERNAL -H ldapi:///

apply_ldif ldap-replica-a "$LDIF_DIR/31-replica-readonly.ldif" \
  ldapmodify -Y EXTERNAL -H ldapi:///
apply_ldif ldap-replica-b "$LDIF_DIR/31-replica-readonly.ldif" \
  ldapmodify -Y EXTERNAL -H ldapi:///

echo "Replication configuration applied."
