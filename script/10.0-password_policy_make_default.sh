#!/usr/bin/env bash
set -euo pipefail

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

BASE_DN="${BASE_DN:-dc=eab,dc=bank,dc=local}"

# Dynamically find the ppolicy overlay DN (index may vary if syncprov loaded first)
ppolicy_dn=$(ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b cn=config -s sub "(objectClass=olcPPolicyConfig)" dn 2>/dev/null \
  | awk '/^dn:/{print $2; exit}')

if [[ -z "$ppolicy_dn" ]]; then
  echo "[FATAL] ppolicy overlay not found in cn=config — run 9.0-password_policy_load_module.sh first"
  exit 1
fi

echo "[INFO] Setting pwdPolicyDefault on ${ppolicy_dn}"

cat > /tmp/pw_default.ldif <<EOF
dn: ${ppolicy_dn}
changetype: modify
add: olcPPolicyDefault
olcPPolicyDefault: cn=default,ou=Policies,${BASE_DN}
EOF

ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/pw_default.ldif
rm -f /tmp/pw_default.ldif
