# Codex Agent Instructions

- After completing any task (including read/review-only tasks), run an audible confirmation.
- Preferred command: `bash script/audio-test.sh`
- Fallback (if the script is missing or fails): `printf '\a'` and, on macOS, `afplay /System/Library/Sounds/Glass.aiff`.
- If audio cannot be played, note the reason in the response.

## Project Context

This is `nextgenopen` — Symas OpenLDAP 2.6.13 on RHEL 9, master/replica architecture. Uses satellite-managed repos.

## Key Paths

| Path | Purpose |
|------|---------|
| `script/install-symas-openldap-all-in-one.sh` | Master full installer |
| `script/install-symas-openldap-replica-all-in-one.sh` | Replica full installer |
| `script/replica/r1..r9-*.sh` | Individual replica scripts |
| `script/replica/test/test_replica_*.sh` | Replica test suite |
| `terraform/openldap-master-replica/` | AWS infra (VPC + master + replica EC2) |
| `terraform/openldap-master-replica/.local-ssh/` | SSH key |
| `docs/BANK_DEPLOYMENT.md` | Bank-specific runbook |
| `docs/BANK_RUNBOOK.md` | Generic runbook |
| `docs/REPLICA_SETUP_EMAIL.md` | Email template |

## Current Branch

`feature/replica-no-ssh` (from `feature/replica-setup`). No SSH/SCP from replica to master. Self-signed TLS default.

## Current AWS Lab (us-west-2)

Master: 54.245.18.142 / 10.30.1.10 (i-04841898308d21989)
Replica: 35.165.218.77 / 10.30.2.10 (i-0993dc2b08a5ed74f)
SSH: `ssh -i terraform/openldap-master-replica/.local-ssh/openldap_master_replica ec2-user@<IP>`
Admin: cn=admin,dc=cae,dc=local / admin
Replicator: cn=replicator,dc=cae,dc=local / replpass

## Bank Deployment IPs

Master: 172.23.11.236, Replica: 172.23.11.237, Jump: 172.23.10.32
Contact: Salama Hamdy. SSH: root. Base DN: dc=eab,dc=bank,dc=local.
