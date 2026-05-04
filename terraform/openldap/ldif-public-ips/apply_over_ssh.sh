#!/usr/bin/env bash
set -euo pipefail

# Apply a node's LDIF bundle over SSH.
#
# Example:
#   bash terraform/openldap/ldif-public-ips/apply_over_ssh.sh live/live-master-1 <public-ip>
#
# Tip:
#   eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"
#   IP="$(terraform -chdir=terraform/openldap output -json instance_public_ips | jq -r '."live-master-1"')"

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

NODE_REL="${1:-}"
IP="${2:-}"
if [[ -z "$NODE_REL" || -z "$IP" ]]; then
  echo "usage: $0 <cluster/node> <public-ip>" >&2
  echo "example: $0 live/live-master-1 <public-ip>" >&2
  exit 2
fi

KEY="terraform/openldap/.local-ssh/openldap_mm"
USER="ec2-user"
SSH="ssh -o StrictHostKeyChecking=no -i ${KEY} ${USER}@${IP}"
SCP="scp -o StrictHostKeyChecking=no -i ${KEY}"

BUNDLE_DIR="terraform/openldap/ldif-public-ips/${NODE_REL}"
if [[ ! -d "$BUNDLE_DIR" ]]; then
  echo "missing bundle dir: ${BUNDLE_DIR}" >&2
  exit 2
fi

TMP_DIR="/tmp/ldif-public-ips/${NODE_REL}"

# Copy bundle
$SSH "mkdir -p '${TMP_DIR}'"
$SCP -r "${BUNDLE_DIR}/"* "${USER}@${IP}:${TMP_DIR}/"

# Apply
$SSH "bash -s -- '${TMP_DIR}'" <<'REMOTE'
set -euo pipefail

export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
LDAPI_URI='ldapi://%2Fvar%2Fsymas%2Frun%2Fldapi'

ADMIN_DN='cn=admin,dc=cae,dc=local'
ADMIN_PW='admin'
LDAP_PORT='389'

bundle_dir="${1:?missing bundle dir}"

# Helpers
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

# If the DIT database is read-only (replica), skip direct DIT writes. The entry
# should arrive via replication from the master once syncrepl is configured.
is_readonly_dit() {
  sudo /opt/symas/bin/ldapsearch -LLL -Y EXTERNAL -H "${LDAPI_URI}" \
    -b 'olcDatabase={1}mdb,cn=config' -s base olcReadOnly 2>/dev/null | grep -qi 'olcReadOnly: *TRUE'
}

# Common
if ! is_readonly_dit; then
  [[ -f "${bundle_dir}/01-replicator.ldif" ]] && ldapadd_local "${bundle_dir}/01-replicator.ldif"
  [[ -f "${bundle_dir}/03-replicator-pw.ldif" ]] && ldapmodify_local "${bundle_dir}/03-replicator-pw.ldif"
fi
[[ -f "${bundle_dir}/02-replicator-acl.ldif" ]] && ldapmodify_cfg "${bundle_dir}/02-replicator-acl.ldif"

# Server ID
[[ -f "${bundle_dir}/10-serverid.ldif" ]] && ldapmodify_cfg "${bundle_dir}/10-serverid.ldif"
[[ -f "${bundle_dir}/10-serverid-cross.ldif" ]] && ldapmodify_cfg "${bundle_dir}/10-serverid-cross.ldif"

# Masters
[[ -f "${bundle_dir}/19-load-syncprov.ldif" ]] && ldapmodify_cfg "${bundle_dir}/19-load-syncprov.ldif"
[[ -f "${bundle_dir}/20-syncprov-master.ldif" ]] && ldapadd_cfg "${bundle_dir}/20-syncprov-master.ldif"
[[ -f "${bundle_dir}/21-mirrormode-cross.ldif" ]] && ldapmodify_cfg "${bundle_dir}/21-mirrormode-cross.ldif"

# Replicas
[[ -f "${bundle_dir}/30-replica-consumer.ldif" ]] && ldapmodify_cfg "${bundle_dir}/30-replica-consumer.ldif"
[[ -f "${bundle_dir}/31-replica-readonly.ldif" ]] && ldapmodify_cfg "${bundle_dir}/31-replica-readonly.ldif"

echo "applied: ${bundle_dir}"
REMOTE
