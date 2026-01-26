#!/usr/bin/env bash
set -euo pipefail

# Returns 0 if slapd is running, non-zero otherwise.
if pgrep -x slapd >/dev/null 2>&1; then
  exit 0
fi

exit 1
