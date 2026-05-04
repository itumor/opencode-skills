# OpenLDAP MirrorMode AWS Lab Report

Date: 2026-02-07

## Goal
Provision the AWS lab with Terraform, bootstrap OpenLDAP (MirrorMode masters + read-only replica), and validate:
- admin binds
- replicator binds
- write path vs read-only path
- MirrorMode peer replication (master-1 <-> master-2)
- replica syncrepl from masters

## Terraform
### AWS Credentials
Used repo-local env file `terraform/key.aws.text` (not included here because it contains long-lived keys).

### Remote State Bootstrap
Terraform module: `terraform/bootstrap`
- State bucket: `openldap-mm-tfstate-20260131-nklx28`
- Lock table: `openldap-mm-tf-lock-20260131-nklx28`

Logs:
- `reports/logs/terraform_bootstrap_init.txt`
- `reports/logs/terraform_bootstrap_apply.txt`

### OpenLDAP Lab
Terraform module: `terraform/openldap`
Terraform vars used:
- `aws_region=us-east-1`
- `masters_per_vpc=2`
- `replicas_per_vpc=1`
- `enable_global_accelerator=false`
- `enable_keepalived=false`

Artifacts bucket:
- `openldap-mm-artifacts-f27302f0`

Load balancers:
- live write: `openldap-mm-live-w-7b768a0065d56e98.elb.us-east-1.amazonaws.com`
- live read:  `openldap-mm-live-r-566d5423cd6457d0.elb.us-east-1.amazonaws.com`
- dr write:   `openldap-mm-dr-w-82967a7df4d72e69.elb.us-east-1.amazonaws.com`
- dr read:    `openldap-mm-dr-r-992f18f5817d1f87.elb.us-east-1.amazonaws.com`

Terraform logs:
- `reports/logs/terraform_openldap_init.txt`
- `reports/logs/terraform_openldap_apply.txt`
- `reports/logs/terraform_openldap_apply_fix1.txt`

## OpenLDAP Bootstrap Implementation
Bootstrap entrypoint used by AWS user-data:
- `terraform/openldap/artifacts/bootstrap-ldap.sh`

Key fixes required to make AWS nodes converge:
1. Symas fallback support
   - RHEL AMIs did not have `openldap-servers` available; bootstrap fell back to Symas OpenLDAP.
   - Symas service failed initially because it expects a config; the bootstrap now initializes `cn=config` using `slapadd -n 0`.
2. SELinux context
   - SELinux is enforcing on these hosts.
   - `restorecon -Rv` is used to label cn=config and DB directories so slapd can read/write.
3. LDIF correctness
   - Fixed multiple heredoc-generated LDIF blocks that were indented (leading spaces) which broke LDIF parsing.
4. Replicator auth
   - Store `cn=replicator` password as `{SSHA}`.
   - Fix ACLs so simple binds work (`userPassword` needs `anonymous auth` + `self write`).
   - Re-run bootstrap on both masters per VPC so the write NLB behaves consistently.

Bootstrap was re-run on each node via AWS SSM after uploading the updated `bootstrap-ldap.sh` into the artifacts bucket.
SSM logs are under `reports/logs/ssm_*.txt` / `reports/logs/ssm_*.json`.

## Current EC2 Nodes (At Time Of Final Test)
Live VPC:
- master-1: `i-07970dbb117b0ca9f` public `13.222.25.172` private `10.10.0.10`
- master-2: `i-0e974c7f75ec4403b` public `3.83.147.211` private `10.10.1.11`
- replica-1: `i-0ec946aa5d0bdc7fa` public `3.235.161.16` private `10.10.0.30`

DR VPC:
- master-1: `i-0405e2e8887b597ea` public `98.91.186.236` private `10.20.0.10`
- master-2: `i-02513b5456289a621` public `35.174.5.20` private `10.20.1.11`
- replica-1: `i-025fc21a50e9d2ef2` public `18.213.245.85` private `10.20.0.30`

## LDAP Test Results
Final test run log:
- `reports/logs/aws_ldap_tests_v4.txt`

What was validated:
- Admin bind succeeds on live/dr write and read NLBs.
- Replicator bind succeeds on live/dr write NLBs.
- Write to `live-master-1` replicated to `live-master-2` (MirrorMode peer) and `live-replica-1` (syncrepl consumer).
- Writes on replicas fail as expected (read-only).
- Same validations on DR side.

## Notes / Follow-Ups
- The RHEL AMI repo set did not expose `openldap-servers`; Symas install is the supported path for this lab as currently configured.
- Consider making the SSM rerun flow first-class by writing `/opt/openldap/bootstrap/node.env` from user-data for easy manual re-runs.
- Consider reducing noise from repeated `dnf` operations in subsequent bootstrap re-runs (idempotency).
