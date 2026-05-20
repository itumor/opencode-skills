# OpenLDAP 2-EC2 Master/Replica AWS Report

Date: 2026-05-19

## Summary

- Status: PASS
- Terraform root: `terraform/openldap-master-replica`
- Region: `us-west-2`
- Topology: 1 master EC2 + 1 read-only replica EC2
- Bootstrap method: SSH Terraform provisioners
- LDAP replication: PASS

## AWS Resources

| Role | Instance ID | Private IP | Public IP |
| --- | --- | --- | --- |
| master | `i-066ec5cd4bc2f9f9d` | `10.30.1.10` | `52.13.60.230` |
| replica | `i-037c148651f4ab98e` | `10.30.2.10` | `54.189.212.43` |

Other resources:

- VPC: `vpc-03387fa2e3dfd3239`
- Security group: `sg-09caee7e57cbd29e5`
- Key pair: `openldap-mr-20260519134357610200000001`
- SSH/LDAP external CIDR used for this run: `94.30.232.121/32`

## Validation Results

| Check | Result |
| --- | --- |
| `terraform fmt -check` | PASS |
| `terraform validate` | PASS |
| `terraform plan` | PASS, 13 resources create |
| `terraform apply` | PASS |
| Post-apply drift plan | PASS, no changes |
| SSH master | PASS |
| SSH replica | PASS |
| Master service `symas-openldap-servers` | PASS, active |
| Replica service `symas-openldap-servers` | PASS, active |
| Master LDAP bind | PASS |
| Master base DN search | PASS |
| Replica LDAP bind | PASS |
| Replication write/read | PASS |

Replication proof:

- Test UID: `codexcheck20260519135333`
- Write target: master
- Read target: replica
- Result: `replication=PASS`

Fresh SSH script run:

- Date/time: 2026-05-19 14:17 UTC
- Command: `terraform/openldap-master-replica/scripts/verify.sh`
- Master service check: PASS, `active`
- Replica service check: PASS, `active`
- Master bind/search: PASS
- Replica bind: PASS
- Test UID: `codexcheck20260519141741`
- Write target: master
- Read target: replica
- Result: `replication=PASS`
- Standalone SSH run guide: `terraform/openldap-master-replica/SSH_RUN_GUIDE.md`

## Issues Found And Fixed

- Initial bootstrap failed with exit `137`.
- Cause: `dnf` was OOM-killed on `t3.micro` with no swap.
- Fix: bootstrap script now creates a 2G `/swapfile` before package installation.
- Second bootstrap failed with exit `247`.
- Cause: master LDIF mixed database `modify` and syncprov overlay `add` in one `ldapmodify` operation.
- Fix: split master configuration into ACL `ldapmodify` and syncprov `ldapadd`.

## Run Commands

```bash
set -a
source .env
set +a

mkdir -p terraform/openldap-master-replica/.local-ssh
ssh-keygen -t ed25519 -N "" -f terraform/openldap-master-replica/.local-ssh/openldap_master_replica

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
./scripts/verify.sh
```

Destroy when the lab is no longer needed:

```bash
cd terraform/openldap-master-replica
MY_IP="$(curl -s https://checkip.amazonaws.com)/32"
terraform destroy \
  -var="admin_cidr_blocks=[\"${MY_IP}\"]" \
  -var="ldap_cidr_blocks=[\"${MY_IP}\"]"
```
