---
name: aws-ec2-ops
description: AWS EC2 operational knowledge — launch, resize, stop, terminate, Elastic IP, security groups, key pairs, SSH access. Use when asked to manage EC2 instances, open/close ports, allocate IPs, or run AWS CLI operations. Also covers cost checking and cleanup patterns.
---

# AWS EC2 Operations — Quick Reference

## Credentials

```bash
source /Users/eramadan/openscript/nextgenopen/.env
# vars: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION=us-west-2
# also: $gitlab_token, $gitlab_username
```

## Account

- Account ID: `083792476705`
- Region: `us-west-2`

## Launch EC2

```bash
# Get latest RHEL 9 AMI
AMI=$(aws ec2 describe-images --owners 309956199498 \
  --filters "Name=name,Values=RHEL-9.*_HVM-*-x86_64-*" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)

# Get latest Windows 2022 AMI
WIN_AMI=$(aws ec2 describe-images --owners amazon \
  --filters "Name=name,Values=Windows_Server-2022-English-Full-Base-*" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)

# Default VPC + subnet
VPC=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text)
SUBNET=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=availabilityZone,Values=us-west-2a" --query 'Subnets[0].SubnetId' --output text)
MY_IP=$(curl -s https://checkip.amazonaws.com)/32
```

## Key Pairs

```bash
# Create
KEY_NAME="my-key-$(date +%Y%m%d)"
KEY_FILE="/var/folders/6f/d1t0_mk542lbwrztssz2rcdh0000gp/T/opencode/${KEY_NAME}.pem"
aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "$KEY_FILE"
chmod 600 "$KEY_FILE"
```

## Security Groups

```bash
# Create SG
SG=$(aws ec2 create-security-group --group-name "my-sg-$(date +%H%M%S)" \
  --description "desc" --vpc-id $VPC --query 'GroupId' --output text)

# Open port
aws ec2 authorize-security-group-ingress --group-id $SG \
  --protocol tcp --port 22 --cidr $MY_IP

# Open all (for testing only)
aws ec2 authorize-security-group-ingress --group-id $SG \
  --protocol -1 --cidr 0.0.0.0/0

# Delete SG
aws ec2 delete-security-group --group-id $SG
```

## Elastic IP

```bash
# Allocate
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
EIP=$(aws ec2 describe-addresses --allocation-ids $EIP_ALLOC --query 'Addresses[0].PublicIp' --output text)

# Associate
aws ec2 associate-address --instance-id $INSTANCE_ID --allocation-id $EIP_ALLOC

# Release
aws ec2 release-address --allocation-id $EIP_ALLOC
```

## Instance Lifecycle

```bash
# List running
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress,InstanceType,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# Stop
aws ec2 stop-instances --instance-ids $ID
aws ec2 wait instance-stopped --instance-ids $ID

# Start
aws ec2 start-instances --instance-ids $ID
aws ec2 wait instance-running --instance-ids $ID
NEW_IP=$(aws ec2 describe-instances --instance-ids $ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# Resize (must be stopped first)
aws ec2 modify-instance-attribute --instance-id $ID --instance-type t3.large

# Terminate
aws ec2 terminate-instances --instance-ids $ID
aws ec2 wait instance-terminated --instance-ids $ID

# Reboot
aws ec2 reboot-instances --instance-ids $ID
```

## SSH

```bash
KEY=/var/folders/6f/d1t0_mk542lbwrztssz2rcdh0000gp/T/opencode/my-key.pem
# RHEL/Amazon Linux
ssh -i $KEY -o StrictHostKeyChecking=no ec2-user@$IP

# Wait for SSH ready
for i in $(seq 1 30); do
  ssh -i $KEY -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@$IP "echo ready" 2>/dev/null && break
  sleep 8
done
```

## Cost Check

```bash
# Daily this month
aws ce get-cost-and-usage \
  --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity DAILY --metrics UnblendedCost \
  --query 'ResultsByTime[*].[TimePeriod.Start,Total.UnblendedCost.Amount]' --output table

# By service this month
aws ce get-cost-and-usage \
  --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups[*].[Keys[0],Metrics.UnblendedCost.Amount]' --output table
```

## Instance Types Reference

| Type | vCPU | RAM | Cost/hr (Windows) | Cost/hr (Linux) |
|------|------|-----|-------------------|-----------------|
| t3.micro | 2 | 1GB | ~$0.017 | ~$0.010 |
| t3.small | 2 | 2GB | ~$0.023 | ~$0.023 |
| t3.medium | 2 | 4GB | ~$0.048 | ~$0.042 |
| t3.large | 2 | 8GB | ~$0.096 | ~$0.083 |
| t3.xlarge | 4 | 16GB | ~$0.192 | ~$0.166 |

## Temp Key Storage Path

`/var/folders/6f/d1t0_mk542lbwrztssz2rcdh0000gp/T/opencode/`
