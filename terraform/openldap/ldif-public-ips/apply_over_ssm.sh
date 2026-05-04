#!/usr/bin/env bash
set -euo pipefail

# Apply a node's LDIF bundle via AWS SSM (no inbound SSH required).
#
# Example:
#   bash terraform/openldap/ldif-public-ips/apply_over_ssm.sh us-east-1 live/live-master-1
#
# This script:
# - Resolves the instance ID from `terraform/openldap` outputs (instance_ids)
# - Uploads the bundle contents into /tmp via inline base64 payloads
# - Runs the same apply logic used by apply_over_ssh.sh

REGION="${1:-us-east-1}"
NODE_REL="${2:-}"
if [[ -z "${NODE_REL}" ]]; then
  echo "usage: $0 <region> <cluster/node>" >&2
  echo "example: $0 us-east-1 live/live-master-1" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

if [[ -f terraform/key.aws.text ]]; then
  # Only eval AWS exports (the file may contain non-shell notes).
  eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"
fi
# Force the region for both Terraform backend access + SSM calls.
export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"

if ! command -v terraform >/dev/null 2>&1; then
  echo "missing terraform in PATH" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "missing jq in PATH" >&2
  exit 2
fi

bundle_dir="terraform/openldap/ldif-public-ips/${NODE_REL}"
if [[ ! -d "$bundle_dir" ]]; then
  echo "missing bundle dir: ${bundle_dir}" >&2
  exit 2
fi

name="${NODE_REL##*/}" # e.g. live-master-1
instance_id="$(terraform -chdir=terraform/openldap output -json instance_ids | jq -r --arg n "$name" '.[$n] // empty')"
if [[ -z "$instance_id" || "$instance_id" == "null" ]]; then
  echo "could not resolve instance id for node name '${name}' from terraform output instance_ids" >&2
  exit 2
fi

SSM_RUN="terraform/openldap/tools/ssm_run.sh"
tmp_dir="/tmp/ldif-public-ips/${NODE_REL}"

# Build a remote script that reconstructs the bundle via base64 payloads.
remote_payload="$(mktemp)"
{
  echo "set -euo pipefail"
  echo "mkdir -p '${tmp_dir}'"
  echo "cd '${tmp_dir}'"
  for f in "$bundle_dir"/*; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    echo "cat >'${tmp_dir}/${base}.b64' <<'B64'"
    base64 <"$f"
    echo "B64"
    echo "base64 -d '${tmp_dir}/${base}.b64' >'${tmp_dir}/${base}'"
    echo "rm -f '${tmp_dir}/${base}.b64'"
  done

  echo ""
  echo "# Apply (same logic as apply_over_ssh.sh)"
  echo "bundle_dir='${tmp_dir}'"
  cat <<'APPLY'
export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
LDAPI_URI='ldapi://%2Fvar%2Fsymas%2Frun%2Fldapi'

ADMIN_DN='cn=admin,dc=cae,dc=local'
ADMIN_PW='admin'
LDAP_PORT='389'

ldapadd_local() {
  sudo /opt/symas/bin/ldapadd -x -H "ldap://localhost:${LDAP_PORT}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" -f "$1" || true
}
ldapmodify_local() {
  sudo /opt/symas/bin/ldapmodify -x -H "ldap://localhost:${LDAP_PORT}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" -f "$1" || true
}
ldapadd_cfg() {
  sudo /opt/symas/bin/ldapadd -Y EXTERNAL -H "${LDAPI_URI}" -f "$1" || true
}
ldapmodify_cfg() {
  sudo /opt/symas/bin/ldapmodify -Y EXTERNAL -H "${LDAPI_URI}" -f "$1" || true
}

is_readonly_dit() {
  sudo /opt/symas/bin/ldapsearch -LLL -Y EXTERNAL -H "${LDAPI_URI}" \
    -b 'olcDatabase={1}mdb,cn=config' -s base olcReadOnly 2>/dev/null | grep -qi 'olcReadOnly: *TRUE'
}

if ! is_readonly_dit; then
  [[ -f "${bundle_dir}/01-replicator.ldif" ]] && ldapadd_local "${bundle_dir}/01-replicator.ldif"
  [[ -f "${bundle_dir}/03-replicator-pw.ldif" ]] && ldapmodify_local "${bundle_dir}/03-replicator-pw.ldif"
fi
[[ -f "${bundle_dir}/02-replicator-acl.ldif" ]] && ldapmodify_cfg "${bundle_dir}/02-replicator-acl.ldif"

[[ -f "${bundle_dir}/10-serverid.ldif" ]] && ldapmodify_cfg "${bundle_dir}/10-serverid.ldif"
[[ -f "${bundle_dir}/10-serverid-cross.ldif" ]] && ldapmodify_cfg "${bundle_dir}/10-serverid-cross.ldif"

[[ -f "${bundle_dir}/19-load-syncprov.ldif" ]] && ldapmodify_cfg "${bundle_dir}/19-load-syncprov.ldif"
[[ -f "${bundle_dir}/20-syncprov-master.ldif" ]] && ldapadd_cfg "${bundle_dir}/20-syncprov-master.ldif"
[[ -f "${bundle_dir}/21-mirrormode-cross.ldif" ]] && ldapmodify_cfg "${bundle_dir}/21-mirrormode-cross.ldif"

[[ -f "${bundle_dir}/30-replica-consumer.ldif" ]] && ldapmodify_cfg "${bundle_dir}/30-replica-consumer.ldif"
[[ -f "${bundle_dir}/31-replica-readonly.ldif" ]] && ldapmodify_cfg "${bundle_dir}/31-replica-readonly.ldif"

echo "applied: ${bundle_dir}"
APPLY
} >"$remote_payload"

echo "[ssm] ${NODE_REL} -> ${instance_id}"
"$SSM_RUN" "$REGION" "$instance_id" "openldap-mm-${name}" "ldif_public_ips" "apply ldif-public-ips bundle ${NODE_REL}" <"$remote_payload"

rm -f "$remote_payload"
