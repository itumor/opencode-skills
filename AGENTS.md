# Codex Agent Instructions

- After any task (including read-only), run audible confirmation.
- Preferred: `bash script/audio-test.sh`
- Fallback: `printf '\a'` + macOS `afplay /System/Library/Sounds/Glass.aiff`
- If audio fails, note why.

## Project Context

nextgenopen = Symas OpenLDAP 2.6.13 on RHEL 9, master/replica. Satellite-managed repos.

## Key Paths

| Path | Purpose |
|------|---------|
| `script/install-symas-openldap-all-in-one.sh` | Master installer |
| `script/install-symas-openldap-replica-all-in-one.sh` | Replica installer |
| `script/replica/r1..r9-*.sh` | Replica scripts |
| `script/replica/test/test_replica_*.sh` | Replica tests |
| `terraform/openldap-master-replica/` | AWS infra (VPC + EC2) |
| `terraform/openldap-master-replica/.local-ssh/` | SSH key |
| `deploy-tls-lab.sh` | Full TLS deploy + verify (one-command) |
| `docs/BANK_DEPLOYMENT.md` | Bank runbook |
| `docs/BANK_RUNBOOK.md` | Generic runbook |
| `docs/REPLICA_SETUP_EMAIL.md` | Email template |

## Pre-Merge Verification Rule

**Before any merge or after any change to `script/` files**, run the full deploy to verify nothing broke:

```bash
bash deploy-tls-lab.sh
```

This clean-installs master+replica on the AWS lab, tests TLS binds, and verifies replication. If it fails, the change is not safe to merge. Takes ~5-7 minutes.

## Branch

`feature/replica-no-ssh` (from `feature/replica-setup`). No SSH/SCP replica→master. Self-signed TLS default.

## AWS Lab (us-west-2)

### Current: TLS Deployment (2026-06-08)

Master: 54.186.123.12 / 10.30.1.10 (i-07105527154403a7f)
Replica: 44.243.198.216 / 10.30.2.10 (i-0c6b02568872b0bdc)
VPC: 10.30.0.0/16, project: openldap-mr
SSH: `ssh -i terraform/openldap-master-replica/.local-ssh/openldap_master_replica ec2-user@<IP>`
Admin: cn=admin,dc=eab,dc=bank,dc=local / TheN1le1
Replicator: cn=replicator,dc=eab,dc=bank,dc=local / replpass
Mode: TLS (TLS_MODE=yes). Master: t3.medium, Replica: t3.medium.
CA cert: `/tmp/master-ca.crt` (extracted from master via ssh+sudo cat)

### Previous: TLS Lab (2026-05-25 — terminated)

Master: 54.245.18.142 / 10.30.1.10 (i-04841898308d21989)
Replica: 35.165.218.77 / 10.30.2.10 (i-0993dc2b08a5ed74f)
Admin: cn=admin,dc=cae,dc=local / admin
Mode: Self-signed TLS

## Bank Deployment

Master: 172.23.11.236, Replica: 172.23.11.237, Jump: 172.23.10.32
Contact: Salama Hamdy. SSH: root. Base DN: dc=eab,dc=bank,dc=local.

## Admin-Provisioned Access (Bank — user `ebrahim`)

Paths + permissions on master + replica:

| Path | Mode | Type | Notes |
|------|------|------|-------|
| `/opt/symas/bin/` | rx | dir | No write — pkg-managed |
| `/opt/symas/etc/openldap/slapd.d/` | rw | dir | Created |
| `/opt/symas/etc/openldap/schema/` | rw | dir | Config dir |
| `/opt/symas/etc/openldap/tls/` | rw | dir | Created |
| `/var/symas/openldap-data/example/` | rw | dir | Created |
| `/tmp/script/` | rwx | dir | Created |
| `/tmp/script/replica/` | rwx | dir | Created |
| `/opt/symas/sbin/slapd` | rx | file | Ignored (non-existent) |
| `/opt/symas/etc/openldap/slapd.conf` | rw | file | Created |
| `/opt/symas/etc/openldap/ldap.conf` | rw | file | Created |
| `/usr/lib/systemd/system/symas-openldap-servers.service` | r | file | Admin-managed |
| `/opt/symas/etc/openldap/sysmas_env.sh` | rw | file | Wrong path! Not `/etc/profile.d/` |
| `/etc/yum.repos.d/symas.repo` | r | file | Admin-managed (not `soldap-release26.repo`) |
| `/var/symas/run/ldapi` | 777 | socket | Pre-existed |

