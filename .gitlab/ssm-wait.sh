#!/usr/bin/env bash
# ssm-wait.sh <instance-id>
# Polls until SSM agent is Online on the instance.
set -euo pipefail

INSTANCE_ID="${1:?instance ID required}"

echo "Waiting for SSM agent on $INSTANCE_ID..."
for i in $(seq 1 30); do
  status=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null) || true
  if [[ "$status" == "Online" ]]; then
    echo "SSM online (attempt $i)"
    exit 0
  fi
  echo "  attempt $i/30, waiting 10s..."
  sleep 10
done
echo "SSM agent did not come online within 5 minutes"
exit 1
