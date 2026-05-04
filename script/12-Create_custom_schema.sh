#!/usr/bin/env bash
set -euo pipefail

SCHEMA_NAME="${SCHEMA_NAME:-bank-custom}"
LDAPI_URI="${LDAPI_URI:-ldapi:///}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[FATAL] Must be run as root (SASL EXTERNAL over ldapi:///)" >&2
  exit 1
fi

if [[ -f /etc/profile.d/symas_env.sh ]]; then
  # shellcheck source=/etc/profile.d/symas_env.sh
  source /etc/profile.d/symas_env.sh
fi
if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
  export PATH="/opt/symas/bin:${PATH}"
fi

require_cmd() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[FATAL] ${bin} not found in PATH; ensure Symas OpenLDAP client tools are installed" >&2
    exit 1
  fi
}
require_cmd ldapsearch
require_cmd ldapadd

ldif_file="$(mktemp /tmp/create-custom-schema.XXXXXX.ldif)"
trap 'rm -f "$ldif_file"' EXIT

# OpenLDAP may rewrite the cn to include an ordering prefix like "{3}name".
if ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "cn=schema,cn=config" -LLL "(&(objectClass=olcSchemaConfig)(|(cn=${SCHEMA_NAME})(cn=*${SCHEMA_NAME})))" dn | grep -q '^dn: '; then
  echo "[INFO] Schema ${SCHEMA_NAME} already exists; skipping"
  exit 0
fi

cat >"$ldif_file" <<EOF
dn: cn=${SCHEMA_NAME},cn=schema,cn=config
objectClass: olcSchemaConfig
cn: ${SCHEMA_NAME}
EOF

ldapadd -Y EXTERNAL -H "$LDAPI_URI" -f "$ldif_file"

created_dn="$(
  ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "cn=schema,cn=config" -LLL "(&(objectClass=olcSchemaConfig)(cn=*${SCHEMA_NAME}))" dn \
    | awk '/^dn: /{print $2; exit}'
)"
echo "[OK] Created schema container: ${SCHEMA_NAME} (dn=${created_dn:-unknown})"
