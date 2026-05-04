#!/usr/bin/env bash
set -euo pipefail

# Ensure Symas tools are on PATH so ldapadd is found.
if [[ ":${PATH}:" != *":/opt/symas/bin:"* ]]; then
	PATH="/opt/symas/bin:${PATH}"
fi
LDAPADD="${LDAPADD:-$(command -v ldapadd || true)}"
if [[ -z "$LDAPADD" && -x /opt/symas/bin/ldapadd ]]; then
	LDAPADD=/opt/symas/bin/ldapadd
fi
if [[ -z "$LDAPADD" ]]; then
	echo "[FATAL] ldapadd not found; ensure Symas clients are installed" >&2
	exit 1
fi

#create the root OU
cat > /tmp/pw_load_module.ldif << 'EOF'
dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulePath: /opt/symas/lib/openldap
olcModuleLoad: ppolicy

EOF

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
	echo "[FATAL] Must be run as root (SASL EXTERNAL over ldapi:///)" >&2
	exit 1
fi

"$LDAPADD" -Y EXTERNAL -H ldapi:/// -f /tmp/pw_load_module.ldif
