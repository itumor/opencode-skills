# Ansible OpenLDAP (MirrorMode) Bootstrap

This folder bootstraps the EC2 nodes created by `terraform/openldap`.

As of 2026-02-09, Terraform runs this Ansible convergence automatically after EC2 provisioning
(`terraform/openldap/ansible.tf`). You can still run playbooks manually for re-runs.

## Prereqs (controller)

- `ansible` installed
- AWS credentials available (env, profile, SSO, etc.)
- `terraform` available (optional, but recommended): used to auto-read outputs (LB DNS, artifacts bucket, EIP alloc id)

Install collections:

```bash
cd ansible/openldap
ansible-galaxy collection install -r requirements.yml
```

## Inventory (Dynamic)

Two inventory configs are provided:

- `inventory/ssm.aws_ec2.yml` (default): connect using AWS SSM (no inbound SSH required). `ansible_host` is the instance id.
- `inventory/ssh.aws_ec2.yml`: connect using SSH (uses public IPs).

Both filter instances by tag `Name=openldap-mm-*` by default. If your Terraform `project_name` differs, edit the filter.

## Bootstrap

SSM:

```bash
cd ansible/openldap
ansible-playbook -i inventory/ssm.aws_ec2.yml playbooks/bootstrap.yml
```

SSH:

```bash
cd ansible/openldap
ansible-playbook -i inventory/ssh.aws_ec2.yml playbooks/bootstrap.yml \
  -e ansible_user=ec2-user -e ansible_ssh_private_key_file=terraform/openldap/.local-ssh/openldap_mm
```

Useful overrides:

- `-e openldap_project_name=openldap-mm`
- `-e openldap_base_dn=dc=cae,dc=local`
- `-e openldap_admin_pw=... -e openldap_repl_pw=...`
- `-e openldap_enable_keepalived=false` (skip keepalived configuration)

## Verify Replication (SSM-friendly)

```bash
cd ansible/openldap
ansible-playbook -i inventory/ssm.aws_ec2.yml playbooks/verify_replication.yml
```

## Apply terraform/openldap/ldif-public-ips (SSM or SSH)

This applies the same LDIF bundles as `terraform/openldap/ldif-public-ips/apply_over_ssh.sh` and
`terraform/openldap/ldif-public-ips/apply_over_ssm.sh`, but via Ansible.

SSM (default inventory):

```bash
cd ansible/openldap
ansible-playbook -i inventory/ssm.aws_ec2.yml playbooks/apply_ldif_public_ips.yml
```

SSH:

```bash
cd ansible/openldap
ansible-playbook -i inventory/ssh.aws_ec2.yml playbooks/apply_ldif_public_ips.yml \
  -e ansible_user=ec2-user -e ansible_ssh_private_key_file=terraform/openldap/.local-ssh/openldap_mm
```

Optional cross-VPC master-master MirrorMode (applies `terraform/openldap/ldif-public-ips/cross-vpc/*`
to `*-master-1` nodes only):

```bash
cd ansible/openldap
ansible-playbook -i inventory/ssm.aws_ec2.yml playbooks/apply_ldif_public_ips.yml \
  -e openldap_ldif_public_ips_apply_cross_vpc=true
```
