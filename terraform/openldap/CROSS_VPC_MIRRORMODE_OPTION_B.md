# Cross-VPC MirrorMode (Option B) Runbook

This document describes how to run and validate the **Option B** topology:

- Exactly **2 masters total**, one in each VPC (`live` and `dr`)
- Masters replicate **master-master** across VPC peering (MirrorMode-style behavior)
- All other nodes remain **read-only consumers** (replicas)

Last validated in this repo on **2026-02-08 (UTC)** via `reports/OpenLDAP_E2E_REPORT_2026-02-08.md`.

## What This Repo Uses For Option B

- Terraform provisions VPC peering, NLBs, and EC2 nodes in `terraform/openldap/`.
- OpenLDAP master-master is enabled **post-provision** via SSM (no EC2 replacement).
- Script:
  - `terraform/openldap/tools/enable_cross_vpc_mirrormode_ssm.sh`

## Prerequisites

- AWS credentials loaded (this repo uses `terraform/key.aws.text`):

```bash
eval "$(awk '/^export AWS_/ {print}' terraform/key.aws.text)"
```

- Instances must be reachable via **AWS SSM** (IAM + SSM Agent working).
- VPC peering and routing must already be in place (this Terraform stack creates it).
- Security groups must allow TCP `389` between VPC CIDRs (this stack does by default).

## Global Accelerator Endpoints

These are the **shared** Global Accelerator endpoints (2 total: read + write).

From `reports/logs/terraform_openldap_outputs_2026-02-08.json`:

- **WRITE (masters):** `ac6c679a7787ca2f4.awsglobalaccelerator.com:389`
- **READ (replicas):** `a652580c8ede8f005.awsglobalaccelerator.com:389`

If Global Accelerator is disabled, use the per-VPC NLB endpoints from the same outputs JSON:

- live write NLB: `openldap-mm-live-w-7b768a0065d56e98.elb.us-east-1.amazonaws.com:389`
- live read  NLB: `openldap-mm-live-r-566d5423cd6457d0.elb.us-east-1.amazonaws.com:389`
- dr write NLB: `openldap-mm-dr-w-82967a7df4d72e69.elb.us-east-1.amazonaws.com:389`
- dr read  NLB: `openldap-mm-dr-r-992f18f5817d1f87.elb.us-east-1.amazonaws.com:389`

## Enable Cross-VPC Master-Master (SSM)

This makes **live master** and **dr master** replicate to each other.

Command:

```bash
bash terraform/openldap/tools/enable_cross_vpc_mirrormode_ssm.sh us-east-1
```

What it does (high level):

- Discovers the `live` and `dr` masters via EC2 tags (`Role=master`, `VPC=live|dr`)
- On each master:
  - Replaces `cn=config` `olcServerID` with a 2-entry mapping so both masters are known
  - Replaces the DB `olcSyncRepl` so each master pulls from the other master

Notes:

- This script uses **SSM only**. It does not modify Terraform `user_data`, so it avoids EC2 replacement.
- Replicas remain consumers; they should continue consuming from their configured providers.

## Validate MirrorMode Behavior (Command Line)

### 1) Connectivity / Bind

```bash
WRITE_HOST=ac6c679a7787ca2f4.awsglobalaccelerator.com
READ_HOST=a652580c8ede8f005.awsglobalaccelerator.com
BASE_DN='dc=cae,dc=local'
BIND_DN="cn=admin,${BASE_DN}"
BIND_PW='admin'

ldapwhoami -x -H "ldap://${WRITE_HOST}:389" -D "${BIND_DN}" -w "${BIND_PW}"
ldapwhoami -x -H "ldap://${READ_HOST}:389"  -D "${BIND_DN}" -w "${BIND_PW}"
```

### 2) Write to WRITE endpoint, read back from READ endpoint, cleanup

```bash
WRITE_HOST=ac6c679a7787ca2f4.awsglobalaccelerator.com
READ_HOST=a652580c8ede8f005.awsglobalaccelerator.com
BASE_DN='dc=cae,dc=local'
BIND_DN="cn=admin,${BASE_DN}"
BIND_PW='admin'

TS="$(date -u +%Y%m%d%H%M%S)"
TEST_UID="studio-ga-${TS}"
DN="uid=${TEST_UID},ou=people,${BASE_DN}"

cat > /tmp/${TEST_UID}.ldif <<EOF
dn: ${DN}
objectClass: inetOrgPerson
cn: ${TEST_UID}
sn: ${TEST_UID}
uid: ${TEST_UID}
EOF

ldapadd -x -H "ldap://${WRITE_HOST}:389" -D "${BIND_DN}" -w "${BIND_PW}" -f /tmp/${TEST_UID}.ldif

# Wait briefly for replication to the read side
for i in $(seq 1 30); do
  if ldapsearch -LLL -x -H "ldap://${READ_HOST}:389" -D "${BIND_DN}" -w "${BIND_PW}" -b "${BASE_DN}" "(uid=${TEST_UID})" dn | grep -q '^dn:'; then
    echo "replicated OK"
    break
  fi
  sleep 2
done

ldapdelete -x -H "ldap://${WRITE_HOST}:389" -D "${BIND_DN}" -w "${BIND_PW}" "${DN}"
```

