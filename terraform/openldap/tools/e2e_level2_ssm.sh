#!/usr/bin/env bash
set -euo pipefail

# Level 2: verify bootstrap + replication + read-only replicas using SSM.
# - Works with either 1-master or 2-master layouts.
# - Per-VPC MirrorMode tests run only when a VPC has >=2 masters.
# - Cross-VPC master-master tests run when both live+dr have a master (Option B topology).

REGION="${1:-us-east-1}"
RUN_DATE_UTC="$(date -u +%Y-%m-%d)"

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

# Load AWS credentials (required for SSM). key.aws.text may contain non-shell notes,
# so only eval the AWS exports.
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
ADMIN_PW="$(tfvar_get admin_password)"
REPL_PW="$(tfvar_get replication_password)"
ADMIN_DN="cn=admin,${BASE_DN}"
REPL_DN="cn=replicator,${BASE_DN}"

OUT_JSON="reports/logs/terraform_openldap_outputs_${RUN_DATE_UTC}.json"
if [[ ! -f "$OUT_JSON" ]]; then
  # Fallback: use the newest existing outputs snapshot if present.
  OUT_JSON="$(ls -1t reports/logs/terraform_openldap_outputs_*.json 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$OUT_JSON" || ! -f "$OUT_JSON" ]]; then
  echo "missing terraform outputs snapshot (expected reports/logs/terraform_openldap_outputs_${RUN_DATE_UTC}.json); run terraform output -json first" >&2
  exit 2
fi

WRITE_LB_LIVE="$(python3 -c 'import json; d=json.load(open("'"$OUT_JSON"'")); print(d["write_lb_dns"]["value"].get("live",""))')"
READ_LB_LIVE="$(python3 -c 'import json; d=json.load(open("'"$OUT_JSON"'")); print(d["read_lb_dns"]["value"].get("live",""))')"
WRITE_LB_DR="$(python3 -c 'import json; d=json.load(open("'"$OUT_JSON"'")); print(d["write_lb_dns"]["value"].get("dr",""))')"
READ_LB_DR="$(python3 -c 'import json; d=json.load(open("'"$OUT_JSON"'")); print(d["read_lb_dns"]["value"].get("dr",""))')"

INST_RAW="reports/logs/ec2_openldap_instances_raw_${RUN_DATE_UTC}.json"
INST_SORTED="reports/logs/ec2_openldap_instances_${RUN_DATE_UTC}.json"
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=openldap-mm-*" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,Role:Tags[?Key=='Role']|[0].Value,VPC:Tags[?Key=='VPC']|[0].Value,InstanceId:InstanceId,PrivateIp:PrivateIpAddress,PublicIp:PublicIpAddress,LaunchTime:LaunchTime}" \
  --output json >"$INST_RAW"
python3 - "$INST_RAW" "$INST_SORTED" <<'PY'
import json
import sys
raw=sys.argv[1]
out=sys.argv[2]
arr=json.load(open(raw))
arr=sorted(arr,key=lambda x:(x.get('VPC',''), x.get('Role',''), x.get('Name','')))
json.dump(arr, open(out,'w'), indent=2)
print('instances', len(arr))
PY

# Build id->name map and per-VPC role lists (bash 3.2 compatible: no assoc arrays).
ID_MAP_TSV="reports/logs/ec2_openldap_id_map_${RUN_DATE_UTC}.tsv"
LIVE_MASTER_IDS=""
LIVE_REPLICA_IDS=""
DR_MASTER_IDS=""
DR_REPLICA_IDS=""

python3 - "$INST_SORTED" <<'PY' >"$ID_MAP_TSV"
import json
import sys
arr=json.load(open(sys.argv[1]))
for x in arr:
  print(f"{x['InstanceId']}\t{x['Name']}\t{x.get('Role','')}\t{x.get('VPC','')}")
PY

name_of() {
  local iid="$1"
  awk -F'\t' -v id="$iid" '$1==id {print $2; exit}' "$ID_MAP_TSV"
}

