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

# Drive exampledb.sh non-interactively: choose cn=config (2), confirm erase (YES), skip test search (n).
printf "2\nYES\nn\n" | "$TARGET_EXAMPLEDB"