#!/usr/bin/env bash
set -euo pipefail

# Verify LDAP reachability + replication using the public Network Load Balancer DNS names.
#
# This runs ldap* commands on a "runner" EC2 instance (so you don't need local ldap utilities),
# and targets the NLB DNS names on port 389.
#
# Defaults (override via env):
#   RUNNER_IP=44.200.226.106 (live-master-1 public IP)
#   LIVE_W_HOST=openldap-mm-live-w-7b768a0065d56e98.elb.us-east-1.amazonaws.com
#   LIVE_R_HOST=openldap-mm-live-r-566d5423cd6457d0.elb.us-east-1.amazonaws.com
#   DR_W_HOST=openldap-mm-dr-w-82967a7df4d72e69.elb.us-east-1.amazonaws.com
#   DR_R_HOST=openldap-mm-dr-r-992f18f5817d1f87.elb.us-east-1.amazonaws.com
#
# Usage:
#   bash terraform/openldap/ldif-public-ips/verify_replication_via_elb.sh
#

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

if [[ -f terraform/key.aws.text ]]; then
  # Only eval AWS exports (the file may contain non-shell notes).
  eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"
fi

STACK_REGION="$(awk -F'\"' '/^aws_region *=/ {print $2; exit}' terraform/openldap/terraform.tfvars 2>/dev/null || true)"
REGION="${REGION:-${STACK_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}}"
export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"

KEY="${KEY_PATH:-terraform/openldap/.local-ssh/openldap_mm}"
USER="${SSH_USER:-ec2-user}"
SSH_BASE=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$KEY")

if [[ -z "${RUNNER_IP:-}" ]] && command -v terraform >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  RUNNER_IP="$(terraform -chdir=terraform/openldap output -json instance_public_ips 2>/dev/null | jq -r '.["live-master-1"] // empty' 2>/dev/null)"
fi
RUNNER_IP="${RUNNER_IP:-44.200.226.106}"

tf_out() {
  # Best-effort: derive current LB DNS names from terraform state, so this script
  # doesn't go stale when NLBs are replaced (e.g., subnet/AZ changes).
  #
  # Requires terraform + jq. If unavailable, the caller can still set *_HOST env vars.
  local key="$1" vpc="$2"
  terraform -chdir=terraform/openldap output -json "$key" 2>/dev/null | jq -r --arg vpc "$vpc" '.value[$vpc] // empty' 2>/dev/null
}

LIVE_W_HOST="${LIVE_W_HOST:-$(tf_out write_lb_dns live)}"
LIVE_R_HOST="${LIVE_R_HOST:-$(tf_out read_lb_dns live)}"
DR_W_HOST="${DR_W_HOST:-$(tf_out write_lb_dns dr)}"
DR_R_HOST="${DR_R_HOST:-$(tf_out read_lb_dns dr)}"

# Final fallback (kept for backwards compatibility if terraform output isn't available).
LIVE_W_HOST="${LIVE_W_HOST:-openldap-mm-live-w-7b768a0065d56e98.elb.us-east-1.amazonaws.com}"
LIVE_R_HOST="${LIVE_R_HOST:-openldap-mm-live-r-566d5423cd6457d0.elb.us-east-1.amazonaws.com}"
DR_W_HOST="${DR_W_HOST:-openldap-mm-dr-w-82967a7df4d72e69.elb.us-east-1.amazonaws.com}"
DR_R_HOST="${DR_R_HOST:-openldap-mm-dr-r-992f18f5817d1f87.elb.us-east-1.amazonaws.com}"

ADMIN_DN="${ADMIN_DN:-cn=admin,dc=cae,dc=local}"
ADMIN_PW="${ADMIN_PW:-admin}"
BASE_DN="${BASE_DN:-dc=cae,dc=local}"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

ssh_run() {
  local cmd="$1"
  "${SSH_BASE[@]}" "${USER}@${RUNNER_IP}" "$cmd"
}

remote_ldapsearch() {
  local host="$1"
  local filter="${2:-"(objectClass=*)"}"
  local attrs="${3:-dn}"
  # Prevent hangs if the NLB target group or security group is misconfigured.
  # -o nettimeout applies to connect/read operations; timelimit bounds the whole search on the server side.
  ssh_run "if command -v timeout >/dev/null 2>&1; then
      timeout 12s sudo /opt/symas/bin/ldapsearch -LLL -x -o nettimeout=5 -o timelimit=10 -H 'ldap://${host}:389' -D '${ADMIN_DN}' -w '${ADMIN_PW}' -b '${BASE_DN}' '${filter}' ${attrs} 2>/dev/null || true;
    else
      sudo /opt/symas/bin/ldapsearch -LLL -x -o nettimeout=5 -o timelimit=10 -H 'ldap://${host}:389' -D '${ADMIN_DN}' -w '${ADMIN_PW}' -b '${BASE_DN}' '${filter}' ${attrs} 2>/dev/null || true;
    fi"
}

