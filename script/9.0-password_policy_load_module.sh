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

#add the overlay to the database
cat > /tmp/pw_add_overlay.ldif << 'EOF'
dn: olcOverlay=ppolicy,olcDatabase={1}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcPPolicyConfig
olcOverlay: ppolicy
EOF

ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/pw_add_overlay.ldif
#"$LDAPADD" -x -D "cn=config" -W -H ldap:/// -f /tmp/pw_load_module_db.ldif