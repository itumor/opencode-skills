#!/usr/bin/env bash
set -euo pipefail

REGION="${1:-us-east-1}"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

# Only eval AWS exports (the file may contain non-shell notes).
eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"
export AWS_REGION="${AWS_REGION:-$REGION}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$REGION}"

SSM_RUN="terraform/openldap/tools/ssm_run.sh"

INST_RAW="reports/logs/ec2_openldap_instances_raw_2026-02-07.json"
INST_SORTED="reports/logs/ec2_openldap_instances_2026-02-07.json"
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=openldap-mm-*" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,InstanceId:InstanceId}" \
  --output json >"$INST_RAW"
python3 - <<'PY'
import json
raw='reports/logs/ec2_openldap_instances_raw_2026-02-07.json'
arr=json.load(open(raw))
arr=sorted(arr,key=lambda x:x['Name'])
json.dump(arr, open('reports/logs/ec2_openldap_instances_2026-02-07.json','w'), indent=2)
print(len(arr))
PY

python3 - "$INST_SORTED" <<'PY' | while read -r iid name; do
import json,sys
arr=json.load(open(sys.argv[1]))
for x in arr:
  print(x["InstanceId"], x["Name"])
PY
  echo "[bootstrap] ${name} ${iid}"
  "$SSM_RUN" "$REGION" "$iid" "$name" bootstrap "sync + rerun bootstrap" <<'CMD'
set -euo pipefail

echo "=== ensure env file exists ==="
sudo test -f /opt/openldap/bootstrap/node.env

echo "=== load env ==="
set -a
# shellcheck disable=SC1091
source /opt/openldap/bootstrap/node.env
set +a

echo "=== sync latest bootstrap from S3 ==="
sudo dnf -y install awscli >/dev/null 2>&1 || true
sudo aws s3 sync "s3://${ARTIFACTS_BUCKET}/bootstrap" /opt/openldap/bootstrap >/dev/null
sudo chmod +x /opt/openldap/bootstrap/bootstrap-ldap.sh

echo "=== run bootstrap ==="
export BOOTSTRAP_SKIP_INSTALL=1
sudo -E /opt/openldap/bootstrap/bootstrap-ldap.sh

echo "=== marker ==="
sudo ls -la /opt/openldap/.bootstrap_done
CMD

done