remote_base_csn() {
  local host="$1"
  remote_ldapsearch "$host" "(objectClass=*)" "contextCSN" | awk -F': ' '/^contextCSN:/{print $2; exit}'
}

remote_add_ldif() {
  local host="$1"
  ssh_run "sudo /opt/symas/bin/ldapadd -x -H 'ldap://${host}:389' -D '${ADMIN_DN}' -w '${ADMIN_PW}' -f /tmp/codex_elb_test.ldif >/dev/null"
}

remote_delete_dn() {
  local host="$1"
  local dn="$2"
  ssh_run "sudo /opt/symas/bin/ldapdelete -x -H 'ldap://${host}:389' -D '${ADMIN_DN}' -w '${ADMIN_PW}' '${dn}' >/dev/null 2>&1 || true"
}

wait_for_presence() {
  local host="$1"
  local filter="$2"
  local expect="$3" # yes/no
  local deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    out="$(remote_ldapsearch "$host" "$filter" "dn" | sed -n '1,3p')"
    if [[ "$expect" == "yes" ]]; then
      grep -q '^dn: ' <<<"$out" && return 0
    else
      ! grep -q '^dn: ' <<<"$out" && return 0
    fi
    sleep 2
  done
  return 1
}

cleanup() {
  local dn
  for dn in "${TEST_DN_1:-}" "${TEST_DN_2:-}"; do
    [[ -z "$dn" ]] && continue
    remote_delete_dn "$LIVE_W_HOST" "$dn"
    remote_delete_dn "$DR_W_HOST" "$dn"
  done
}
trap cleanup EXIT

log "Runner SSH check (${RUNNER_IP})..."
ssh_run "echo ok: \$(hostname)" >/dev/null || die "Unable to SSH to runner ${RUNNER_IP}"

log "Checking base reachability via all LBs..."
for host in "$LIVE_W_HOST" "$LIVE_R_HOST" "$DR_W_HOST" "$DR_R_HOST"; do
  csn="$(remote_base_csn "$host" || true)"
  [[ -n "$csn" ]] || die "No contextCSN returned via ${host} (bind or routing issue)"
  log "  ${host} contextCSN=${csn}"
done

TS="$(date -u +%Y%m%d%H%M%S)"
TEST_DN_1="cn=codex-elb-test-${TS},${BASE_DN}"
TEST_DN_2="cn=codex-elb-test2-${TS},${BASE_DN}"

log "Test 1: add entry via LIVE write LB, verify via all LBs..."
printf "dn: %s\nobjectClass: organizationalRole\ncn: codex-elb-test-%s\ndescription: elb-repl-test-%s\n" \
  "$TEST_DN_1" "$TS" "$TS" > /tmp/codex_elb_test.ldif
ssh_run "cat > /tmp/codex_elb_test.ldif" < /tmp/codex_elb_test.ldif
remote_add_ldif "$LIVE_W_HOST"

filter1="(cn=codex-elb-test-${TS})"
for host in "$LIVE_W_HOST" "$LIVE_R_HOST" "$DR_W_HOST" "$DR_R_HOST"; do
  wait_for_presence "$host" "$filter1" "yes" || die "Test 1 did not show up via ${host} in time"
done
log "Test 1 OK."

log "Test 2: add entry via DR write LB, verify via all LBs..."
printf "dn: %s\nobjectClass: organizationalRole\ncn: codex-elb-test2-%s\ndescription: elb-repl-test2-%s\n" \
  "$TEST_DN_2" "$TS" "$TS" > /tmp/codex_elb_test.ldif
ssh_run "cat > /tmp/codex_elb_test.ldif" < /tmp/codex_elb_test.ldif
remote_add_ldif "$DR_W_HOST"

filter2="(cn=codex-elb-test2-${TS})"
for host in "$LIVE_W_HOST" "$LIVE_R_HOST" "$DR_W_HOST" "$DR_R_HOST"; do
  wait_for_presence "$host" "$filter2" "yes" || die "Test 2 did not show up via ${host} in time"
done
log "Test 2 OK."

log "Cleanup: delete entries via LIVE write LB, verify gone via all LBs..."
remote_delete_dn "$LIVE_W_HOST" "$TEST_DN_1"
remote_delete_dn "$LIVE_W_HOST" "$TEST_DN_2"

for host in "$LIVE_W_HOST" "$LIVE_R_HOST" "$DR_W_HOST" "$DR_R_HOST"; do
  wait_for_presence "$host" "(|(cn=codex-elb-test-${TS})(cn=codex-elb-test2-${TS}))" "no" || die "Deletions not reflected via ${host} in time"
done
log "PASS: replication + routing verified via all 4 load balancers."
