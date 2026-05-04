# Public-IP LDIFs For Terraform OpenLDAP

This folder contains **new** LDIFs (does not modify `openldap-mirrormode/ldif/`) intended to be applied over SSH to the Terraform-created OpenLDAP nodes using their **public** IPs.

Topology assumed (from `terraform/openldap/terraform.tfvars`):

- `live`: 1 master, 2 replicas
- `dr`: 1 master, 2 replicas

Public IPs + ELB/NLB DNS names (dynamic):

These values change whenever instances/LBs are replaced. Always pull them from Terraform outputs:

```bash
# From repo root. If you use the local AWS creds file:
eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"

# Instance public IPs (used for SSH-based apply)
terraform -chdir=terraform/openldap output -json instance_public_ips | jq -r 'to_entries|sort_by(.key)|.[]|"\(.key)\t\(.value)"'

# NLB DNS names
terraform -chdir=terraform/openldap output -json write_lb_dns | jq -r 'to_entries|sort_by(.key)|.[]|"write_lb_dns[\(.key)]\t\(.value)"'
terraform -chdir=terraform/openldap output -json read_lb_dns  | jq -r 'to_entries|sort_by(.key)|.[]|"read_lb_dns[\(.key)]\t\(.value)"'
```

## What These LDIFs Do

- Create/update the replication bind DN: `cn=replicator,dc=cae,dc=local`.
- Set a minimal ACL allowing the replicator DN to read.
- Set `olcServerID` values that reference **private** `ldap://IP:389` URLs.
- Ensure masters have `syncprov` loaded and the `syncprov` overlay created.
- Configure replicas as `syncrepl` consumers of their local master using the **private** master IP.
- Optionally enable **cross-VPC master-master MirrorMode** between `live-master-1` and `dr-master-1` using private IPs.

## Important Notes

- These LDIFs are meant to be applied to nodes *over SSH* using the nodes' **public** IPs, but they configure replication using the nodes' **private** IPs (so Security Groups and VPC peering work as expected).
- These LDIFs assume:
  - `BASE_DN=dc=cae,dc=local`
  - `ADMIN_DN=cn=admin,dc=cae,dc=local` with password `admin`
  - `REPL_PW=replpass`
  - `cn=module{0},cn=config` and `olcDatabase={1}mdb,cn=config`
- On these Symas OpenLDAP instances, the LDAPI socket is `/var/symas/run/ldapi`.
  - Use `ldapi://%2Fvar%2Fsymas%2Frun%2Fldapi` for EXTERNAL auth operations.
- Applying these LDIFs will override existing replication settings (it uses `replace:` for several attributes).

## How To Run

- Live cluster: see `terraform/openldap/ldif-public-ips/live/README.md`
- DR cluster: see `terraform/openldap/ldif-public-ips/dr/README.md`
- Cross-VPC master-master: see `terraform/openldap/ldif-public-ips/cross-vpc/README.md`
