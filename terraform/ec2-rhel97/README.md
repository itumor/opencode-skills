# Single EC2 (RHEL 9.7) With SSH From Your Laptop

This Terraform stack creates:

- 1 EC2 instance running **RHEL 9.7** (latest available AMI matching the filters)
- 1 Security Group allowing **SSH (22)** only from **your laptop public IP**
- (Optional) an EC2 Key Pair created from your local `*.pub` key

## Prereqs

- AWS account + credentials available to Terraform (for example via `aws configure` or environment variables)
- Terraform installed
- An SSH keypair on your laptop

## 1) Create an SSH key (if you don't already have one)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/aws_rhel97
```

This creates:

- Private key: `~/.ssh/aws_rhel97`
- Public key: `~/.ssh/aws_rhel97.pub`

If you prefer to keep the key inside this repo (and ignored by git), use:

```bash
mkdir -p terraform/ec2-rhel97/.local-ssh
ssh-keygen -t ed25519 -f terraform/ec2-rhel97/.local-ssh/aws_rhel97
```

## 1.1) (Optional) Load AWS credentials from this repo

If you have an env file like `terraform/key.aws.text` that contains `export AWS_...` lines, load it with:

```bash
eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"
```

## 2) Get your laptop public IP (so SSH is locked down)

```bash
curl -s https://checkip.amazonaws.com
```

Take that value and append `/32` (example: `203.0.113.10/32`).

## 3) Deploy

```bash
cd terraform/ec2-rhel97
terraform init

terraform apply \
  -var="aws_region=us-west-2" \
  -var="ssh_ingress_cidr=YOUR_PUBLIC_IP/32" \
  -var="ssh_public_key_path=$HOME/.ssh/aws_rhel97.pub"
```

If you used the repo-local key above:

```bash
terraform apply \
  -var="aws_region=us-west-2" \
  -var="ssh_ingress_cidr=YOUR_PUBLIC_IP/32" \
  -var="ssh_public_key_path=$(pwd)/.local-ssh/aws_rhel97.pub"
```

## 4) SSH into the instance

RHEL on AWS uses the `ec2-user` account.

```bash
ssh -i ~/.ssh/aws_rhel97 ec2-user@$(terraform output -raw public_ip)
```

If you used the repo-local key above:

```bash
ssh -i terraform/ec2-rhel97/.local-ssh/aws_rhel97 ec2-user@$(terraform output -raw public_ip)
```

## Verified Working (February 7, 2026)

This was verified from this repo using `terraform/key.aws.text` as AWS credentials.

- Region: `us-west-2`
- Instance: `i-026db7ce9a2da5a0c`
- Public IP: `34.223.100.180`
- RHEL confirmed: `Red Hat Enterprise Linux release 9.7 (Plow)`
- SSH security group locked to laptop public IP: `94.30.232.121/32`
- SSH keypair generated:
  - Private key: `terraform/ec2-rhel97/.local-ssh/aws_rhel97`
  - Public key: `terraform/ec2-rhel97/.local-ssh/aws_rhel97.pub`

SSH:

```bash
ssh -i terraform/ec2-rhel97/.local-ssh/aws_rhel97 ec2-user@34.223.100.180
```

Copy + run a script:

```bash
scp -i terraform/ec2-rhel97/.local-ssh/aws_rhel97 ./script/YOUR_SCRIPT.sh ec2-user@34.223.100.180:/home/ec2-user/
ssh -i terraform/ec2-rhel97/.local-ssh/aws_rhel97 ec2-user@34.223.100.180 \
  'chmod +x /home/ec2-user/YOUR_SCRIPT.sh && /home/ec2-user/YOUR_SCRIPT.sh'
