#!/bin/bash
set -euo pipefail

# Terminal bell
printf '\a'

# macOS system sound
if command -v afplay >/dev/null 2>&1; then
  afplay /System/Library/Sounds/Glass.aiff
else
  echo "afplay not found; bell should still ring if enabled."
fi
