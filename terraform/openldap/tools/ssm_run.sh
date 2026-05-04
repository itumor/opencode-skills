#!/usr/bin/env bash
set -euo pipefail

# Run an AWS SSM RunShellScript command on a single instance, wait for completion,
# and write a JSON log under reports/logs.

if [[ $# -lt 4 ]]; then
  echo "usage: $0 <region> <instance-id> <name> <action> [comment]" >&2
  echo "Reads commands from stdin (one command per line)." >&2
  exit 2
fi

REGION="$1"
INSTANCE_ID="$2"
NAME="$3"
ACTION="$4"
COMMENT="${5:-}"
export REGION INSTANCE_ID COMMENT

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LOG_DIR="${REPO_ROOT}/reports/logs"
mkdir -p "$LOG_DIR"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
REQ_JSON="${LOG_DIR}/ssm_${NAME}_${ACTION}_${TS}.request.json"
RES_JSON="${LOG_DIR}/ssm_${NAME}_${ACTION}_${TS}.result.json"
INV_JSON="${LOG_DIR}/ssm_${NAME}_${ACTION}_${TS}.invocation.json"

# Read stdin into a list of commands.
CMDS_FILE="$(mktemp)"
cat >"$CMDS_FILE"
export CMDS_FILE

python3 - <<PY >"$REQ_JSON"
import json, os
instance_id=os.environ['INSTANCE_ID']
comment=os.environ.get('COMMENT','')
region=os.environ['REGION']
with open(os.environ['CMDS_FILE'], 'r', encoding='utf-8') as f:
    cmds=[line.rstrip('\n') for line in f if line.rstrip('\n')!='']
if not cmds:
    raise SystemExit('no commands provided on stdin')
payload={
  "InstanceIds": [instance_id],
  "DocumentName": "AWS-RunShellScript",
  "TimeoutSeconds": 3600,
  "Comment": comment,
  "Parameters": {"commands": cmds},
}
print(json.dumps(payload, indent=2))
PY

CMD_ID="$(aws ssm send-command --region "$REGION" --cli-input-json "file://${REQ_JSON}" --output json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Command"]["CommandId"])')"

# Wait for completion; poll to also persist the invocation payload.
DEADLINE=$(( $(date +%s) + 3600 ))
STATUS=""
while :; do
  tmp_inv="$(mktemp)"
  if aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" --output json >"$tmp_inv" 2>/dev/null; then
    # Avoid clobbering the last good file with an empty/partial write.
    if [[ -s "$tmp_inv" ]]; then
      mv "$tmp_inv" "$INV_JSON"
    else
      rm -f "$tmp_inv"
    fi
  else
    rm -f "$tmp_inv"
  fi
  STATUS="$(python3 -c 'import json; import sys
p=sys.argv[1]
try:
  d=json.load(open(p))
  print(d.get("Status",""))
except Exception:
  print("")
' "$INV_JSON")"

  case "$STATUS" in
    Success|Failed|Cancelled|TimedOut)
      break
      ;;
  esac

  if [[ $(date +%s) -gt $DEADLINE ]]; then
    STATUS="TimedOut"
    break
  fi
  sleep 5
done

# Persist the send-command response too (includes CommandId).
aws ssm list-command-invocations --region "$REGION" --command-id "$CMD_ID" --details --output json >"$RES_JSON" || true

rm -f "$CMDS_FILE"

if [[ "$STATUS" != "Success" ]]; then
  echo "SSM command failed: instance=${INSTANCE_ID} name=${NAME} action=${ACTION} status=${STATUS} cmd_id=${CMD_ID}" >&2
  exit 1
fi

# Print a short locator for humans.
echo "${INV_JSON}"