```

Notes:

- Fix applied: `terraform init` was failing due to invalid variable validations; checks were moved to resource `precondition`s in `terraform/ec2-rhel97/main.tf` and invalid validations removed from `terraform/ec2-rhel97/variables.tf`.
- Security: `terraform/key.aws.text` contains AWS long-lived access keys; rotate/revoke them in IAM when you can.
- Audio confirmation: `script/audio-test.sh` failed (`AudioQueueStart failed (-66680)`), and the fallback `Glass.aiff` failed with the same error, so audio could not be played in this environment.

## 5) Copy and run scripts on the EC2

Copy a local script:

```bash
scp -i ~/.ssh/aws_rhel97 ./script/YOUR_SCRIPT.sh ec2-user@$(terraform output -raw public_ip):/home/ec2-user/
```

If you used the repo-local key above:

```bash
scp -i terraform/ec2-rhel97/.local-ssh/aws_rhel97 ./script/YOUR_SCRIPT.sh ec2-user@$(terraform output -raw public_ip):/home/ec2-user/
```

Run it:

```bash
ssh -i ~/.ssh/aws_rhel97 ec2-user@$(terraform output -raw public_ip) \
  'chmod +x /home/ec2-user/YOUR_SCRIPT.sh && /home/ec2-user/YOUR_SCRIPT.sh'
```

If you used the repo-local key above:

```bash
ssh -i terraform/ec2-rhel97/.local-ssh/aws_rhel97 ec2-user@$(terraform output -raw public_ip) \
  'chmod +x /home/ec2-user/YOUR_SCRIPT.sh && /home/ec2-user/YOUR_SCRIPT.sh'
```

## 6) Tear down

```bash
terraform destroy \
  -var="aws_region=us-west-2" \
  -var="ssh_ingress_cidr=YOUR_PUBLIC_IP/32" \
  -var="ssh_public_key_path=$HOME/.ssh/aws_rhel97.pub"
```

If you used the repo-local key above:

```bash
terraform destroy \
  -var="aws_region=us-west-2" \
  -var="ssh_ingress_cidr=YOUR_PUBLIC_IP/32" \
  -var="ssh_public_key_path=$(pwd)/.local-ssh/aws_rhel97.pub"
```

## Notes about "cheapest"

- `t3.micro` is a common low-cost x86 instance type.
- If your scripts work on ARM, `t4g.micro` can be cheaper, but then set:
  - `instance_type=t4g.micro`
  - `architecture=arm64`

## LDAPS: Connect To The OpenLDAP Stack (Port 636)

This repo also contains an OpenLDAP stack in `terraform/openldap/` that exposes:

- **LDAPS** on port `636` (TLS from the LDAP server)
- (Optionally) plain LDAP / StartTLS on port `389`

### 1) Load AWS credentials from `terraform/key.aws.text`

That file contains human-readable lines plus `export AWS_...` lines. Load only the `export` lines:

```bash
eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"
```

### 2) Get the LDAPS endpoint from Terraform outputs

Global Accelerator (recommended endpoint for public testing):

```bash
READ_HOST="$(terraform -chdir=terraform/openldap output -raw ga_read_dns)"
WRITE_HOST="$(terraform -chdir=terraform/openldap output -raw ga_write_dns)"
echo "READ_HOST=$READ_HOST"
echo "WRITE_HOST=$WRITE_HOST"
```

### 3) Command-line connectivity test (from your laptop)

TCP port check:

```bash
nc -vz "$READ_HOST" 636
```

TLS handshake check (will show certificates if LDAPS is enabled on the servers):

```bash
echo | openssl s_client -connect "$READ_HOST:636" -servername "$READ_HOST" -showcerts | head -n 40
```

### 4) Test from the RHEL 9.7 EC2 instance (`terraform/ec2-rhel97`)

This stack bootstraps a helper on the instance: `ldaps-test`.

If you set `-var="ldaps_host=..."` when applying `terraform/ec2-rhel97`, you can just:

```bash
ssh -i terraform/ec2-rhel97/.local-ssh/aws_rhel97 ec2-user@$(terraform output -raw public_ip) 'ldaps-test'
```

Or pass the host explicitly:

```bash
ssh -i terraform/ec2-rhel97/.local-ssh/aws_rhel97 ec2-user@$(terraform output -raw public_ip) \
  "ldaps-test $READ_HOST 636"
```

### Note On "Port Open To The World"

In `terraform/openldap/variables.tf`, `ldap_cidr_blocks` defaults to `["0.0.0.0/0"]`, which allows public access to the LDAP/LDAPS listeners at the load balancer/Global Accelerator layer.
