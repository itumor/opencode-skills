#!/bin/bash
# Seed demo content into the LOCAL kind Ascender (http://127.0.0.1:32000). Safe to re-run.
# Usage: bash seed.sh            (reads the admin password from the kind cluster secret; prints no secrets)
set -euo pipefail
URL=http://127.0.0.1:32000
HERE=$(cd "$(dirname "$0")" && pwd)
kc() { kubectl --kubeconfig "$HOME/.kube/kind-ascender-demo.config" --context kind-ascender-demo -n awx "$@"; }
PW=$(kc get secret ascender-demo-admin-password -o jsonpath='{.data.password}' | base64 -d)

api() { # api METHOD PATH [JSON]  -> body on stdout, fails on HTTP >= 400
  local m=$1 p=$2 d=${3:-} out code
  out=$(mktemp)
  code=$(curl -s -o "$out" -w '%{http_code}' -u "admin:$PW" -H 'Content-Type: application/json' -X "$m" ${d:+-d "$d"} "$URL/api/v2$p")
  if [ "$code" -ge 400 ]; then echo "API $m $p -> $code: $(head -c 300 "$out")" >&2; rm -f "$out"; return 1; fi
  cat "$out"; rm -f "$out"
}
id_of() { api GET "/$1/?name=$(jq -rn --arg n "$2" '$n|@uri')" | jq -r '.results[0].id // empty'; }
ensure() { # ensure COLLECTION NAME JSON -> id (create only when missing)
  local id; id=$(id_of "$1" "$2")
  [ -n "$id" ] || id=$(api POST "/$1/" "$3" | jq -r .id)
  echo "$id"
}

echo "waiting for a ready task instance..."
for _ in $(seq 1 60); do
  # API answers 5xx / nothing until the migration job ends: treat that as "0 ready", keep waiting quietly
  n=$(api GET '/instances/' 2>/dev/null | jq '[.results[] | select(.node_state=="ready" and .enabled)] | length' 2>/dev/null || true)
  [ "${n:-0}" -gt 0 ] && break
  sleep 5
done

ORG=$(ensure organizations "EIS DevOps" '{"name":"EIS DevOps","description":"Local demo org"}')
INV=$(ensure inventories "CAA demo fleet" "{\"name\":\"CAA demo fleet\",\"organization\":$ORG,\"description\":\"localhost stand-ins for EC2 hosts\"}")
for h in aws0caagitlab01 aws0caajenkins01 aws0caanexus01; do
  [ -n "$(api GET "/inventories/$INV/hosts/?name=$h" | jq -r '.results[0].id // empty')" ] ||
    api POST "/inventories/$INV/hosts/" "{\"name\":\"$h\",\"variables\":\"ansible_connection: local\\nansible_python_interpreter: '{{ ansible_playbook_python }}'\"}" >/dev/null
done

PRJ=$(ensure projects "EIS demo playbooks" "{\"name\":\"EIS demo playbooks\",\"organization\":$ORG,\"scm_type\":\"git\",\"scm_url\":\"https://github.com/ansible/ansible-tower-samples\",\"scm_update_on_launch\":false}")
echo "waiting for project sync (first run pulls the execution environment image)..."
for _ in $(seq 1 120); do
  st=$(api GET "/projects/$PRJ/" | jq -r .status)
  [ "$st" = successful ] && break
  if [ "$st" = failed ] || [ "$st" = error ]; then api POST "/projects/$PRJ/update/" '{}' >/dev/null; fi
  sleep 5
done
[ "$st" = successful ] || { echo "project sync status: $st" >&2; exit 1; }