### Gaps

- `symas_env.sh` at `/opt/symas/etc/openldap/sysmas_env.sh` (typo'd dir) — NOT `/etc/profile.d/symas_env.sh`. Scripts sourcing `/etc/profile.d/symas_env.sh` fail silently. Fallback: set PATH + LDAPCONF explicitly.
- Yum repo at `/etc/yum.repos.d/symas.repo` (not `soldap-release26.repo` as scripts expect).
- `r2-configure-replica-instance.sh` requires root (line 26). Needs `slappasswd` + `slaptest` at `/opt/symas/sbin/`. If Symas packages missing → script fails.
- Symas ships `.ldif` schemas, not `.schema`. r2 detects this, creates `/tmp/replica-needs-schema-load` marker for post-load.
- Binaries dir `rx` only — cannot `ldapadd` new schema files from there; write elsewhere.

## Bank Troubleshooting Session (2026-06-07)

### Critical Learnings

1. **ldapsearch wraps lines at ~76 chars by default** — always use `-o ldif-wrap=no` when parsing output, or `tr -d '\n'` to join wrapped lines. This caused `refreshAndPersist` → `refreshAndPersi` truncation in fix-replica.sh.

2. **Replica needs ppolicy module loaded** — without it, syncrepl fails with `objectClass: value #0 invalid per syntax` on pwdPolicy objects from master. Added to replica orchestrator + bank-fix-all.sh.

3. **Empty replica DB causes syncrepl refreshDelete loop** — syncrepl sends refreshDelete, connection detaches, retries forever. Fix: seed replica with `ldapsearch` from master → `slapadd` before enabling syncrepl. Added as Step 7 in bank-fix-all.sh replica section.

4. **Replicator password can be reset via Python SSHA** — no slappasswd needed. Use `hashlib.sha1` + `os.urandom(8)` + base64. Built into bank-fix-all.sh.

5. **find_service() needs pgrep fallback** — `systemctl list-units | grep` may fail in some environments. Added `pgrep -x slapd` fallback to fix-master.sh, fix-replica.sh, bank-fix-all.sh.

6. **Master MUST have syncprov overlay** — without it, syncrepl never streams changes. Added to bank-fix-all.sh master section.

7. **Master MUST have entryUUID/entryCSN indices** — without them, syncrepl can't track entries. Added to fix-master.sh + bank-fix-all.sh.

8. **Replica ACL missing = admin can't read data** — slapadd doesn't set olcAccess. bank-fix-all.sh now adds `to * by * read` if missing.

9. **TLS certs in cn=config may be stale** — use `replace` not `add` for olcTLSCertificateFile/KeyFile/CACertificateFile to avoid constraint violation on olcTLSProtocolMin.

10. **`slapd -Tt` validates config without starting** — safe way to check config integrity.

### Fix Scripts Summary

| Script | Use |
|--------|-----|
| `bank-fix-all.sh` | **RECOMMENDED** — single script, detects master/replica, applies all fixes + seeds empty replica + verifies |
| `fix-master.sh` | Standalone master fix (checksums + indices) |
| `fix-replica.sh` | Standalone replica fix (syncrepl TLS + ppolicy + TLS certs) |
| `verify-master.sh` | 16-point health check |
| `verify-replica.sh` | 17-point sync verification |
| `BANK_FIX_GUIDE.md` | Customer-facing deployment guide |
| `BANK_FIX_EMAIL.md` | Email template for Salama |

### Zip package
`/tmp/openldap-bank-fix.zip` — contains all scripts + guide. Send to bank.

### Bank Environment Quick Reference
- No `slappasswd` availability → use Python SSHA
- `ldapmodify` may be at `/opt/symas/bin/` only → always set PATH first
- Reboot cycle: `systemctl restart symas-openldap-servers` + wait 15s
- Force sync: restart replica slapd + check contextCSN
- Seed replica: `ldapsearch` from master → stop replica → wipe mdb → `slapadd` → start replica
- Hardening toggle: delete `olcSecurity: simple_bind=128` from cn=config via ldapi
