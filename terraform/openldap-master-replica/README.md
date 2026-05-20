# OpenLDAP Master/Replica on 2 EC2 Instances

This Terraform root creates exactly two RHEL EC2 instances:

- `openldap-mr-master-1`
- `openldap-mr-replica-1`

The master is writable. The replica is configured as a read-only OpenLDAP syncrepl consumer.

## Prerequisites

- Terraform installed.
- AWS CLI credentials in repo-root `.env`.
- GitLab credentials in repo-root `.env` only for pushing and MR creation.
- No secrets or Terraform state committed.

## 1. Load Credentials

From repo root:

```bash
set -a
source .env
set +a
```

## 2. Create SSH Key

```bash
mkdir -p terraform/openldap-master-replica/.local-ssh
ssh-keygen -t ed25519 -N "" -f terraform/openldap-master-replica/.local-ssh/openldap_master_replica
```

If the key already exists, keep it and skip generation.

## 3. Deploy

```bash
cd terraform/openldap-master-replica
terraform init
terraform fmt -check
terraform validate
MY_IP="$(curl -s https://checkip.amazonaws.com)/32"
terraform plan \
  -var="admin_cidr_blocks=[\"${MY_IP}\"]" \
  -var="ldap_cidr_blocks=[\"${MY_IP}\"]"
terraform apply \
  -var="admin_cidr_blocks=[\"${MY_IP}\"]" \
  -var="ldap_cidr_blocks=[\"${MY_IP}\"]"
```

`admin_cidr_blocks` controls SSH. `ldap_cidr_blocks` controls external LDAP/LDAPS test access. The VPC CIDR is always allowed for master-to-replica replication.

## 4. Verify

```bash
cd terraform/openldap-master-replica
ADMIN_PW="${TF_VAR_admin_password:-admin}" ./scripts/verify.sh
```

The verify script checks:

- SSH to both EC2 instances.
- `symas-openldap-servers` active on both instances.
- LDAP admin bind on master and replica.
- Base DN search.
- Write test user to master.
- Read same user from replica.

## 5. Useful Outputs

```bash
terraform output
terraform output -raw master_public_ip
terraform output -raw replica_public_ip
```

## 6. Destroy

```bash
cd terraform/openldap-master-replica
terraform destroy
```

## Notes

- Default region: `us-west-2`.
- Default base DN: `dc=cae,dc=local`.
- Default admin DN: `cn=admin,dc=cae,dc=local`.
- For production-like use, pass strong passwords with `TF_VAR_admin_password` and `TF_VAR_replication_password` from the environment.
