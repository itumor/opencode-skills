#!/usr/bin/env bash
set -euo pipefail

# Convenience runner:
#   Level 1 (terraform) -> bootstrap rerun (SSM) -> Level 2 E2E (SSM).
#
# Default behavior is NON-DESTRUCTIVE (plan only). Use --apply to converge infra.

REGION="us-east-1"
DO_APPLY="0"

usage() {
  cat <<'USAGE' >&2
Usage:
  e2e_all.sh [region] [--apply]

Examples:
  bash terraform/openldap/tools/e2e_all.sh us-east-1
  bash terraform/openldap/tools/e2e_all.sh us-east-1 --apply
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -n "${1:-}" && "${1:-}" != --* ]]; then
  REGION="$1"
  shift
fi

for arg in "$@"; do
  case "$arg" in
    --apply) DO_APPLY="1" ;;
    *)
      echo "unknown argument: $arg" >&2
      usage
      exit 2
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

if [[ "$DO_APPLY" == "1" ]]; then
  bash terraform/openldap/tools/e2e_level1_terraform.sh "$REGION" --apply
else
  bash terraform/openldap/tools/e2e_level1_terraform.sh "$REGION"
fi

# Even if terraform didn't replace instances, re-run bootstrap to converge scripts/ldif on-box.
bash terraform/openldap/tools/rerun_bootstrap_all_ssm.sh "$REGION"

# Run the validation suite.
bash terraform/openldap/tools/e2e_level2_ssm.sh "$REGION"

