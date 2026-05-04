# OpenLDAP MirrorMode — VM/SSH Step‑by‑Step

This guide shows how to run the **same bootstrap + LDIF flow** used by the AWS
Terraform build, but on your own VMs over SSH. It is intentionally aligned with
`terraform/openldap/RUNBOOK.md` and `terraform/openldap/artifacts/bootstrap-ldap.sh`.

> Note: The AWS Terraform build already runs `bootstrap-ldap.sh` at instance boot.
> The steps below are for **non‑AWS** VMs or when you want to re‑run bootstrap.

---

## 1) Prep your local workstation

From the repo root, confirm the artifact paths you will copy:

- `script/`
- `openldap-mirrormode/ldif/`
- `openldap-mirrormode/scripts/`
- `terraform/openldap/artifacts/bootstrap-ldap.sh`

---

## 2) Prepare each VM

Run once on each VM:

```bash
sudo mkdir -p /opt/openldap/{bootstrap,script,ldif-src,mirrormode-scripts}
sudo chmod 755 /opt/openldap
```

---

## 3) Copy artifacts to each VM

From your workstation (repeat for each VM):

```bash
scp terraform/openldap/artifacts/bootstrap-ldap.sh root@HOST:/opt/openldap/bootstrap/
scp -r script/* root@HOST:/opt/openldap/script/
scp -r openldap-mirrormode/ldif/* root@HOST:/opt/openldap/ldif-src/
scp -r openldap-mirrormode/scripts/* root@HOST:/opt/openldap/mirrormode-scripts/
```

Then on the VM:

```bash
sudo chmod +x /opt/openldap/bootstrap/bootstrap-ldap.sh
```

---

## 4) Create per‑node config

Create `/opt/openldap/bootstrap/node.env` **on each VM** with node‑specific values.

### Example (master)

```bash
ROLE=master
VPC_NAME=live
BASE_DN=dc=cae,dc=local
ADMIN_DN=cn=admin,dc=cae,dc=local
ADMIN_PW=admin
REPL_DN=cn=replicator,dc=cae,dc=local
REPL_PW=replpass
SERVER_ID=1
PRIVATE_IP=10.10.0.10
LDAP_PORT=389
WRITE_LB_DNS=ldap-write.example.local
ORG_NAME=CAE
MASTER_IPS="10.10.0.10 10.10.0.11"
KEEPALIVED_ENABLED=true
KEEPALIVED_ROLE=MASTER
KEEPALIVED_PEER_IP=10.10.0.11
KEEPALIVED_PRIORITY=200
KEEPALIVED_AUTH_PASS=openldap
KEEPALIVED_EIP_ALLOC_ID=
```

### Example (replica)

```bash
ROLE=replica
VPC_NAME=live
BASE_DN=dc=cae,dc=local
ADMIN_DN=cn=admin,dc=cae,dc=local
ADMIN_PW=admin
REPL_DN=cn=replicator,dc=cae,dc=local
REPL_PW=replpass
SERVER_ID=101
PRIVATE_IP=10.10.0.30
LDAP_PORT=389
WRITE_LB_DNS=ldap-write.example.local
ORG_NAME=CAE
MASTER_IPS="10.10.0.10 10.10.0.11"
KEEPALIVED_ENABLED=false
```

---

## 5) Run bootstrap on each VM

```bash
cd /opt/openldap/bootstrap
set -a
source ./node.env
set +a
sudo -E ./bootstrap-ldap.sh
```

This installs OpenLDAP, applies base DIT, and configures MirrorMode replication
based on `ROLE`.

---

## 6) Run additional scripts (optional)

Your Symas/tuning scripts live in `/opt/openldap/script/`. Run them only if you
want extra configuration beyond bootstrap:

```bash
sudo bash /opt/openldap/script/install-symas-openldap-all-in-one.sh
# or
sudo bash /opt/openldap/script/install-symas-openldap-all-in-one.sh
```

---

## 7) Validate LDAP

Run from your workstation or any host that can reach the LDAP endpoint:

```bash
ldapwhoami -x -H ldap://<WRITE_ENDPOINT>:389 -D "cn=admin,dc=cae,dc=local" -w admin
ldapsearch -x -H ldap://<READ_ENDPOINT>:389 -D "cn=admin,dc=cae,dc=local" -w admin -b "dc=cae,dc=local" "(objectClass=*)"
```

---

## 8) Re‑run bootstrap (if scripts/LDIFs change)

If you update any files in `script/` or `openldap-mirrormode/ldif/`:

```bash
scp -r script/* root@HOST:/opt/openldap/script/
scp -r openldap-mirrormode/ldif/* root@HOST:/opt/openldap/ldif-src/
ssh root@HOST 'set -a; source /opt/openldap/bootstrap/node.env; set +a; sudo -E /opt/openldap/bootstrap/bootstrap-ldap.sh'
```

---

## 9) Reference

For full AWS + on‑prem mapping details, see:

- `terraform/openldap/RUNBOOK.md`
- `terraform/README.md`
