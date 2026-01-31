# AWS OpenLDAP MirrorMode (Terraform)

This Terraform project provisions a low-cost OpenLDAP MirrorMode lab in AWS using RHEL EC2 instances. It mirrors the architecture in `openldap-mirrormode/`:

- 2 VPCs: `live` and `dr`
- Per VPC: 1 master + 2 read-only replicas (3 nodes)
- 2 Network Load Balancers per VPC: **write** (masters) and **read** (replicas)
- VPC peering between `live` and `dr`
- OpenLDAP configured via cloud-init using the same replication flow as `openldap-mirrormode/scripts/apply-replication-ldifs.sh`
- Optional keepalived on the primary masters (live/dr) to move a single Elastic IP for write failover

6> Cost note: this creates 12 EC2 instances + 4 NLBs + public IPv4 addresses. AWS Free Tier (750 hrs/month) will **not** cover this. For lower cost, reduce `masters_per_vpc`, `replicas_per_vpc`, use smaller instance types, or deploy only one VPC.

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
