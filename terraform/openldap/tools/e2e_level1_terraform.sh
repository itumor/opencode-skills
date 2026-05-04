#!/usr/bin/env bash
set -euo pipefail

# Level 1: Terraform workflow for terraform/openldap.
# - Loads AWS creds from terraform/key.aws.text (expects export AWS_* lines).
# - Runs init + plan by default.
# - If --apply is provided, runs apply.
# - Always writes a terraform outputs snapshot consumed by Level 2.

REGION="us-east-1"
DO_APPLY="0"

usage() {
  cat <<'USAGE' >&2
Usage:
  e2e_level1_terraform.sh [region] [--apply]

Examples:
  bash terraform/openldap/tools/e2e_level1_terraform.sh us-east-1
  bash terraform/openldap/tools/e2e_level1_terraform.sh us-east-1 --apply
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

eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"
export AWS_REGION="${AWS_REGION:-$REGION}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$REGION}"

RUN_DATE_UTC="$(date -u +%Y-%m-%d)"
RUN_STAMP_UTC="$(date -u +%Y%m%dT%H%M%SZ)"

TF_DIR="terraform/openldap"
LOG_DIR="reports/logs"
mkdir -p "$LOG_DIR"

INIT_LOG="${LOG_DIR}/terraform_openldap_init_${RUN_STAMP_UTC}.txt"
PLAN_LOG="${LOG_DIR}/terraform_openldap_plan_${RUN_STAMP_UTC}.txt"
APPLY_LOG="${LOG_DIR}/terraform_openldap_apply_${RUN_STAMP_UTC}.txt"
OUT_JSON="${LOG_DIR}/terraform_openldap_outputs_${RUN_DATE_UTC}.json"

terraform -chdir="$TF_DIR" init -input=false -no-color >"$INIT_LOG" 2>&1
terraform -chdir="$TF_DIR" plan -no-color >"$PLAN_LOG" 2>&1

if [[ "$DO_APPLY" == "1" ]]; then
  terraform -chdir="$TF_DIR" apply -auto-approve -no-color >"$APPLY_LOG" 2>&1
fi

terraform -chdir="$TF_DIR" output -json >"$OUT_JSON"

echo "level1.init_log=${INIT_LOG}"
echo "level1.plan_log=${PLAN_LOG}"
if [[ "$DO_APPLY" == "1" ]]; then
  echo "level1.apply_log=${APPLY_LOG}"
fi
echo "level1.outputs_json=${OUT_JSON}"