### 3) Verify read endpoint rejects writes (expected)

```bash
WRITE_HOST=ac6c679a7787ca2f4.awsglobalaccelerator.com
READ_HOST=a652580c8ede8f005.awsglobalaccelerator.com
BASE_DN='dc=cae,dc=local'
BIND_DN="cn=admin,${BASE_DN}"
BIND_PW='admin'

TS="$(date -u +%Y%m%d%H%M%S)"
TEST_UID="read-should-fail-${TS}"
DN="uid=${TEST_UID},ou=people,${BASE_DN}"

cat > /tmp/${TEST_UID}.ldif <<EOF
dn: ${DN}
objectClass: inetOrgPerson
cn: ${TEST_UID}
sn: ${TEST_UID}
uid: ${TEST_UID}
EOF

set +e
ldapadd -x -H "ldap://${READ_HOST}:389" -D "${BIND_DN}" -w "${BIND_PW}" -f /tmp/${TEST_UID}.ldif
echo "rc=$?"
set -e
```

## Validate Using Repo E2E

This runs SSM checks + write/read tests + cross-vpc master-master checks:

```bash
bash terraform/openldap/tools/e2e_level2_ssm.sh us-east-1
```

It will generate a report similar to:

- `reports/OpenLDAP_E2E_REPORT_2026-02-08.md`

## ApacheDirectoryStudio Setup (Global Accelerator)

Create **two** LDAP connections.

1) READ connection (searches)

- Name: `OpenLDAP-MM GA READ`
- Host: `a652580c8ede8f005.awsglobalaccelerator.com`
- Port: `389` (plain LDAP) or `636` (LDAPS)
- Encryption:
  - If using `389`: `No encryption` (or `StartTLS` if you have enabled it)
  - If using `636`: `Use SSL` (LDAPS)
- Auth: `Simple`
- Bind DN: `cn=admin,dc=cae,dc=local`
- Password: `admin`

2) WRITE connection (adds/modifies/deletes)

- Name: `OpenLDAP-MM GA WRITE`
- Host: `ac6c679a7787ca2f4.awsglobalaccelerator.com`
- Port: `389` (plain LDAP) or `636` (LDAPS)
- Encryption:
  - If using `389`: `No encryption` (or `StartTLS` if you have enabled it)
  - If using `636`: `Use SSL` (LDAPS)
- Auth: `Simple`
- Bind DN: `cn=admin,dc=cae,dc=local`
- Password: `admin`

Recommended browsing base:

- Base DN: `dc=cae,dc=local`

If using LDAPS (636):
- Import the CA cert that signed the LDAP server cert into Studio's trust store (Preferences -> Network -> SSL -> Trusted Certificates).
- Increase timeouts (Connection timeout and Read/Response timeout) to 30000ms while debugging.
- If you see `ERR_04169_RESPONSE_QUEUE_EMPTIED` / `ERR_04170_TIMEOUT_OCCURED`, treat it as connect/TLS first (not credentials). See `terraform/openldap/LDAPS_TESTING_GUIDE.md`.

## Troubleshooting

- `NXDOMAIN` for GA DNS:
  - You are likely using an **old outputs JSON**. Refresh via:
    - `cd terraform/openldap && terraform output -json > reports/logs/terraform_openldap_outputs_YYYY-MM-DD.json`
  - Current shared GA names are in `reports/logs/terraform_openldap_outputs_2026-02-08.json`.

- `Can't contact LDAP server`:
  - Check DNS resolution (`nslookup HOST`)
  - Check port reachability (`nc -vz HOST 389`)
  - Confirm NLB/GA is internet-facing (this stack uses `lb_internal=false` for GA).

- TLS/LDAPS:
  - This document is for plain LDAP on `389`.
  - For TLS, see `terraform/openldap/LDAPS_TESTING_GUIDE.md`.
