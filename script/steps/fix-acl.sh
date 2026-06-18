#!/usr/bin/env bash
# steps/fix-acl.sh — Fix ldapi ACL for cn=config
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/ldap-ops.sh"
require_root; setup_path
banner "Fix: LDAPI ACL"
section "Fix: cn=config ACL"
ldapi_modify <<LDIF 2>/dev/null && ok "SASL/EXTERNAL manage ACL fixed" || warn "ACL fix failed"
dn: olcDatabase={0}config,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to * by * none
olcAccess: {1}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * none
LDIF
summary
