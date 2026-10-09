---
name: eis-nexus-docker-compose-upgrade
description: Runbook + kit to upgrade a Sonatype Nexus running as docker compose on an EIS EC2 host (aws0<code>nexus01, role cv-devops docker_compose_nexus) to a new 3.x version, with OS dnf update + reboot, for ANY client. Use when a ticket says "Nexus security update / update to 3.9x+", "Sonatype Nexus Upgrade <client> <quarter>", "patch Nexus", or a client must adopt docker_compose_nexus v2.x. Ships IID-guarded SSM scripts (backup, OS, verify, restore), clone/E2E/post-task playbooks and a group_vars example. Covers recon, upgrade path, role v2 default traps, isolated clone dry-run, backup/restore drills, dnf docker-upgrade outage trap, MW execution, E2E proof. Reference: COEXT-106742 (CAA 3.91.1 -> 3.96.4, done 2026-10-02, MR !17).
---

# Nexus (docker compose) upgrade: runbook

Proven end to end on COEXT-106742: CAA `aws0caanexus01`, 3.91.1 -> **3.96.4**, done 2026-10-02 with ~24 min downtime and zero data loss. The evidence is in `~/.claude/change-runs/COEXT-106742.md`, and the backup/restore plan in `COEXT-106742-backup-restore.md`.

**Kit:** `kit/` next to this file. It holds scripts, playbooks and examples, so copy it rather than rewriting:
```
kit/kit.env.example            per-client IIDs, FQDN, profile  -> ~/.claude/change-runs/<TICKET>/kit.env
kit/ssm.sh <env> <clone|prod> <script>   runs common.sh + script on target via SSM
kit/common.sh                  IID + FQDN guard (clone must resolve FQDN to 127.0.0.1; prod must be PROD_IID)
kit/mw_backup.sh               B1 pg_dump (writes stopped) + TOC check + sha256, B3 /opt tarball, stop stack
kit/mw_os.sh                   dnf -y update (refuses if stack running), records boot_id
kit/mw_postboot.sh             G2: new boot_id, waits for docker
kit/mw_verify.sh               G3: writable, ports, version, repo count, nginx loop count
kit/mw_restore_r1.sh           R1: /opt from B3 + dropdb/pg_restore B1 + compose up
kit/playbooks/clone.yaml       role run on the clone only (pre_task refuses unless FQDN -> 127.0.0.1)
kit/playbooks/e2e.yaml         15 authenticated probes; run BEFORE (baseline) and AFTER, then compare
kit/playbooks/post.yaml        creates + runs "Rebuild repository search" via API; docker layer pull via :5000 + digest check
kit/playbooks/wait.yaml        waits for the rebuild task; summarises Nexus ERROR/WARN since the upgrade
kit/playbooks/e2e-vars.example.yml   per-client repo names, image, LDAP user
kit/group_vars.nexus.yaml.example    CAA overrides (start here, adapt to the live inventory)
```
Put the playbooks in the client ansible repo root, but git-exclude them (`.git/info/exclude`); they are not for the MR. Run them with `-e @e2e-vars.yml`.

