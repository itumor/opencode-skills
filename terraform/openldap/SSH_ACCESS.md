# SSH Access To OpenLDAP EC2 Instances

This stack creates multiple EC2 instances under `aws_instance.node` (masters and replicas) and outputs their public IPs.

Important limitation: you cannot add an EC2 SSH key pair to an existing instance after it is created. To use SSH keys, set `ssh_key_name` before the instances are created, or be prepared for Terraform to replace the instances.

If `ssh_key_name` is empty, this module will auto-create an EC2 key pair from `terraform/openldap/.local-ssh/openldap_mm.pub` and use it for all instances.

## Option A (Recommended For Existing Deployments): Use SSM Instead Of SSH

These instances have an IAM role with SSM attached, so you can get an interactive shell without opening SSH.

1) Get instance IDs:

```bash
cd terraform/openldap
terraform output -json instance_ids
```

2) Start a session (example for `live-master-1`):

```bash
aws ssm start-session --target "$(terraform output -json instance_ids | jq -r '.\"live-master-1\"')"
```

Notes:
- This requires `jq` and the AWS CLI configured for the same account/region as the deployment (`aws_region`).
- If you prefer, you can also use the AWS Console Session Manager.

## Option B: Enable SSH Key Injection (Requires Recreate If Already Applied)

### 1) Create a local SSH keypair

```bash
mkdir -p terraform/openldap/.local-ssh
ssh-keygen -t ed25519 -f terraform/openldap/.local-ssh/openldap_mm -C openldap-mm
chmod 600 terraform/openldap/.local-ssh/openldap_mm
```

### 2) Import the public key as an EC2 key pair

Pick a keypair name, for example `openldap-mm-ssh`:

```bash
aws ec2 import-key-pair \
  --key-name openldap-mm-ssh \
  --public-key-material "fileb://terraform/openldap/.local-ssh/openldap_mm.pub" \
  --region us-east-1
```

### 3) Configure Terraform to use that keypair

Edit `terraform/openldap/terraform.tfvars`:

```hcl
ssh_key_name = "openldap-mm-ssh"
admin_cidr_blocks = ["YOUR_PUBLIC_IP/32"]
```

Then apply:

```bash
cd terraform/openldap
terraform apply
```

## Connecting To All Instances Over SSH

1) Fetch the public IPs:

```bash
cd terraform/openldap
terraform output -json instance_public_ips
```

2) SSH to one instance (example `live-master-1`):

```bash
ssh -i terraform/openldap/.local-ssh/openldap_mm ec2-user@"$(terraform output -json instance_public_ips | jq -r '.[\"live-master-1\"]')"
```

3) SSH to all instances (loops over all keys in the output):

```bash
cd terraform/openldap
for name in $(terraform output -json instance_public_ips | jq -r 'keys[]'); do
  ip=$(terraform output -json instance_public_ips | jq -r --arg n "$name" '.[$n]')
  echo "==> $name ($ip)"
  ssh -o StrictHostKeyChecking=accept-new -i ../openldap/.local-ssh/openldap_mm ec2-user@"$ip" 'hostname; uptime' || true
done
```

4) Scripted SSH smoke test (recommended after apply):

```bash
terraform/openldap/tools/test_ssh_all.sh
```

Troubleshooting:
- If SSH times out, confirm `admin_cidr_blocks` includes your current public IP range and that the instance has a public IP (`assign_public_ip=true`).
- RHEL on AWS commonly uses `ec2-user` as the default user.