while IFS=$'\t' read -r iid name role vpc; do
  case "$vpc:$role" in
    live:master) LIVE_MASTER_IDS+=" $iid" ;;
    live:replica) LIVE_REPLICA_IDS+=" $iid" ;;
    dr:master) DR_MASTER_IDS+=" $iid" ;;
    dr:replica) DR_REPLICA_IDS+=" $iid" ;;
  esac
done <"$ID_MAP_TSV"

# Trim leading spaces.
LIVE_MASTER_IDS="${LIVE_MASTER_IDS# }"
LIVE_REPLICA_IDS="${LIVE_REPLICA_IDS# }"
DR_MASTER_IDS="${DR_MASTER_IDS# }"
DR_REPLICA_IDS="${DR_REPLICA_IDS# }"

SSM_RUN="terraform/openldap/tools/ssm_run.sh"

check_instance() {
  local iid="$1"
  local name
  name="$(name_of "$iid" || true)"
  [[ -n "$name" ]] || name="$iid"
  "$SSM_RUN" "$REGION" "$iid" "$name" check "check cloud-init + ldap + artifacts" <<CMD
set -euo pipefail

echo "=== name: $name ==="
if command -v cloud-init >/dev/null 2>&1; then
  echo "=== cloud-init status ==="
  cloud-init status || true
fi

echo "=== marker ==="
for _ in {1..120}; do
  if sudo test -f /opt/openldap/.bootstrap_done; then
    echo OK
    break
  fi
  echo "waiting for /opt/openldap/.bootstrap_done ..."
  sleep 10
done
sudo test -f /opt/openldap/.bootstrap_done || (echo MISSING; sudo tail -n 120 /var/log/cloud-init-output.log 2>/dev/null || true; exit 1)

echo "=== artifacts ==="
sudo test -d /opt/openldap/bootstrap
sudo test -d /opt/openldap/script
sudo test -d /opt/openldap/ldif-src
sudo test -d /opt/openldap/mirrormode-scripts

echo "=== services ==="
sudo systemctl is-active symas-openldap-servers || true
sudo systemctl is-active slapd || true

export PATH=/opt/symas/bin:/opt/symas/sbin:

echo "=== whoami admin (localhost) ==="
ldapwhoami -x -ZZ -H ldap://localhost:389 -D "$ADMIN_DN" -w "$ADMIN_PW"

echo "=== whoami replicator (localhost) ==="
ldapwhoami -x -ZZ -H ldap://localhost:389 -D "$REPL_DN" -w "$REPL_PW"
CMD
}

add_user_on() {
  local iid="$1" uid="$2" cn="$3"
  local name
  name="$(name_of "$iid" || true)"
  [[ -n "$name" ]] || name="$iid"
  "$SSM_RUN" "$REGION" "$iid" "$name" add "add ${uid}" <<CMD
set -euo pipefail
export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
cat >/tmp/${uid}.ldif <<LDIF
dn: uid=${uid},ou=people,${BASE_DN}
objectClass: inetOrgPerson
uid: ${uid}
sn: ${uid}
cn: ${cn}
LDIF
ldapadd -x -ZZ -H ldap://localhost:389 -D "$ADMIN_DN" -w "$ADMIN_PW" -f /tmp/${uid}.ldif
CMD
}

wait_for_user_on() {
  local iid="$1" uid="$2"
  local name
  name="$(name_of "$iid" || true)"
  [[ -n "$name" ]] || name="$iid"
  "$SSM_RUN" "$REGION" "$iid" "$name" wait "wait ${uid}" <<CMD
set -euo pipefail
export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
for _ in {1..24}; do
  if ldapsearch -LLL -x -ZZ -H ldap://localhost:389 -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$BASE_DN" "(uid=${uid})" dn | grep -q '^dn:'; then
    echo "FOUND"
    exit 0
  fi
  sleep 5
done
echo "NOT FOUND"
exit 1
CMD
}

