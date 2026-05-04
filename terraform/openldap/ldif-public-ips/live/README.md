# Apply LDIFs: live Cluster

## Dynamic Node IPs

From repo root:

```bash
eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"
terraform -chdir=terraform/openldap output -json instance_public_ips | jq -r 'to_entries|sort_by(.key)|.[]|"\(.key)\t\(.value)"'
```

## Apply Via SSM (Recommended)

No inbound SSH required:

```bash
bash terraform/openldap/ldif-public-ips/apply_over_ssm.sh us-east-1 live/live-master-1
bash terraform/openldap/ldif-public-ips/apply_over_ssm.sh us-east-1 live/live-replica-1
bash terraform/openldap/ldif-public-ips/apply_over_ssm.sh us-east-1 live/live-replica-2
```

## Apply Via SSH (Optional)

```bash
eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"
LIVE_MASTER_IP="$(terraform -chdir=terraform/openldap output -json instance_public_ips | jq -r '."live-master-1"')"
LIVE_REPLICA_1_IP="$(terraform -chdir=terraform/openldap output -json instance_public_ips | jq -r '."live-replica-1"')"
LIVE_REPLICA_2_IP="$(terraform -chdir=terraform/openldap output -json instance_public_ips | jq -r '."live-replica-2"')"

bash terraform/openldap/ldif-public-ips/apply_over_ssh.sh live/live-master-1   "$LIVE_MASTER_IP"
bash terraform/openldap/ldif-public-ips/apply_over_ssh.sh live/live-replica-1  "$LIVE_REPLICA_1_IP"
bash terraform/openldap/ldif-public-ips/apply_over_ssh.sh live/live-replica-2  "$LIVE_REPLICA_2_IP"
```

## Verify (Optional)

On `live-master-1`:

```bash
ssh -i terraform/openldap/.local-ssh/openldap_mm ec2-user@"$LIVE_MASTER_IP" \
  'sudo /opt/symas/bin/ldapsearch -LLL -Y EXTERNAL -H ldapi://%2Fvar%2Fsymas%2Frun%2Fldapi -b cn=config "(objectClass=olcGlobal)" olcServerID'
```

On each replica, check it has `olcSyncRepl` pointing to the **private** master IP (`10.10.0.10`):

```bash
ssh -i terraform/openldap/.local-ssh/openldap_mm ec2-user@"$LIVE_REPLICA_1_IP" \
  'sudo /opt/symas/bin/ldapsearch -LLL -Y EXTERNAL -H ldapi://%2Fvar%2Fsymas%2Frun%2Fldapi -b "olcDatabase={1}mdb,cn=config" -s base olcSyncRepl olcUpdateRef olcReadOnly'
```
