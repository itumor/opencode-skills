# AWS OpenLDAP MirrorMode (Terraform)

This Terraform project provisions a low-cost OpenLDAP MirrorMode lab in AWS using RHEL EC2 instances. It mirrors the architecture in `openldap-mirrormode/`:

- 2 VPCs: `live` and `dr`
- Per VPC: 1 master + 2 read-only replicas (3 nodes)
- 2 Network Load Balancers per VPC: **write** (masters) and **read** (replicas)
- VPC peering between `live` and `dr`
- OpenLDAP configured via cloud-init using the same replication flow as `openldap-mirrormode/scripts/apply-replication-ldifs.sh`
- Optional keepalived on the primary masters (live/dr) to move a single Elastic IP for write failover

> Cost note: this creates **6 EC2 instances** (1 master + 2 replicas in each VPC) + **4 NLBs** + public IPv4 addresses. AWS Free Tier will **not** fully cover this. For lower cost, keep `masters_per_vpc=1` and `replicas_per_vpc=2`, set `lb_internal=true`, and set `assign_public_ip=false`.

### Free Tier quick math (current defaults)

Assumptions:
- 6 × `t3.micro` running 24/7
- 4 public NLBs (2 per VPC) across 2 subnets each
- Public IPv4 enabled on EC2 + keepalived EIP enabled

Free Tier coverage (two cases):
- **Legacy Free Tier (accounts created before July 15, 2025, first 12 months):** 750 EC2 micro instance-hours per month, and 750 hours/month of **public IPv4 usage on EC2**. With 6 instances, you pay for ~5 instances worth of compute hours and for EC2 public IPv4 hours beyond the 750-hour allowance.
- **New Free Tier (accounts created on/after July 15, 2025):** 6‑month free plan with up to **$200 credits** (credits expire within 12 months). Those credits can apply to EC2 + NLB + IPv4 charges until depleted.

Other pricing facts:
- ELB Free Tier covers **ALB/CLB only**; **NLB is not covered**, so NLB hours + NLCU usage are billed.
- Public IPv4 addresses are billed at **$0.005 per hour each** (in-use or idle).

Estimated public IPv4 charges (if public IPs + public NLBs are enabled):
- EC2 public IPv4s: 6
- NLB public IPv4s: 4 NLBs × 2 subnets = 8
- Keepalived EIP: 1
- **Total**: 15 addresses × $0.005/hr ≈ **$0.075/hr** (~$55/month at 730 hrs)

Legacy Free Tier adjustment for EC2 public IPv4:
- 6 EC2 IPv4s × 730 hrs = 4,380 hrs
- 750 hrs free → **3,630 billable hrs** × $0.005 = **~$18.15**
- NLB + EIP IPv4s (9 addresses) remain billable → 9 × 730 × $0.005 = **~$32.85**
- **Total IPv4 estimate with Legacy Free Tier** ≈ **$51/month**

You can reduce this by setting `lb_internal=true`, `assign_public_ip=false`, and disabling keepalived/EIP if you don't need a single public write endpoint.

## 1) Bootstrap remote state

Create the S3 bucket + DynamoDB lock table:

```bash
cd terraform/bootstrap
terraform init
terraform apply \
  -var="aws_region=us-east-1" \
  -var="state_bucket_name=YOUR_BUCKET" \
  -var="lock_table_name=YOUR_LOCK_TABLE"
```

## 2) Configure the backend

Copy the example backend file:

```bash
cd terraform/openldap
cp backend.hcl.example backend.hcl
```

Edit `terraform/openldap/backend.hcl` with the bucket, region, and table from step 1.

## 3) Deploy the OpenLDAP lab

```bash
cd terraform/openldap
terraform init -backend-config=backend.hcl
terraform apply \
  -var="aws_region=us-east-1" \
  -var="ssh_key_name=YOUR_KEYPAIR"
```

## Artifacts (scripts + LDIFs)

This module syncs local content to an S3 artifacts bucket and pulls it onto each EC2 instance:

- `/script` → `/opt/openldap/script`
- `/openldap-mirrormode/ldif` → `/opt/openldap/ldif-src`
- Bootstrap script → `/opt/openldap/bootstrap/bootstrap-ldap.sh`

The bootstrap script builds LDIFs per-role and applies them using the local LDAP tools, so each EC2 instance runs its own script and uses LDIF files tailored to its role and VPC.

If you already have an artifacts bucket, set `create_artifacts_bucket=false` and `artifacts_bucket_name=your-bucket`.

## Connectivity and testing

Outputs include NLB DNS names for read/write in each VPC. Example test (if `lb_internal=false` and `ldap_cidr_blocks` allows your IP):

```bash
ldapwhoami -x -H ldap://<WRITE_LB_DNS>:389 -D "cn=admin,dc=cae,dc=local" -w admin
ldapsearch -x -H ldap://<READ_LB_DNS>:389 -D "cn=admin,dc=cae,dc=local" -w admin -b "dc=cae,dc=local" "(objectClass=*)"
```

## Key variables

- `masters_per_vpc` (default 1)
- `replicas_per_vpc` (default 2)
- `instance_type` (default `t3.micro`)
- `lb_internal` (default `false`)
- `admin_cidr_blocks` / `ldap_cidr_blocks` (default `0.0.0.0/0` for easy testing)
- `rhel_ami_id` (override the AMI if the lookup fails)
- `create_artifacts_bucket` / `artifacts_bucket_name`
- `enable_keepalived` / `keepalived_eip_allocation_id`

## Mapping to openldap-mirrormode

The bootstrap script in `terraform/openldap/artifacts/bootstrap-ldap.sh` follows the same replication steps as:

- `openldap-mirrormode/scripts/apply-replication-ldifs.sh`
- `openldap-mirrormode/ldif/*.ldif`

The AWS implementation swaps Docker container names for private IPs and uses NLB DNS names for `olcUpdateRef`.

## Keepalived note (AWS)

Keepalived in this project uses an **Elastic IP** reassociation for failover between the *live* and *dr* primary masters. This is not the same as a VRRP floating private IP (which AWS VPCs do not support across VPCs). Use the NLB DNS names for normal read/write traffic; the EIP is an optional single-address write endpoint.
