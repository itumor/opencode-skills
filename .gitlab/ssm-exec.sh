#!/usr/bin/env bash
# ssm-exec.sh <instance-id> <command>
# Runs a shell command via SSM and prints the output.
# Does NOT fail on non-zero command exit — SSM commands are fire-and-observe.
set -euo pipefail

INSTANCE_ID="${1:?instance ID required}"
shift
COMMAND="$*"

CMD_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets "Key=InstanceIds,Values=$INSTANCE_ID" \
  --parameters "{\"commands\":[\"$COMMAND\"]}" \
  --query 'Command.CommandId' --output text)

echo "[ssm:$CMD_ID] Running: $COMMAND"

# Poll until command finishes (Success, Failed, or TimedOut)
for i in $(seq 1 60); do
  result=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query '{S:Status,SO:StandardOutputContent,SE:StandardErrorContent}' --output json 2>/dev/null)
  status=$(echo "$result" | jq -r '.S // "InProgress"')
  case "$status" in
    Success|Failed|Cancelled|TimedOut)
      echo "SSM result: $status"
      echo "$result" | jq -r '.SO // ""'
      echo "$result" | jq -r '.SE // ""' >&2
      exit 0
      ;;
  esac
  sleep 2
done

echo "SSM command timed out waiting for completion"
exit 1
