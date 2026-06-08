# OpenLDAP Master/Replica on 2 EC2 Instances

This Terraform root creates exactly two RHEL EC2 instances:

- `openldap-mr-master-1`
- `openldap-mr-replica-1`

The master is writable. The replica is configured as a read-only OpenLDAP syncrepl consumer.

Supports both **TLS** (self-signed, default) and **no-TLS** (plain LDAP) modes.

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

### With custom variables (recommended)

Create a `.tfvars` file:

```bash
cat > terraform/openldap-master-replica/my.tfvars <<'EOF'
vpc_cidr             = "10.50.0.0/16"
base_dn              = "dc=eab,dc=bank,dc=local"
org_name             = "EAB"
admin_password       = "TheN1le1"
replication_password = "replpass"
instance_type        = "t3.medium"
project_name         = "openldap-mytag"
EOF
```

```bash
cd terraform/openldap-master-replica
terraform init
terraform plan -var-file=my.tfvars
terraform apply -var-file=my.tfvars
```

### Quick deploy (defaults)

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

## 4. Bootstrap Notes

Instances run `scripts/bootstrap-userdata.sh.tpl` on first boot (cloud-init `user_data`):

1. Creates 2G swap **first** (avoids OOM kills on small instances)
2. Installs Symas OpenLDAP packages + openssl
3. Configures `/etc/profile.d/symas_env.sh` (PATH + LDAPCONF)
4. Installs SSM Agent (for remote management)
5. Opens firewall ports 389 + 636

Check bootstrap completion:
```bash
ssh -i .local-ssh/openldap_master_replica ec2-user@<IP> \
  "grep 'Bootstrap complete' /var/log/openldap-bootstrap.log"
```

## 5. Run Install Scripts

### Master (with or without TLS)

```bash
# Copy scripts
scp -i .local-ssh/openldap_master_replica -r ../../script ec2-user@<MASTER_IP>:/tmp/script

# Run with TLS (default)
ssh -i .local-ssh/openldap_master_replica ec2-user@<MASTER_IP> \
  "sudo bash /tmp/script/install-symas-openldap-all-in-one.sh 2>&1" | tee master-install.log

# Run without TLS
ssh -i .local-ssh/openldap_master_replica ec2-user@<MASTER_IP> \
  "sudo TLS_MODE=no ADMIN_PW=<pw> bash /tmp/script/install-symas-openldap-all-in-one.sh 2>&1" | tee master-install.log
```

### Replica (with or without TLS)

```bash
# Copy scripts
scp -i .local-ssh/openldap_master_replica -r ../../script ec2-user@<REPLICA_IP>:/tmp/script

# Run with TLS (default)
ssh -i .local-ssh/openldap_master_replica ec2-user@<REPLICA_IP> \
  "sudo MASTER_IP=<MASTER_PRIVATE_IP> ADMIN_PW=<pw> REPL_PW=replpass \
   bash /tmp/script/install-symas-openldap-replica-all-in-one.sh 2>&1" | tee replica-install.log

# Run without TLS
ssh -i .local-ssh/openldap_master_replica ec2-user@<REPLICA_IP> \
  "sudo MASTER_IP=<MASTER_PRIVATE_IP> ADMIN_PW=<pw> REPL_PW=replpass TLS_MODE=no \
   bash /tmp/script/install-symas-openldap-replica-all-in-one.sh 2>&1" | tee replica-install.log
```

> **No SSH/SCP from replica to master is needed.** The replica uses self-signed certs by default (`COPY_FROM_MASTER=0`). For no-TLS mode (`TLS_MODE=no`), no certs are generated at all.

## 6. TLS / No-TLS Modes

| Mode | `TLS_MODE` | TLS Certs | Syncrepl | Bind Hardening |
|------|-----------|-----------|----------|---------------|
| TLS (default) | `yes` (or unset) | Self-signed generated | `starttls=yes` | `simple_bind=128` |
| No-TLS | `no` | None | Plain LDAP | Anon disabled only |

When `TLS_MODE=no`:
- Master skips `24-configure-ssl-tls.sh` and runs hardening without TLS enforcement
- Replica skips `r5-configure-replica-tls.sh` and runs hardening without TLS enforcement
- Syncrepl uses plain `ldap://` (no `starttls=yes`)

## 7. Verify

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

## 8. Useful Outputs

```bash
terraform output
terraform output -raw master_public_ip
terraform output -raw replica_public_ip
```

## 9. Current Deployments

### No-TLS Lab (us-west-2)

| Role | Public IP | Private IP | Instance ID |
|------|-----------|------------|-------------|
| Master | `54.185.183.18` | `10.50.1.10` | `i-0693bef1c65ce8825` |
| Replica | `54.191.26.211` | `10.50.2.10` | `i-0dabec022a85f6ecd` |

Admin: `cn=admin,dc=eab,dc=bank,dc=local` / `TheN1le1`
Replicator: `cn=replicator,dc=eab,dc=bank,dc=local` / `replpass`

Deployed with: `terraform apply -var-file=no-tls.tfvars`, then `TLS_MODE=no` scripts.

## 10. Destroy

```bash
cd terraform/openldap-master-replica
terraform destroy -var-file=my.tfvars
```

## Notes

- Default region: `us-west-2`.
- Default base DN: `dc=cae,dc=local`.
- Default admin DN: `cn=admin,dc=cae,dc=local`.
- For production-like use, pass strong passwords with `TF_VAR_admin_password` and `TF_VAR_replication_password` from the environment.
- Use `t3.medium` or larger to avoid OOM during bootstrap (the swap-first fix helps on `t3.micro` too).
