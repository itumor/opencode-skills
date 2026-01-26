#!/usr/bin/env bash
set -euo pipefail

# Keepalived healthcheck helper.
#
# When keepalived runs in a container (even with host networking), it may not share
# the host PID namespace. A process-based check (pgrep slapd) can be unreliable.
# Instead, do a simple TCP connect to the local LDAP listener.
#
# Override with:
#   SLAPD_HOST=127.0.0.1 SLAPD_PORT=389

host="${1:-${SLAPD_HOST:-127.0.0.1}}"
port="${2:-${SLAPD_PORT:-389}}"

timeout 2 bash -lc "echo > /dev/tcp/${host}/${port}" >/dev/null 2>&1
