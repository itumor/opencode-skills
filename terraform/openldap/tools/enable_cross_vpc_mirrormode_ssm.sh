#!/usr/bin/env bash
set -euo pipefail

# Enable master-master syncrepl between the live and dr masters (Option B topology),
# without changing Terraform-managed EC2 resources (no instance replacement).
#
# This script uses SSM to:
# - Set unique olcServerID mappings on both masters.
# - Configure each master to syncrepl from the other master.
#
# Notes:
# - We intentionally do NOT touch user_data or Terraform state here.
# - Consumers/replicas remain consumers; their existing syncrepl should keep working.

REGION="${1:-us-east-1}"

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"
export AWS_REGION="${AWS_REGION:-$REGION}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$REGION}"

TFVARS="terraform/openldap/terraform.tfvars"
if [[ ! -f "$TFVARS" ]]; then
  echo "missing ${TFVARS}; create it first" >&2
  exit 2
fi

tfvar_get() {
  local key="$1"
  awk -v k="$key" '
    $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "", $0)
      gsub(/^[[:space:]]*\"/, "", $0)
      gsub(/\"[[:space:]]*$/, "", $0)
      print $0
      exit
    }
  ' "$TFVARS"
}

BASE_DN="$(tfvar_get base_dn)"
REPL_PW="$(tfvar_get replication_password)"

SSM_RUN="terraform/openldap/tools/ssm_run.sh"

masters_json="$(mktemp)"
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=openldap-mm-*" "Name=tag:Role,Values=master" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,VPC:Tags[?Key=='VPC']|[0].Value,InstanceId:InstanceId,PrivateIp:PrivateIpAddress}" \
  --output json >"$masters_json"

live_master_id="$(python3 -c 'import json; import sys
arr=json.load(open(sys.argv[1]))
for x in arr:
  if x.get("VPC")=="live":
    print(x["InstanceId"]); break
' "$masters_json")"
dr_master_id="$(python3 -c 'import json; import sys
arr=json.load(open(sys.argv[1]))
for x in arr:
  if x.get("VPC")=="dr":
    print(x["InstanceId"]); break
' "$masters_json")"
live_ip="$(python3 -c 'import json; import sys
arr=json.load(open(sys.argv[1]))
for x in arr:
  if x.get("VPC")=="live":
    print(x["PrivateIp"]); break
' "$masters_json")"
dr_ip="$(python3 -c 'import json; import sys
arr=json.load(open(sys.argv[1]))
for x in arr:
  if x.get("VPC")=="dr":
    print(x["PrivateIp"]); break
' "$masters_json")"

rm -f "$masters_json"

if [[ -z "$live_master_id" || -z "$dr_master_id" || -z "$live_ip" || -z "$dr_ip" ]]; then
  echo "could not discover both live+dr masters via tags (expected Role=master and VPC=live/dr)" >&2
  exit 1
fi

enable_on() {
  local iid="$1" name="$2" this_ip="$3" peer_ip="$4" rid="$5" this_sid="$6" peer_sid="$7"
  "$SSM_RUN" "$REGION" "$iid" "$name" enable_cross_mm "enable cross-vpc master-master" <<CMD
set -euo pipefail
export PATH=/opt/symas/bin:/opt/symas/sbin:\$PATH
BASE_DN='${BASE_DN}'
REPL_PW='${REPL_PW}'
THIS_IP='${this_ip}'
PEER_IP='${peer_ip}'
DB_DN="\$(ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b cn=config -o ldif-wrap=no "(olcSuffix=\${BASE_DN})" dn | awk '/^dn: /{print \$2; exit}')"

cat >/tmp/serverid.ldif <<LDIF
dn: cn=config
changetype: modify
replace: olcServerID
olcServerID: ${this_sid} ldap://\${THIS_IP}:389
olcServerID: ${peer_sid} ldap://\${PEER_IP}:389
LDIF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/serverid.ldif

cat >/tmp/syncrepl.ldif <<LDIF
dn: \${DB_DN}
changetype: modify
replace: olcSyncRepl
olcSyncRepl: rid=${rid} provider=ldap://\${PEER_IP}:389 bindmethod=simple binddn="cn=replicator,\${BASE_DN}" credentials=\${REPL_PW} searchbase="\${BASE_DN}" type=refreshAndPersist retry="5 5 300 5" timeout=1
LDIF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/syncrepl.ldif

echo '=== verify ==='
ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b cn=config -o ldif-wrap=no "(objectClass=olcGlobal)" olcServerID
ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b "\$DB_DN" -s base -o ldif-wrap=no dn olcSyncRepl olcMultiProvider
CMD
}

enable_on "$live_master_id" "openldap-mm-live-master-1" "$live_ip" "$dr_ip" 201 1 2
enable_on "$dr_master_id" "openldap-mm-dr-master-1" "$dr_ip" "$live_ip" 202 2 1

echo "enabled cross-vpc master-master between live=${live_ip} (${live_master_id}) and dr=${dr_ip} (${dr_master_id})"

