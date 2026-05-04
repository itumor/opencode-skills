# OpenLDAP Terraform + Ansible E2E

## Goals

- One command to provision everything: `terraform apply`
- No install-time shell scripts (OpenLDAP install/config is done via Ansible tasks)
- One command E2E (apply + verify + destroy) using a real test framework (Go + Terratest)

## Prereqs (controller)

- `terraform`, `ansible`, `ansible-galaxy`, `go`
- AWS credentials available via env/profile/SSO
- SSH key material exists locally in `terraform/openldap/.local-ssh/` (Terraform will auto-create an EC2 keypair when `ssh_key_name=""`)
- Your public IP is allowed in `admin_cidr_blocks` (SSH is required for the Ansible run)

## One Command: Apply Everything

```bash
terraform -chdir=terraform/openldap apply
```

Notes:

- Terraform will create the AWS infrastructure, then run Ansible via `null_resource.ansible_apply`.
- Ansible will:
  - install/configure Symas OpenLDAP
  - apply `terraform/openldap/ldif-public-ips`
  - run smoke + replication verification

If you only want infra (skip Ansible), run:

```bash
terraform -chdir=terraform/openldap apply -var run_ansible=false
```

## One Command: Destroy

```bash
terraform -chdir=terraform/openldap destroy
```

## One Command: Full E2E (Apply + Test + Destroy)

This runs Terraform apply, validates LDAP/replication via SSH, then destroys the environment.

```bash
go test ./e2e -v -run TestOpenLDAP -timeout 120m
```

Useful overrides:

- Keep the environment after tests (skip destroy):
  - `SKIP_DESTROY=1 go test ./e2e -v -run TestOpenLDAP -timeout 120m`
- Use a different SSH key or user:
  - `OPENLDAP_SSH_KEY_PATH=terraform/openldap/.local-ssh/openldap_mm OPENLDAP_SSH_USER=ec2-user go test ./e2e -v -run TestOpenLDAP -timeout 120m`
