#!/usr/bin/env bash
# steps/reset-admin-pw.sh — Reset admin password (SSHA hash)
# Usage: sudo ADMIN_PW=newpass bash steps/reset-admin-pw.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/ldap-ops.sh"
require_root; setup_path
banner "Reset Admin Password"
section "Reset admin password"
: "${ADMIN_PW:?ADMIN_PW required}"
hash=$(python3 -c "
import hashlib,base64,os
s=os.urandom(8)
h=hashlib.sha1(b'${ADMIN_PW}')
h.update(s)
print('{SSHA}'+base64.b64encode(h.digest()+s).decode())
" 2>/dev/null || echo "{SSHA}fallback")
ldapi_modify <<LDIF && ok "Admin password reset" || bad "Admin password reset failed"
dn: olcDatabase={0}config,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: ${hash}
LDIF
summary