expect_write_fail_on() {
  local iid="$1" uid="$2"
  local name
  name="$(name_of "$iid" || true)"
  [[ -n "$name" ]] || name="$iid"
  "$SSM_RUN" "$REGION" "$iid" "$name" writefail "expect write fail ${uid}" <<CMD
set -euo pipefail
export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
cat >/tmp/${uid}-replica.ldif <<LDIF
dn: uid=${uid},ou=people,${BASE_DN}
objectClass: inetOrgPerson
uid: ${uid}
sn: ${uid}
cn: should-fail
LDIF
set +e
ldapadd -x -ZZ -H ldap://localhost:389 -D "$ADMIN_DN" -w "$ADMIN_PW" -f /tmp/${uid}-replica.ldif 2>/tmp/err.txt
rc=\$?
set -e
if [[ \$rc -eq 0 ]]; then
  echo "UNEXPECTED: write succeeded on replica"
  exit 1
fi
echo "expected failure rc=\$rc"
cat /tmp/err.txt || true
CMD
}

nlb_sanity_from() {
  local iid="$1" vpc="$2" write_dns="$3" read_dns="$4" uid="$5"
  local name
  name="$(name_of "$iid" || true)"
  [[ -n "$name" ]] || name="$iid"
  "$SSM_RUN" "$REGION" "$iid" "$name" nlb "test NLB ${vpc}" <<CMD
set -euo pipefail
export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH

echo "=== whoami write NLB (${vpc}) ==="
ldapwhoami -x -ZZ -H ldap://${write_dns}:389 -D "$ADMIN_DN" -w "$ADMIN_PW"

echo "=== whoami read NLB (${vpc}) ==="
ldapwhoami -x -ZZ -H ldap://${read_dns}:389 -D "$ADMIN_DN" -w "$ADMIN_PW"

echo "=== read NLB search (${vpc}) ==="
ldapsearch -LLL -x -ZZ -H ldap://${read_dns}:389 -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$BASE_DN" "(uid=${uid})" dn | grep -q '^dn:'
CMD
}

# Checks on all instances.
for iid in $LIVE_MASTER_IDS $LIVE_REPLICA_IDS $DR_MASTER_IDS $DR_REPLICA_IDS; do
  echo "[check] $(name_of "$iid" || echo "$iid") ${iid}"
  check_instance "$iid"
done

