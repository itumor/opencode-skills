#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_EXAMPLEDB="${SCRIPT_DIR}/Exampledb/exampledb.sh"
TARGET_EXAMPLEDB="/opt/symas/share/symas/exampledb.sh"

if [[ ! -f "$CUSTOM_EXAMPLEDB" ]]; then
	echo "[FATAL] Custom exampledb.sh not found at ${CUSTOM_EXAMPLEDB}" >&2
	exit 1
fi

# Replace the vendor exampledb.sh with our customized suffix/domain version.
cp "$CUSTOM_EXAMPLEDB" "$TARGET_EXAMPLEDB"
chmod +x "$TARGET_EXAMPLEDB"

cd /opt/symas/share/symas

# Drive exampledb.sh non-interactively: choose slapd.conf (1), confirm erase (YES),
# skip test search (n). The bundled cn=config path can fail on newer Symas
# schema LDIFs, so we generate slapd.conf first and convert it with slaptest.
printf "1\nYES\nn\n" | "$TARGET_EXAMPLEDB"

systemctl stop symas-openldap-servers >/dev/null 2>&1 || systemctl stop slapd >/dev/null 2>&1 || true

SLAPD_CONF="/opt/symas/etc/openldap/slapd.conf"
CONFIG_DIR="/opt/symas/etc/openldap/slapd.d"

rm -rf "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
/opt/symas/sbin/slaptest -f "$SLAPD_CONF" -F "$CONFIG_DIR"

cat >/etc/default/symas-openldap <<EOF
SLAPD_URLS="ldap:/// ldapi:///"
SLAPD_OPTIONS="-F ${CONFIG_DIR}"
EOF

systemctl daemon-reload
systemctl enable --now symas-openldap-servers
