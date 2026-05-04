#!/usr/bin/env bash
set -euo pipefail

# Smoke test: SSH to every node in terraform/openldap using the injected EC2 key pair.
#
# This script intentionally reads AWS creds only to allow `terraform output` to work
# with the S3 backend. SSH itself uses the local private key.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
stack_dir="$repo_root/terraform/openldap"
aws_env_file="$repo_root/terraform/key.aws.text"

ssh_key="$stack_dir/.local-ssh/openldap_mm"
ssh_user="ec2-user"

if [[ -f "$aws_env_file" ]]; then
  # shellcheck disable=SC1090
  eval "$(sed -n '/^export /p' "$aws_env_file")"
fi

# Backend/provider are in us-east-1 for this stack.
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ ! -f "$ssh_key" ]]; then
  echo "Missing SSH private key: $ssh_key" >&2
  exit 1
fi

ips_json="$(terraform -chdir="$stack_dir" output -json instance_public_ips)"
entries=()
while IFS= read -r line; do
  entries+=("$line")
done < <(echo "$ips_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')

echo "Public IPs:"
printf '%s\n' "${entries[@]}"
echo

echo "Waiting for SSH to become available on all nodes..."
retries=30
sleep_s=10
while (( retries > 0 )); do
  failed=0
  for e in "${entries[@]}"; do
    name="${e%%=*}"
    ip="${e#*=}"
    [[ -z "$ip" || "$ip" == "null" ]] && continue
    if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 \
      -i "$ssh_key" "$ssh_user@$ip" true >/dev/null 2>&1; then
      failed=$((failed + 1))
    fi
  done

  if (( failed == 0 )); then
    echo "SSH OK to all nodes"
    break
  fi

  retries=$((retries - 1))
  echo "SSH not ready yet ($failed failing). Retries left: $retries"
  sleep "$sleep_s"
done

echo
echo "Per-host SSH check (hostname + whoami):"
all_ok=1
for e in "${entries[@]}"; do
  name="${e%%=*}"
  ip="${e#*=}"
  [[ -z "$ip" || "$ip" == "null" ]] && continue
  echo "==> $name $ip"
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 \
    -i "$ssh_key" "$ssh_user@$ip" 'hostname; whoami'; then
    :
  else
    all_ok=0
  fi
  echo
done

if (( all_ok == 1 )); then
  echo "RESULT: SSH succeeded to all nodes"
else
  echo "RESULT: SSH failed to one or more nodes" >&2
  exit 2
fi
