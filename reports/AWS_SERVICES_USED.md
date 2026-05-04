# AWS Services Used In This Project (NEXTGenopen)

This document lists the AWS services used by this repo and why they are used.

Scope notes:

- Primary infrastructure lives under `terraform/openldap/` (OpenLDAP MirrorMode simulation: Live + DR).
- Terraform state/bootstrap lives under `terraform/bootstrap/`.
- Some helper infrastructure exists under `terraform/ec2-rhel97/` (standalone EC2 host for testing).

## Service List (What + Why)

| AWS service | Where it appears | Why it is used in this project |
|---|---|---|
| Amazon EC2 | `terraform/openldap/main.tf`, `terraform/ec2-rhel97/main.tf` | Runs the OpenLDAP nodes (masters and read-only replicas) and their bootstrap/configuration scripts. Also used for a standalone RHEL 9.7 test instance module. |
| Amazon VPC | `terraform/openldap/main.tf`, `terraform/ec2-rhel97/main.tf` (data sources) | Provides isolated networking for the LDAP environments. The OpenLDAP lab creates two VPCs (`live` and `dr`) to simulate dual-site deployments. |
| VPC Subnets | `terraform/openldap/main.tf`, `terraform/ec2-rhel97/main.tf` (data sources) | Places instances and load balancers into specific Availability Zones within each VPC. |
| Internet Gateway (IGW) | `terraform/openldap/main.tf` | Enables outbound/inbound internet connectivity for public subnets (used for bootstrapping packages/agents and optional public access to services). |
| Route Tables and Routes | `terraform/openldap/main.tf` | Routes `0.0.0.0/0` traffic to the IGW for public subnets, and adds routes for cross-VPC traffic via VPC peering. |
| VPC Peering | `terraform/openldap/main.tf` | Connects the `live` and `dr` VPCs so the topology can simulate cross-site replication and admin access across environments. |
| Security Groups | `terraform/openldap/main.tf`, `terraform/ec2-rhel97/main.tf` | Controls network access to SSH and LDAP ports, and (optionally) VRRP protocol for keepalived between masters. |
| Elastic Load Balancing (ELBv2) Network Load Balancers (NLB) | `terraform/openldap/main.tf` | Provides stable read and write entry points per VPC (`read` and `write` NLBs) and performs TCP health checks to instances. |
| AWS Global Accelerator | `terraform/openldap/global-accelerator.tf` | Optional global anycast front door for the read/write endpoints, routing TCP/389 traffic to the Live and DR NLBs (requires internet-facing NLBs). |
| Amazon S3 | `terraform/bootstrap/main.tf`, `terraform/openldap/artifacts.tf`, `terraform/openldap/backend.tf`, `terraform/openldap/templates/user-data.sh.tmpl`, `terraform/openldap/artifacts/bootstrap-ldap.sh` | Stores Terraform remote state (state bucket) and stores instance bootstrap artifacts (scripts/LDIFs/bootstrap script) that EC2 syncs at boot or via SSM re-runs. |
| Amazon DynamoDB | `terraform/bootstrap/main.tf` | Used for Terraform state locking (prevents concurrent applies against the same remote state). |
| AWS Identity and Access Management (IAM) | `terraform/openldap/iam.tf` | Provides an EC2 instance role and instance profile allowing instances to read artifacts from S3, and (optionally) manage EIP association for keepalived-based VIP simulation. Also attaches the managed policy needed for SSM. |
| AWS Systems Manager (SSM) | `terraform/openldap/iam.tf`, `terraform/openldap/templates/user-data.sh.tmpl`, `terraform/openldap/tools/ssm_run.sh`, `terraform/openldap/tools/e2e_level2_ssm.sh`, `terraform/openldap/tools/rerun_bootstrap_all_ssm.sh` | Installs and enables the SSM agent on instances, then uses SSM Run Command to run checks, re-run bootstrap, and perform E2E verification without SSH. |
| Elastic IP (EIP) | `terraform/openldap/keepalived.tf`, `terraform/openldap/artifacts/bootstrap-ldap.sh` | Optional static public IP used to simulate a VIP failover target when keepalived is enabled. Terraform can create the EIP, and the instance can associate it during failover via EC2 API calls. |
| Amazon Machine Images (AMIs) (EC2 Images) | `terraform/openldap/main.tf`, `terraform/ec2-rhel97/main.tf` | Uses AMI lookups (data sources) to select the most recent RHEL image (or a user-provided AMI), ensuring a consistent base OS for OpenLDAP nodes. |
| AWS Key Pairs (EC2 key pair) | `terraform/ec2-rhel97/main.tf` | Optional: creates or references an EC2 key pair to allow SSH access to the standalone EC2 test instance. (The OpenLDAP lab also supports a provided `ssh_key_name` for SSH access.) |

## Mapping To Project Features

These are the major project features and the AWS services that enable them:

- Dual-site simulation (Live + DR): VPC, Subnets, Route Tables/Routes, VPC Peering, Security Groups, EC2.
- Read and write endpoints: NLB (ELBv2), Target Groups, Listeners.
- Optional global front door: Global Accelerator (requires internet-facing NLBs).
- Bootstrap artifact distribution: S3 + EC2 user-data, plus SSM for re-runs.
- Remote Terraform operations: S3 backend + DynamoDB lock table.
- Instance permissions: IAM role + instance profile + managed SSM policy attachment.
- Optional VIP simulation: EIP + EC2 API permissions + keepalived configuration in bootstrap.

## References In Repo

- OpenLDAP lab Terraform: `terraform/openldap/`
- Terraform state bootstrap: `terraform/bootstrap/`
- Standalone EC2 test module: `terraform/ec2-rhel97/`
- Architecture/runbook: `terraform/openldap/RUNBOOK.md`

