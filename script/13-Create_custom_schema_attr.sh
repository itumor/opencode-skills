#!/usr/bin/env bash
set -euo pipefail

SCHEMA_NAME="${SCHEMA_NAME:-bank-custom}"
OID_ROOT="${OID_ROOT:-1.3.6.1.4.1.55555}"
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
require_cmd ldapmodify

ATTR_USER_ACTIVE="${ATTR_USER_ACTIVE:-userisactive}"
ATTR_MEM_ANSWER="${ATTR_MEM_ANSWER:-memorableAnswer}"
ATTR_MEM_QUESTION="${ATTR_MEM_QUESTION:-memorableQuestion}"
ATTR_ACTIVATION_DT="${ATTR_ACTIVATION_DT:-activationdatetime}"
ATTR_CIF="${ATTR_CIF:-cif}"
OBJECTCLASS_NAME="${OBJECTCLASS_NAME:-bankUserExtension}"

SCHEMA_DN="$(
  # OpenLDAP may rewrite the cn to include an ordering prefix like "{3}name".
  ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "cn=schema,cn=config" -LLL "(&(objectClass=olcSchemaConfig)(|(cn=${SCHEMA_NAME})(cn=*${SCHEMA_NAME})))" dn \
    | awk '/^dn: /{print $2; exit}'
)"

if [[ -z "$SCHEMA_DN" ]]; then
  echo "[FATAL] Schema ${SCHEMA_NAME} not found. Run 12-Create_custom_schema.sh first." >&2
  exit 1
fi

schema_dump="$(ldapsearch -Y EXTERNAL -H "$LDAPI_URI" -b "$SCHEMA_DN" -s base -LLL olcAttributeTypes olcObjectClasses || true)"

if echo "$schema_dump" | grep -Fq "NAME '${OBJECTCLASS_NAME}'"; then
  echo "[INFO] ObjectClass ${OBJECTCLASS_NAME} already exists; skipping"
  exit 0
fi

ldif_file="$(mktemp /tmp/add-schema-attr.XXXXXX.ldif)"
cat >"$ldif_file" <<EOF
dn: ${SCHEMA_DN}
changetype: modify
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.1 NAME 'userisactive' DESC 'User active flag' EQUALITY booleanMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.7 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.2 NAME 'memorableanswer' DESC 'Memorable answer' EQUALITY caseExactMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.3 NAME 'memorablequestion' DESC 'Memorable question' EQUALITY caseIgnoreMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.4 NAME 'activationdatetime' DESC 'Account activation timestamp in milliseconds (13 digits)' EQUALITY caseExactMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.5 NAME 'cif' DESC 'Customer Information File ID' EQUALITY caseExactMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.12 NAME 'lastvisit' DESC 'Last visit timestamp in milliseconds (13 digits)' EQUALITY caseExactMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.13 NAME 'oblastloginattemptdate' DESC 'Last login attempt datetime' EQUALITY generalizedTimeMatch ORDERING generalizedTimeOrderingMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.24 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.14 NAME 'oblastfailedlogin' DESC 'Last failed login timestamp in seconds (10 digits)' EQUALITY caseExactMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.15 NAME 'userfullname' DESC 'User full name' EQUALITY caseIgnoreMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcObjectClasses
olcObjectClasses: ( 1.3.6.1.4.1.55555.2.1 NAME 'bankUserExtension' SUP top AUXILIARY MAY ( userisactive $ memorableAnswer $ memorableQuestion $ activationdatetime $ cif $ mail $ lastvisit $ oblastloginattemptdate $ oblastfailedlogin $ userfullname ) )
EOF

ldapmodify -Y EXTERNAL -H "$LDAPI_URI" -f "$ldif_file"
rm -f "$ldif_file"
echo "[OK] Added custom attributes and objectClass ${OBJECTCLASS_NAME}"
exit 0

add_attribute_type() {
  local oid="$1"
  local name="$2"
  local desc="$3"
  local equality="$4"
  local syntax="$5"
  local extras="${6:-}"

  if echo "$schema_dump" | grep -Fq "NAME '${name}'"; then
    echo "[INFO] Attribute ${name} already exists; skipping"
    return 0
  fi

  local ldif_file
  ldif_file="$(mktemp /tmp/add-schema-attr.XXXXXX.ldif)"

  cat >"$ldif_file" <<EOF
dn: ${SCHEMA_DN}
changetype: modify
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.1 NAME 'userisactive' DESC 'User active flag' EQUALITY booleanMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.7 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.2 NAME 'memorableanswer' DESC 'Memorable answer' EQUALITY caseExactMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.3 NAME 'memorablequestion' DESC 'Memorable question' EQUALITY caseIgnoreMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.4 NAME 'activationdatetime' DESC 'Account activation timestamp in milliseconds (13 digits)' EQUALITY caseExactMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.5 NAME 'cif' DESC 'Customer Information File ID' EQUALITY caseExactMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.11 NAME 'mail' DESC 'Email address' EQUALITY caseIgnoreMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.12 NAME 'lastvisit' DESC 'Last visit timestamp in milliseconds (13 digits)' EQUALITY caseExactMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.13 NAME 'oblastloginattemptdate' DESC 'Last login attempt datetime' EQUALITY generalizedTimeMatch ORDERING generalizedTimeOrderingMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.24 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.14 NAME 'oblastfailedlogin' DESC 'Last failed login timestamp in seconds (10 digits)' EQUALITY caseExactMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcAttributeTypes
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.15 NAME 'userfullname' DESC 'User full name' EQUALITY caseIgnoreMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
-
add: olcObjectClasses
olcObjectClasses: ( 1.3.6.1.4.1.55555.2.1 NAME 'bankUserExtension' SUP top AUXILIARY MAY ( userisactive $ memorableAnswer $ memorableQuestion $ activationdatetime $ cif $ mail $ lastvisit $ oblastloginattemptdate $ oblastfailedlogin $ userfullname ) )
EOF

  ldapmodify -Y EXTERNAL -H "$LDAPI_URI" -f "$ldif_file"
  rm -f "$ldif_file"
  echo "[OK] Added objectClass ${name} (${oid})"
}

add_attribute_type "${OID_ROOT}.1.1" "$ATTR_USER_ACTIVE" "User active flag" "booleanMatch" "1.3.6.1.4.1.1466.115.121.1.7"
add_attribute_type "${OID_ROOT}.1.2" "$ATTR_MEM_ANSWER" "Memorable answer" "caseExactMatch" "1.3.6.1.4.1.1466.115.121.1.15"
add_attribute_type "${OID_ROOT}.1.3" "$ATTR_MEM_QUESTION" "Memorable question" "caseIgnoreMatch" "1.3.6.1.4.1.1466.115.121.1.15"
add_attribute_type "${OID_ROOT}.1.4" "$ATTR_ACTIVATION_DT" "Account activation datetime" "generalizedTimeMatch" "1.3.6.1.4.1.1466.115.121.1.24" "ORDERING generalizedTimeOrderingMatch"
add_attribute_type "${OID_ROOT}.1.5" "$ATTR_CIF" "Customer Information File ID" "caseExactMatch" "1.3.6.1.4.1.1466.115.121.1.15"
add_object_class "${OID_ROOT}.2.1" "$OBJECTCLASS_NAME"
