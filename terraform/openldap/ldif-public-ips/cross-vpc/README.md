# Enable Cross-VPC Master-Master (Public IPs)

This is **optional**.

It configures `live-master-1` and `dr-master-1` to syncrepl from each other using the **private** IPs (`10.10.0.10` <-> `10.20.0.10`). You still apply it over SSH to the nodes' public IPs.

## Apply

From the repo root:

```bash
# Include BOTH serverID mappings (public IPs) and enable MirrorMode-style syncrepl on both masters.

# Recommended: apply via SSM (no inbound SSH required)
bash terraform/openldap/ldif-public-ips/apply_over_ssm.sh us-east-1 cross-vpc/live-master-1
bash terraform/openldap/ldif-public-ips/apply_over_ssm.sh us-east-1 cross-vpc/dr-master-1

# Optional: apply via SSH (pull IPs from Terraform)
eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"
LIVE_MASTER_IP="$(terraform -chdir=terraform/openldap output -json instance_public_ips | jq -r '."live-master-1"')"
DR_MASTER_IP="$(terraform -chdir=terraform/openldap output -json instance_public_ips | jq -r '."dr-master-1"')"

bash terraform/openldap/ldif-public-ips/apply_over_ssh.sh cross-vpc/live-master-1 "$LIVE_MASTER_IP"
bash terraform/openldap/ldif-public-ips/apply_over_ssh.sh cross-vpc/dr-master-1 "$DR_MASTER_IP"
```

Note: `apply_over_ssh.sh` is idempotent-ish (it uses `ldapmodify` + `|| true`).

## Verify

```bash
ssh -i terraform/openldap/.local-ssh/openldap_mm ec2-user@"$LIVE_MASTER_IP" \
  'sudo /opt/symas/bin/ldapsearch -LLL -Y EXTERNAL -H ldapi://%2Fvar%2Fsymas%2Frun%2Fldapi -b "olcDatabase={1}mdb,cn=config" -s base olcSyncRepl olcMirrorMode'

ssh -i terraform/openldap/.local-ssh/openldap_mm ec2-user@"$DR_MASTER_IP" \
  'sudo /opt/symas/bin/ldapsearch -LLL -Y EXTERNAL -H ldapi://%2Fvar%2Fsymas%2Frun%2Fldapi -b "olcDatabase={1}mdb,cn=config" -s base olcSyncRepl olcMirrorMode'
```
