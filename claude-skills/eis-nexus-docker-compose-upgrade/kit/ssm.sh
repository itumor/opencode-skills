#!/bin/bash
# usage: ssm.sh <kit.env> <clone|prod> <script.sh> [EXTRA=env ...]
# Runs common.sh + script on the target via SSM (IID guard inside common.sh), prints output, rc=0 only on Success.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd); ENVF=$1 TARGET=$2 S=$3; shift 3
set -a; source "$ENVF"; set +a
case "$TARGET" in clone) I=$CLONE_IID;; prod) I=$PROD_IID;; *) echo "TARGET clone|prod"; exit 2;; esac
body="export TARGET=$TARGET TICKET=$TICKET PROD_IID=$PROD_IID CLONE_IID=$CLONE_IID FQDN=$FQDN COMPOSE_DIR=$COMPOSE_DIR $*; $(cat $D/common.sh); $(cat $D/$S)"
P=$(python3 -c 'import json,sys;print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":["3600"]}))' "$body")
CID=$(aws ssm send-command --instance-ids $I --document-name AWS-RunShellScript --comment "$TICKET $S $TARGET" --parameters "$P" --query Command.CommandId --output text)
until s=$(aws ssm get-command-invocation --command-id $CID --instance-id $I --query Status --output text 2>/dev/null) && [[ $s =~ ^(Success|Failed|TimedOut|Cancelled)$ ]]; do sleep 5; done
aws ssm get-command-invocation --command-id $CID --instance-id $I --query '[StandardOutputContent,StandardErrorContent]' --output text | grep -v -E '^\s*Container '
echo "ssm_status=$s"; [ "$s" = Success ]
