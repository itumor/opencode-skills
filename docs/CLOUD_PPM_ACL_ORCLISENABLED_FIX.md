# PPM + ACL + orclisenabled Fix — Cloud (AWS Lab)

## Overview

Two standalone scripts to fix specific issues on the AWS lab OpenLDAP
master/replica deployment. Both are idempotent — safe to run multiple times.

| Script | Fixes | Run On |
|--------|-------|--------|
| `bank-fix-ppm-acl.sh` | PPM password quality + r6 LDAPI ACL | Both servers |
| `bank-add-orclisenabled.sh` | orclisenabled custom attribute schema | Both servers |

---

## AWS Lab Environment

| Role | IP | Hostname |
|------|-----|----------|
| Master | 54.185.183.18 | ip-10-50-1-10 |
| Replica | 54.191.26.211 | ip-10-50-2-10 |

SSH key: `terraform/openldap-master-replica/.local-ssh/openldap_master_replica`
User: `ec2-user`
Admin DN: `cn=admin,dc=eab,dc=bank,dc=local`
Admin PW: `TheN1le1`

---

## Script 1: bank-fix-ppm-acl.sh

### What it fixes

1. **PPM module** (master only): Verifies `ppm.so` exists, writes `ppm.conf`
   with password quality rules, sets `pwdCheckQuality=2`. Note: Symas `ppm.so`
   lacks `.la` — full module load via `olcPPolicyCheckModule=ppm` may not work,
   but password quality is enforced via `pwdCheckQuality=2` + `ppm.conf`.

2. **r6 LDAPI ACL** (both): Verifies SASL/EXTERNAL has `manage` access to
   `cn=config`. If missing, performs offline repair (stop slapd, patch LDIF,
   restart).

### How to run on cloud lab

```bash
# ---- On MASTER ----
cd /tmp
scp -i terraform/openldap-master-replica/.local-ssh/openldap_master_replica \
  script/bank-fix-ppm-acl.sh ec2-user@54.185.183.18:/tmp/

ssh -i terraform/openldap-master-replica/.local-ssh/openldap_master_replica ec2-user@54.185.183.18
sudo bash /tmp/bank-fix-ppm-acl.sh
```

**Expected output (master):** PASS=5+, FAIL=0

```bash
# ---- On REPLICA ----
scp -i terraform/openldap-master-replica/.local-ssh/openldap_master_replica \
  script/bank-fix-ppm-acl.sh ec2-user@54.191.26.211:/tmp/

ssh -i terraform/openldap-master-replica/.local-ssh/openldap_master_replica ec2-user@54.191.26.211
sudo bash /tmp/bank-fix-ppm-acl.sh
```

**Expected output (replica):** PASS=3+, FAIL=0 (PPM skipped on replica)

### How to verify

```bash
# Check PPM config (master only)
sudo cat /opt/symas/etc/openldap/ppm.conf

# Check pwdCheckQuality (master)
sudo ldapsearch -x -ZZ -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w TheN1le1 \
  -b "cn=default,ou=Policies,dc=eab,dc=bank,dc=local" -s base pwdCheckQuality \
  -o ldif-wrap=no

# Verify LDAPI manage ACL (both servers)
sudo ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b "cn=config" -LLL '(olcDatabase=config)' olcAccess -o ldif-wrap=no \
  | grep -i manage

# Test ldapmodify via ldapi (both)
sudo ldapmodify -Y EXTERNAL -H ldapi:/// <<'EOF'
dn: cn=config
changetype: modify
replace: olcLogLevel
olcLogLevel: 0
EOF
```

---

## Script 2: bank-add-orclisenabled.sh

### What it fixes

Adds the `orclisenabled` custom attribute (OID `1.3.6.1.4.1.55555.1.16`)
to the `bank-custom` schema and includes it in the `bankUserExtension`
object class MAY list.

This is needed when master entries use `orclisenabled: TRUE` and the
replica fails with `objectClass: value #0 invalid per syntax` because
the attribute is unknown.

**Run on BOTH master and replica** — cn=config schema changes do not replicate via syncrepl.

### How to run on cloud lab

```bash
# ---- On MASTER ----
scp -i terraform/openldap-master-replica/.local-ssh/openldap_master_replica \
  script/bank-add-orclisenabled.sh ec2-user@54.186.123.12:/tmp/

ssh -i terraform/openldap-master-replica/.local-ssh/openldap_master_replica ec2-user@54.186.123.12
sudo bash /tmp/bank-add-orclisenabled.sh

# ---- On REPLICA ----
scp -i terraform/openldap-master-replica/.local-ssh/openldap_master_replica \
  script/bank-add-orclisenabled.sh ec2-user@44.243.198.216:/tmp/

ssh -i terraform/openldap-master-replica/.local-ssh/openldap_master_replica ec2-user@44.243.198.216
sudo bash /tmp/bank-add-orclisenabled.sh
```

### How to verify

```bash
# Check attribute exists in schema
sudo ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b "cn={X}bank-custom,cn=schema,cn=config" -s base \
  olcAttributeTypes olcObjectClasses -o ldif-wrap=no \
  | grep orclisenabled

# Wait for replication then check on replica
ssh -i terraform/openldap-master-replica/.local-ssh/openldap_master_replica ec2-user@54.191.26.211 \
  'sudo ldapsearch -Y EXTERNAL -H ldapi:/// -b "cn=schema,cn=config" -s sub \
   "(cn=*bank-custom*)" olcAttributeTypes -o ldif-wrap=no | grep orclisenabled'
```

---

## Quick Cloud Test: One-Command Deploy + Verify

```bash
# From repo root — deploys both scripts to lab, runs, and verifies
bash deploy-tls-lab.sh

# Then run fixes manually:
# Master:
ssh -i terraform/openldap-master-replica/.local-ssh/openldap_master_replica ec2-user@54.185.183.18 \
  'sudo bash /tmp/bank-fix-ppm-acl.sh && sudo bash /tmp/bank-add-orclisenabled.sh'

# Replica:
ssh -i terraform/openldap-master-replica/.local-ssh/openldap_master_replica ec2-user@54.191.26.211 \
  'sudo bash /tmp/bank-fix-ppm-acl.sh'
```
