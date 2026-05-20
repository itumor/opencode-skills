#!/usr/bin/env bash
set -euo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${TF_DIR}"

MASTER_PUBLIC_IP="$(terraform output -raw master_public_ip)"
REPLICA_PUBLIC_IP="$(terraform output -raw replica_public_ip)"
SSH_KEY="$(terraform output -raw ssh_private_key_path)"
BASE_DN="${BASE_DN:-dc=cae,dc=local}"
ADMIN_DN="${ADMIN_DN:-cn=admin,${BASE_DN}}"
ADMIN_PW="${ADMIN_PW:-${TF_VAR_admin_password:-admin}}"
UID_VALUE="${UID_VALUE:-codexcheck$(date -u +%Y%m%d%H%M%S)}"

ssh_cmd() {
  local host="$1"
  shift
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "ec2-user@${host}" "$@"
}

echo "== service checks =="
ssh_cmd "${MASTER_PUBLIC_IP}" "sudo systemctl is-active symas-openldap-servers"
ssh_cmd "${REPLICA_PUBLIC_IP}" "sudo systemctl is-active symas-openldap-servers"

echo "== bind/search checks =="
ssh_cmd "${MASTER_PUBLIC_IP}" "sudo /opt/symas/bin/ldapwhoami -x -H ldap://localhost:389 -D '${ADMIN_DN}' -w '${ADMIN_PW}'"
ssh_cmd "${MASTER_PUBLIC_IP}" "sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 -D '${ADMIN_DN}' -w '${ADMIN_PW}' -b '${BASE_DN}' -s base dn"
ssh_cmd "${REPLICA_PUBLIC_IP}" "sudo /opt/symas/bin/ldapwhoami -x -H ldap://localhost:389 -D '${ADMIN_DN}' -w '${ADMIN_PW}'"

echo "== replication write/read =="
ssh_cmd "${MASTER_PUBLIC_IP}" "cat >/tmp/${UID_VALUE}.ldif <<'LDIF'
dn: uid=${UID_VALUE},ou=people,${BASE_DN}
objectClass: inetOrgPerson
cn: Codex Replication Check
sn: Check
uid: ${UID_VALUE}
mail: ${UID_VALUE}@example.test
LDIF
sudo /opt/symas/bin/ldapadd -x -H ldap://localhost:389 -D '${ADMIN_DN}' -w '${ADMIN_PW}' -f /tmp/${UID_VALUE}.ldif"

for _ in {1..30}; do
  if ssh_cmd "${REPLICA_PUBLIC_IP}" "sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 -D '${ADMIN_DN}' -w '${ADMIN_PW}' -b '${BASE_DN}' '(uid=${UID_VALUE})' dn" | grep -q "uid=${UID_VALUE}"; then
    echo "replication=PASS uid=${UID_VALUE}"
    exit 0
  fi
  sleep 2
done

echo "replication=FAIL uid=${UID_VALUE}" >&2
exit 1
