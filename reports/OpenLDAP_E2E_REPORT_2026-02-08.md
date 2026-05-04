# OpenLDAP AWS E2E Report

- Date (UTC): 2026-02-08T11:15:58Z
- Region: us-east-1

## Inputs

- Base DN: dc=cae,dc=local
- Terraform vars: terraform/openldap/terraform.tfvars
- Terraform outputs: reports/logs/terraform_openldap_outputs_2026-02-07.json
- Instances: reports/logs/ec2_openldap_instances_2026-02-08.json
- Terraform plan snapshot: reports/logs/terraform_openldap_plan_2026-02-07_after_e2e.txt

## Endpoints

- live write NLB: openldap-mm-live-w-7b768a0065d56e98.elb.us-east-1.amazonaws.com:389
- live read  NLB: openldap-mm-live-r-566d5423cd6457d0.elb.us-east-1.amazonaws.com:389
- dr write NLB: openldap-mm-dr-w-82967a7df4d72e69.elb.us-east-1.amazonaws.com:389
- dr read  NLB: openldap-mm-dr-r-992f18f5817d1f87.elb.us-east-1.amazonaws.com:389

## Replication Validation

- Per-VPC MirrorMode: validated only when a VPC has >=2 masters (see VPC Matrix).
- Cross-VPC master-master (Option B): yes
  - live->dr uid: e2e-cross-20260208111542-live
  - dr->live uid: e2e-cross-20260208111542-dr

## Inventory

| VPC | Role | Name | InstanceId | PrivateIp | PublicIp | LaunchTime |
|---|---|---|---|---|---|---|
| dr | master | openldap-mm-dr-master-1 | i-0e03d29332e844401 | 10.20.0.10 | 98.92.35.70 | 2026-02-07T20:49:46+00:00 |
| dr | replica | openldap-mm-dr-replica-1 | i-010e8c7f976def4f3 | 10.20.1.30 | 52.55.244.33 | 2026-02-07T20:49:46+00:00 |
| dr | replica | openldap-mm-dr-replica-2 | i-0bd30239ea5409852 | 10.20.0.31 | 3.237.188.187 | 2026-02-07T20:49:46+00:00 |
| live | master | openldap-mm-live-master-1 | i-05125037a72684ba0 | 10.10.0.10 | 35.174.125.122 | 2026-02-07T20:49:47+00:00 |
| live | replica | openldap-mm-live-replica-1 | i-019770ed9cc71a281 | 10.10.1.30 | 13.221.182.18 | 2026-02-07T20:49:46+00:00 |
| live | replica | openldap-mm-live-replica-2 | i-0bd5b5aa3f95358a6 | 10.10.0.31 | 44.201.53.85 | 2026-02-07T20:49:46+00:00 |

## Results

- VPC test matrix: reports/logs/e2e_vpc_results_2026-02-08.csv
- SSM logs: reports/logs/ssm_*

### VPC Matrix

| vpc | test_uid | mirrormode |
|---|---|---|
| live | e2e-live-20260208111432 | no |
| dr | e2e-dr-20260208111458 | no |

## Terraform Drift

- Plan file: reports/logs/terraform_openldap_plan_2026-02-07_after_e2e.txt
- Summary: Plan: 12 to add, 2 to change, 12 to destroy.

- Note: instance replacements are expected if EC2 `user_data` changed and `user_data_replace_on_change` is enabled.

## Notes

- If a VPC has only 1 master, per-VPC MirrorMode cannot be validated in that VPC (tests mark mirrormode=no).
- For Option B topologies (one master in live + one master in dr), use the Cross-VPC master-master result above.
- Bootstrap marker file: /opt/openldap/.bootstrap_done
- Bootstrap env file: /opt/openldap/bootstrap/node.env
- SSH is not currently available on these instances (no EC2 keypair); post-provisioning is done via AWS SSM.