## Gates and roles
- User-gated: MW approval (ask in Slack in the client's style; CAA = "hey @Roman Terletskyy Can I proceed...? MW first or proceed now?"), MR merge, Jira/Slack posts.
- The agent does: recon, the clone (free hand, **never delete the clone unless asked**), drills, MR, and the prod MW after an explicit "go".
- `Disruption: OUTAGE ~20-30 min — window: yes` on every apply handoff.

## Phase 1: Recon (read-only SSM on prod)
- `docker ps` tags (nexus/nginx/postgres). Compose file: `/opt/docker_compose_nexus/docker-compose.yaml` ("Ansible managed" = an old role version).
- Datastore: `NEXUS_DATASTORE_NEXUS_JDBCURL` = postgres container.
- Blob stores: `select name,type,attributes from blob_store_configuration` (redact keys). For S3, check the bucket policy, versioning, lifecycle, and the CloudWatch size/object count. CAA: 1.5 TB / 3.5M objects, versioning Suspended, lifecycle `expire_soft_deleted_objects` (tag `deleted=true`, 3 days) = **3-day undo window** for blobs.
- Inventory to diff against role defaults: `repository` (name, recipe, blobStoreName, writePolicy, httpPort, remoteUrl, members), `role`, `cleanup_policy`, `ldap_configuration`, `anonymous_configuration`.
- Postgres pw: is `POSTGRES_PASSWORD == b64(hostname)`? Print yes/no only.
- OS: release, kernel, uptime, pending dnf count, dnf-automatic (CAA: disabled).
- Mirror has the images: `docker manifest inspect cvops-reg01.eisgroup.com:5000/sonatype/nexus3:<ver>-ubi` on the host.
- Is the role pinned in the client's `roles/requirements.yml`? (CAA: the playbook existed, but no pin and no group_vars.)

## Phase 2: Version
- Release notes: help.sonatype.com/en/nexus-repository-2026-release-notes.html. Paths: .../nexus-repository-upgrade-paths.html. 3.91 -> 3.96 is direct; Java 21 from 3.87. Pick the latest patch (3.96.4 on 09-30).
- Skip 3.94.x (NEXUS-54717). 3.92+ = SSRF protection: private upstreams break without an allowlist.

## Phase 3: Role v2.x overrides (`inventory/group_vars/nexus.yaml`, see kit example)
v2 reconciles everything on every run, and its defaults describe a FRESH install:

| Default | On an existing host | Override |
|---|---|---|
| `postgres_enabled: false` | empty H2 DB | `true` |
| `postgres_version: 16.11` | minor downgrade | live tag (`"16"`) |
| `licensed: false` | Pro license dropped | `true` |
| `aws_s3_bucket ""`, `blob_storage` = bucket | wrong blob store | `blob_storage: <live>` + full `nexus_s3_blobstore` incl. prefix (validates, never repoints) |
| `nexus_repositories` model | clashing repos, :5000 clash, ALLOW->ALLOW_ONCE | `[]` |
| `nexus_repositories_to_delete` | deletes maven-*/nuget-* | `[]` |
| `nexus_roles`, `nexus_cleanup_policies` | role/policy drift | `[]` |
| LDAPS :636 + Vault CA | AD login may break | `nexus_ldap_protocol: <live>` |
| meta deps | conflict with older client pins | `skip_dependencies: true` (TLS in /opt/ssl) |

Keep `nexus_ssrf_protection.allowed_domains` = every private upstream host. Playbook `hosts: all` -> `hosts: nexus`. Expected role diff on an existing host: image tags, nginx 1.31 (TLS ciphers, upstream rename), nexus.properties -> env/JVM opts, `depends_on: service_healthy`, migrate profile dropped.

## Phase 4: Isolated clone
1. `create-image --no-reboot` of prod. `run-instances`: same subnet/SGs, an **IAM profile with zero rights on the nexus bucket** (CAA: `aws0caagrok01-Role` = SSM + ansible bucket), `Name=<host>-upgrade-sandbox`, `Stage=sandbox`, no `Acronym` tag.
2. **Pin the prod FQDN to 127.0.0.1 on the clone.** The role's uri calls `https://<nodename>` from the target; without the pin the clone reconfigures PROD. cloud-init bootcmd failed silently, so pin via SSM and verify with `getent`. Also `hostnamectl set-hostname <prod fqdn>` (pg pw = b64(nodename)) + `/etc/cloud/cloud.cfg.d/99-*.cfg` `preserve_hostname: true`.
3. Isolation proof: the clone UI shows the S3 blob store **Failed** (expected).
4. Runner `ansible-aws:local` (`docker/run.sh`; tarball `~/gitwork/iac-artifacts/ansible-aws.tar.gz`): install the FULL `roles/requirements.yml`; `ansible-galaxy collection install 'community.docker:>=4,<5' -p /work/.collections`; **`export ANSIBLE_COLLECTIONS_PATH=...` inside `exec`** (a `VAR=x a && b` prefix applies to `a` only). Clone playbook `vars_files` must include the prod stage group vars (CAA `infra.yaml`: `project_zone`).
5. `--check --diff` (it fails at the uri tasks; expected), real run, pg_dump config-table diff (expected: only the `http.forwarded` capability added).
6. User test from the Mac (sudo, the user runs it): `/etc/hosts` line tagged `# <TICKET> clone`; remove it afterwards. While it exists, every tool on the Mac hits the clone.

## Phase 5: Backup + restore (drill ALL on the clone before prod)
| | What | Time (CAA) |
|---|---|---|
| B1 | `pg_dump -Fc` with nexus+nginx stopped, `pg_restore -l` TOC > 50 tables, sha256 | 466 MB, ~40 s |
| B3 | tar /opt/{docker_compose_nexus,nginx,ssl} | 101 MB |
| B2 | `ec2 create-snapshots --instance-specification` with the stack stopped | API instant |
| R0 | re-run role / restart nginx | 2-5 min |
| R1 | `mw_restore_r1.sh` (cross-version 3.96.4 -> 3.91.1 proven) | 217 s |
| R2 | `create-replace-root-volume-task --snapshot-id <B2>` (keeps IID/IP). The snapshot must come from a past root volume of THIS instance, else use `--image-id`. Stack-stopped B2 -> `docker compose up -d` | swap ~2 min, healthy < 7 min |
| R3 | new instance from AMI + new IP + R53 A record | 30-45 min |
Timebox: G3 not green by T+60 -> R1 (OS fine) else R2.

## Phase 6: dnf trap
`dnf -y update` upgrades docker-ce/containerd and restarts the engine. Nexus gets SIGTERM (143) and is NOT restarted; after a reboot it stays down (dockerd restores only running containers) and nginx loops on `host not found`. Hence: **stop the stack BEFORE dnf**, and let the role bring it up after the reboot.

Note: this kit patches the OS with its own `mw_os.sh` (plain `dnf -y update`), NOT the client repo's `playbooks/linux_kernel_patch.yaml` (COEXT-104202 pattern with preflight, EBS snapshots, SSM-safe reboot, kernel post-validation). That playbook is unsafe to run on a live Nexus stack for the same docker-restart reason. If a reviewer asks whether it ran, the answer for CAA (2026-10-02) is no; state that and the equivalent (own snapshot B2 + manual kernel/boot check).

## Phase 7: MW (prod), CAA actual timings
1. `kit/playbooks/e2e.yaml` baseline (all 200 expected; record the blob count/bytes).
2. `ssm.sh kit.env prod mw_backup.sh` (downtime starts) — 59 s
3. B2 snapshot — record the id
4. `ssm.sh … prod mw_os.sh` — 224 s
5. reboot (`shutdown -r +0` via SSM), then poll `mw_postboot.sh` — ~1 min
6. `ansible-playbook playbooks/nexus.yaml --limit <host> --become --diff` from the MR commit — 466 s, `changed=4`
7. `mw_verify.sh` + `e2e.yaml` again: compare with the baseline (same blob count + bytes, LDAP user found, proxies 200, fresh asset download 200)
8. `post.yaml`: rebuild-search task (POST `/service/rest/v1/tasks`, type `repository.rebuild-index`, `repositoryName: "*"`, then `/run` -> 204); docker layer pull through :5000 with a sha256 digest match
9. `wait.yaml`: the rebuild finishes; check the ERROR/WARN summary
10. The user merges the MR after G3; Jira close text (user posts)

## Gotchas hit
- `docker exec` without `-i` passes no stdin -> an empty dump copy. Always verify the TOC count before any drop.
- `set -e` + `c=$(curl …)` in a wait loop dies on curl exit 35 while nginx starts: `|| true`.
- Jinja: `.json.items` is the dict METHOD; use `.json['items']`.
- The Nexus blobstores API has no `available` field; use `blobCount`/`totalSizeInBytes`.
- A docker manifest may be an index: follow `manifests[]` (amd64) to the child, then `layers[0]`.
- POST `/tasks/{id}/run` while the task is running -> HTTP 500 (harmless).
- `uri` with `dest` + an existing file -> 304. Delete the file first for a real read.
- boto3 inside the runner says "SSO expired" while the host CLI works (cached role creds) -> `aws sso login`. Check `~/.aws/sso/cache` `expiresAt` before the MW (need >= 2 h).
- System check `Default Secret Encryption Key` was pre-existing on CAA; not caused by the upgrade.
- replace-root-volume keeps the replaced root (`DeleteReplacedRootVolume=False`) -> orphaned 150 GB volumes. After the drills, list `describe-volumes --filters Name=status,Values=available` and delete them once snapshots cover them.
- `create-snapshots --copy-tags-from-source volume` copies nothing when the source volume is untagged (a replaced root) -> the snapshot has no `Ticket` tag; tag it by hand so cleanup finds it.
- Cleanup: schedule a one-time read-only reminder task (`scheduled-tasks`, fireAt = DeleteAfter + 1 day) that re-checks prod health and hands back deregister-AMI -> delete-snapshots -> rm host files. Never auto-delete.
- Worklog: the harness R12 hook denies Jira POST; the user posts it (or the jira-routine ledger). Use `started` with `-0700`, and don't exceed 8 h/day.
