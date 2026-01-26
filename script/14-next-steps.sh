#!/usr/bin/env bash
set -euo pipefail

next_steps=(
  "15 - add password checker"
  "16 - add strong password quality checker PPM"
  "17 - create the mw user under service account"
  "18 - create the service account password policy with never expire"
  "19 - create user using the mw user"
  "20 - create migration script (make it empty for now)"
  "21 - hardening"
  "22 - tuning"
  "23 - ensure installation not under root"
  "24 - configure SSL/TLS"
)

printf '%s\n' "${next_steps[@]}"
exit 0