JT=$(ensure job_templates "Kernel patch (demo)" "{\"name\":\"Kernel patch (demo)\",\"description\":\"Stand-in for linux_kernel_patch: runs hello_world on 3 fake hosts\",\"job_type\":\"run\",\"inventory\":$INV,\"project\":$PRJ,\"playbook\":\"hello_world.yml\",\"survey_enabled\":true,\"ask_limit_on_launch\":true}")
api POST "/job_templates/$JT/survey_spec/" '{"name":"","description":"","spec":[
 {"question_name":"Client","variable":"client","type":"multiplechoice","choices":["credit-agricole","axa-japan","nnl-japan","pto-reference"],"default":"credit-agricole","required":true,"question_description":"Which client fleet"},
 {"question_name":"Change ticket","variable":"change_ticket","type":"text","default":"COEXT-0000","required":true,"question_description":"Jira key for the maintenance window","min":3,"max":40}]}' >/dev/null

[ -n "$(api GET "/job_templates/$JT/schedules/?name=Weekly%20patch%20window" | jq -r '.results[0].id // empty')" ] ||
  api POST "/job_templates/$JT/schedules/" '{"name":"Weekly patch window","rrule":"DTSTART;TZID=UTC:20261129T020000 RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=SU","enabled":false,"extra_data":{"client":"credit-agricole","change_ticket":"COEXT-0000"}}' >/dev/null

WF=$(id_of workflow_job_templates "Patch with approval")
if [ -z "$WF" ]; then
  WF=$(api POST /workflow_job_templates/ "{\"name\":\"Patch with approval\",\"organization\":$ORG,\"description\":\"Approval gate, then the patch job\"}" | jq -r .id)
  N1=$(api POST "/workflow_job_templates/$WF/workflow_nodes/" '{}' | jq -r .id)
  api POST "/workflow_job_template_nodes/$N1/create_approval_template/" '{"name":"Maintenance window approved?","description":"Approver confirms the window","timeout":0}' >/dev/null
  N2=$(api POST "/workflow_job_templates/$WF/workflow_nodes/" "{\"unified_job_template\":$JT}" | jq -r .id)
  api POST "/workflow_job_template_nodes/$N1/success_nodes/" "{\"id\":$N2}" >/dev/null
fi

# run-only operator: can launch the template, cannot edit anything
TEAM=$(ensure teams "caa-operators" "{\"name\":\"caa-operators\",\"organization\":$ORG}")
CRED="$HERE/demo-credentials.env"   # local test account only; never commit
if [ -z "$(api GET '/users/?username=operator' | jq -r '.results[0].id // empty')" ]; then
  OPW=$(openssl rand -hex 12)   # not tr|head: SIGPIPE kills the script under pipefail
  USR=$(api POST /users/ "$(jq -n --arg p "$OPW" '{username:"operator",password:$p,first_name:"Run-only",last_name:"Operator"}')" | jq -r .id)
  api POST "/teams/$TEAM/users/" "{\"id\":$USR}" >/dev/null
  (umask 077; printf 'OPERATOR_USER=operator\nOPERATOR_PASSWORD=%s\n' "$OPW" > "$CRED")
fi
ROLE=$(api GET "/job_templates/$JT/object_roles/" | jq -r '.results[] | select(.name=="Execute") | .id')
api POST "/teams/$TEAM/roles/" "{\"id\":$ROLE}" >/dev/null
IROLE=$(api GET "/inventories/$INV/object_roles/" | jq -r '.results[] | select(.name=="Use") | .id')
api POST "/teams/$TEAM/roles/" "{\"id\":$IROLE}" >/dev/null

# one finished run so the job history is not empty
if [ "$(api GET "/job_templates/$JT/jobs/" | jq -r .count)" = 0 ]; then
  JOB=$(api POST "/job_templates/$JT/launch/" '{"extra_vars":{"client":"credit-agricole","change_ticket":"COEXT-0000"}}' | jq -r .id)
  for _ in $(seq 1 90); do
    js=$(api GET "/jobs/$JOB/" | jq -r .status); case "$js" in successful|failed|error|canceled) break;; esac; sleep 5
  done
  echo "first job $JOB: $js"
fi
echo "seeded: org=$ORG inventory=$INV project=$PRJ job_template=$JT workflow=$WF team=$TEAM"