run_vpc_tests() {
  local vpc="$1" master_ids="$2" replica_ids="$3" write_lb="$4" read_lb="$5"

  if [[ -z "$master_ids" ]]; then
    echo "No masters found for vpc=${vpc}" >&2
    return 1
  fi

  local masters=() replicas=()
  read -r -a masters <<<"$master_ids"
  if [[ -n "$replica_ids" ]]; then
    read -r -a replicas <<<"$replica_ids"
  fi

  local writer_id="${masters[0]}"
  local test_uid="e2e-${vpc}-$(date -u +%Y%m%d%H%M%S)"
  local cn="E2E ${vpc} $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  echo "[test] vpc=${vpc} add ${test_uid} on $(name_of "$writer_id")" >&2
  add_user_on "$writer_id" "$test_uid" "$cn" 1>&2

  # Replication: other masters + all replicas must see the entry.
  local targets=()
  if [[ ${#masters[@]} -gt 1 ]]; then
    targets+=("${masters[@]:1}")
  fi
  if [[ ${#replicas[@]} -gt 0 ]]; then
    targets+=("${replicas[@]}")
  fi

  for iid in "${targets[@]}"; do
    echo "[test] vpc=${vpc} wait ${test_uid} on $(name_of "$iid")" >&2
    wait_for_user_on "$iid" "$test_uid" 1>&2
  done

  # Read-only: every replica must reject writes.
  for rid in "${replicas[@]}"; do
    echo "[test] vpc=${vpc} replica write reject on $(name_of "$rid")" >&2
    expect_write_fail_on "$rid" "${test_uid}-fail" 1>&2
  done

  # MirrorMode (if 2+ masters): write on 2nd master and verify on 1st master.
  local did_mirrormode="no"
  if [[ ${#masters[@]} -gt 1 ]]; then
    did_mirrormode="yes"
    local writer2_id="${masters[1]}"
    local uid2="${test_uid}-m2"
    echo "[test] vpc=${vpc} mirror-write ${uid2} on $(name_of "$writer2_id")" >&2
    add_user_on "$writer2_id" "$uid2" "${cn} (m2)" 1>&2
    echo "[test] vpc=${vpc} wait ${uid2} on $(name_of "$writer_id")" >&2
    wait_for_user_on "$writer_id" "$uid2" 1>&2
  fi

  # NLB sanity from the writer.
  if [[ -n "$write_lb" && -n "$read_lb" ]]; then
    nlb_sanity_from "$writer_id" "$vpc" "$write_lb" "$read_lb" "$test_uid" 1>&2
  fi

  echo "$vpc,$test_uid,$did_mirrormode"
}

RESULTS_FILE="reports/logs/e2e_vpc_results_${RUN_DATE_UTC}.csv"
echo "vpc,test_uid,mirrormode" >"$RESULTS_FILE"
run_vpc_tests "live" "$LIVE_MASTER_IDS" "$LIVE_REPLICA_IDS" "$WRITE_LB_LIVE" "$READ_LB_LIVE" >>"$RESULTS_FILE"
run_vpc_tests "dr" "$DR_MASTER_IDS" "$DR_REPLICA_IDS" "$WRITE_LB_DR" "$READ_LB_DR" >>"$RESULTS_FILE"

# Cross-VPC master-master replication (MirrorMode Option B): live master <-> dr master.
# This validates "two masters total across two VPCs" even when each VPC has only one master.
CROSS_VPC_MM="no"
CROSS_UID_LIVE=""
CROSS_UID_DR=""
if [[ -n "$LIVE_MASTER_IDS" && -n "$DR_MASTER_IDS" ]]; then
  CROSS_VPC_MM="yes"
  live_master_id="${LIVE_MASTER_IDS%% *}"
  dr_master_id="${DR_MASTER_IDS%% *}"

  cross_uid_base="e2e-cross-$(date -u +%Y%m%d%H%M%S)"
  CROSS_UID_LIVE="${cross_uid_base}-live"
  CROSS_UID_DR="${cross_uid_base}-dr"

  echo "[test] cross-vpc add ${CROSS_UID_LIVE} on live master $(name_of "$live_master_id")" >&2
  add_user_on "$live_master_id" "$CROSS_UID_LIVE" "E2E cross-vpc from live $(date -u +%Y-%m-%dT%H:%M:%SZ)" 1>&2
  echo "[test] cross-vpc wait ${CROSS_UID_LIVE} on dr master $(name_of "$dr_master_id")" >&2
  wait_for_user_on "$dr_master_id" "$CROSS_UID_LIVE" 1>&2

  echo "[test] cross-vpc add ${CROSS_UID_DR} on dr master $(name_of "$dr_master_id")" >&2
  add_user_on "$dr_master_id" "$CROSS_UID_DR" "E2E cross-vpc from dr $(date -u +%Y-%m-%dT%H:%M:%SZ)" 1>&2
  echo "[test] cross-vpc wait ${CROSS_UID_DR} on live master $(name_of "$live_master_id")" >&2
  wait_for_user_on "$live_master_id" "$CROSS_UID_DR" 1>&2
fi

# Optional: include the newest local terraform plan snapshot if present.
PLAN_SNAPSHOT="$(ls -1t reports/logs/terraform_openldap_plan_*_after_e2e.txt 2>/dev/null | head -n 1 | tr -d '\r' || true)"
PLAN_LINE=""
if [[ -n "${PLAN_SNAPSHOT}" && -f "${PLAN_SNAPSHOT}" ]]; then
  PLAN_LINE="$(grep -E '^Plan:' "${PLAN_SNAPSHOT}" | tail -n 1 || true)"
fi

REPORT="reports/OpenLDAP_E2E_REPORT_$(date -u +%Y-%m-%d).md"
{
  echo "# OpenLDAP AWS E2E Report"
  echo
  echo "- Date (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- Region: ${REGION}"
  echo
  echo "## Inputs"
  echo
  echo "- Base DN: ${BASE_DN}"
  echo "- Terraform vars: ${TFVARS}"
  echo "- Terraform outputs: ${OUT_JSON}"
  echo "- Instances: ${INST_SORTED}"
  if [[ -n "${PLAN_SNAPSHOT}" ]]; then
    echo "- Terraform plan snapshot: ${PLAN_SNAPSHOT}"
  fi
  echo
  echo "## Endpoints"
  echo
  echo "- live write NLB: ${WRITE_LB_LIVE}:389"
  echo "- live read  NLB: ${READ_LB_LIVE}:389"
  echo "- dr write NLB: ${WRITE_LB_DR}:389"
  echo "- dr read  NLB: ${READ_LB_DR}:389"
  echo
  echo "## Replication Validation"
  echo
  echo "- Per-VPC MirrorMode: validated only when a VPC has >=2 masters (see VPC Matrix)."
  echo "- Cross-VPC master-master (Option B): ${CROSS_VPC_MM}"
  if [[ "$CROSS_VPC_MM" == "yes" ]]; then
    echo "  - live->dr uid: ${CROSS_UID_LIVE}"
    echo "  - dr->live uid: ${CROSS_UID_DR}"
  fi
  echo
  echo "## Inventory"
  echo
  python3 - "$INST_SORTED" <<'PY'
import json
import sys
arr=json.load(open(sys.argv[1]))
print("| VPC | Role | Name | InstanceId | PrivateIp | PublicIp | LaunchTime |")
print("|---|---|---|---|---|---|---|")
for x in arr:
  print("| {VPC} | {Role} | {Name} | {InstanceId} | {PrivateIp} | {PublicIp} | {LaunchTime} |".format(
    VPC=x.get("VPC",""),
    Role=x.get("Role",""),
    Name=x.get("Name",""),
    InstanceId=x.get("InstanceId",""),
    PrivateIp=x.get("PrivateIp",""),
    PublicIp=x.get("PublicIp",""),
    LaunchTime=x.get("LaunchTime",""),
  ))
PY
  echo
  echo "## Results"
  echo
  echo "- VPC test matrix: ${RESULTS_FILE}"
  echo "- SSM logs: reports/logs/ssm_*"
  echo
  echo "### VPC Matrix"
  echo
  python3 - "$RESULTS_FILE" <<'PY'
import csv
import sys
rows=list(csv.reader(open(sys.argv[1])))
hdr=rows[0]
print("| " + " | ".join(hdr) + " |")
print("|" + "|".join(["---"]*len(hdr)) + "|")
for r in rows[1:]:
  print("| " + " | ".join(r) + " |")
PY
  echo
  if [[ -n "${PLAN_SNAPSHOT}" ]]; then
    echo "## Terraform Drift"
    echo
    echo "- Plan file: ${PLAN_SNAPSHOT}"
    if [[ -n "${PLAN_LINE}" ]]; then
      echo "- Summary: ${PLAN_LINE}"
    fi
    echo
    echo '- Note: instance replacements are expected if EC2 `user_data` changed and `user_data_replace_on_change` is enabled.'
    echo
  fi
  echo "## Notes"
  echo
  echo "- If a VPC has only 1 master, per-VPC MirrorMode cannot be validated in that VPC (tests mark mirrormode=no)."
  echo "- For Option B topologies (one master in live + one master in dr), use the Cross-VPC master-master result above."
  echo "- Bootstrap marker file: /opt/openldap/.bootstrap_done"
  echo "- Bootstrap env file: /opt/openldap/bootstrap/node.env"
  echo "- SSH is not currently available on these instances (no EC2 keypair); post-provisioning is done via AWS SSM."
} >"$REPORT"

echo "$REPORT"
