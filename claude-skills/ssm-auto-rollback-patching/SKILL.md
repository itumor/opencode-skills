---
name: ssm-auto-rollback-patching
description: Deploy and run automated OS patching with in-place auto-rollback on EIS RHEL EC2 fleets via a custom SSM Automation runbook (snapshot all volumes → dnf update + reboot → health check → restore-in-place on failure) wired into terraform Patch Manager maintenance windows + an on-demand wrapper. Use when patching a kernel CVE across an account's infra EC2 hosts (e.g. COEXT-104202 CVE-2026-43284), building reusable scheduled patching, or porting the pattern to a new customer/account. Validated end-to-end on PTO-Reference (9 hosts).
---

# SSM auto-rollback OS patching

End-to-end pattern for patch+reboot of RHEL EC2 fleets with automatic in-place
rollback. Reference impl: `credit-agricole/terraform` MR !72 (CAA) +
`pto-reference/terraform` MR !38 (validated). Ticket COEXT-104202.

## Architecture (terraform, `lower/infra/services/patching_custom.tf`)

- `aws_ssm_document` Automation runbook `${prefix}PatchWithRollback`
  (`files/ssm/patch-with-rollback.yaml`).
- `aws_ssm_patch_baseline` + `aws_ssm_default_patch_baseline` (RHEL) — compliance
  reporting only (patching is done by dnf inside the runbook).
- 4 `aws_ssm_maintenance_window` (risk-ordered batches, nightly, serial
  `max_concurrency=1`, halt `max_errors=0`) each with one AUTOMATION task
  running the runbook against `WindowTargetIds`; `InstanceId="{{RESOURCE_ID}}"`.
- IAM: MW service role (+`ssm:StartAutomationExecution`, `iam:PassRole` cond
  `ssm.amazonaws.com`) + automation exec role (EC2 snapshot/volume/stop-start +
  Run Command).
- `scripts/patch.sh <host…>|--batch bN` for on-demand approved-night runs.

## Runbook steps (order matters)

1. `BackupVolumes` (`aws:executeScript` boto3): create a snapshot of every
   attached volume, tag `Ticket`+`Device`+`SourceVolumeId`, return Mapping +
   SnapshotIds. **Do NOT wait for completion here.**
2. `WaitForSnapshots` (`aws:waitForAwsResourceProperty`, ec2 DescribeSnapshots,
   `$.Snapshots..State` == completed, timeoutSeconds 3600).
3. `PatchInstance` (`aws:runCommand` AWS-RunShellScript): `dnf -y update`; if
   `RebootIfNeeded` and `needs-restarting -r` says so, `exit 194` (SSM-native
   reboot + idempotent re-run). onFailure → RestoreFromSnapshots.
4. `HealthCheck` (RunShellScript): running kernel ≥ MinKernel (sort -V), newest
   installed == running, no pending reboot, no failed systemd units, `docker ps`.
   onFailure → RestoreFromSnapshots. nextStep → Succeeded.
5. `RestoreFromSnapshots` (executeScript boto3): stop instance, per Mapping
   create volume from snapshot in instance AZ (carry Iops io1/io2/gp3, Throughput
   gp3), detach old (Force), attach new at same Device, start. Same instance
   id/IP/ENI. → RestoredButFailed.
6. `RestoredButFailed` (executeScript, isEnd): raise → execution Failed so the
   window/operator sees it and `max_errors=0` halts the batch.
7. `Succeeded` (aws:sleep, isEnd).

## Hard-won gotchas (all cost a failed run)

1. **No `{{ }}` ANYWHERE in embedded scripts or comments.** SSM Automation
   resolves every `{{...}}` in the document as a parameter, including inside
   RunShellScript command bodies and `#` comments → "Failed to resolve input …
   not defined". Use `docker ps` (no `--format '{{.Names}}'`). `%{…}` single
   brace (rpm --queryformat) is safe.
2. **`aws:executeScript` hard-caps at 600s** regardless of step `timeoutSeconds`.
   Never wait on a snapshot/volume waiter inside it — use a native
   `aws:waitForAwsResourceProperty` step (no cap).
3. **Patch with `dnf`, not AWS-RunPatchBaseline**, on AWS RHUI hosts:
   RunPatchBaseline (Scan and Install) fails (instance profile lacks
   patch-baseline S3 access) while `dnf` works. `subscription-manager: Disabled`
   is normal on RHUI — a red herring, not a blocker. Reboot via shell `exit 194`.
4. **Patch baseline `description` rejects `+`** and other `\p{S}` symbols
   (charset `^[\p{L}\p{Z}\p{N}\p{P}\p{M}]*$`). Use "and"; parens/hyphen OK.

## Apply + run (Atlantis-managed repos, e.g. PTO/CAA)

- Local targeted apply (admin SSO can assume the project's plan/apply role):
  `AWS_PROFILE=<profile> terraform apply -var-file=../global.tfvars
  -var 'role_session_name=<you>' -var 'command=apply' -target=aws_ssm_document.patch_rollback …`
  Use `-target` to avoid touching the rest of the services stack. Also push the
  branch + MR so Atlantis records it (plan should be a no-op afterward).
- If a manual SSM doc/role exists from earlier testing, delete it after the
  TF-managed `${prefix}PatchWithRollback` / `${prefix}patching-automation-role`
  take over (avoid duplicate resources).
- On-demand run: `start-automation-execution --document-name ${prefix}PatchWithRollback
  --parameters InstanceId=<id>,AutomationAssumeRole=<automation-role-arn>,MinKernel=<floor>,RebootOption=RebootIfNeeded`.
  Pass a low `MinKernel` floor so the health check validates "newest installed +
  rebooted" rather than a hardcoded NVR.

## Verify after patching

- Per fleet via one `AWS-RunShellScript`: `uname -r`, `dnf check-update` (rc 100=pending),
  `systemctl is-active docker` + `docker ps -q | wc -l`, `systemctl --failed | wc -l`,
  listening ports.
- Web hosts: local `curl -ks -o /dev/null -w '%{http_code}' https://localhost/`
  (200/302/308/401/403 = app up; 000 = down). Hosts with no docker.service are
  idle by design, not a failure.

## Cleanup test artifacts

Orphan detached volumes (`status=available`, tag `Ticket`) from rollback test
runs and the per-run pre-patch snapshots can be deleted once hosts verify
healthy. Add a DLM lifecycle policy on `Ticket=<ticket>` for ongoing retention.

## RHUI detection & read-only sizing (do this first)

EIS AWS RHEL hosts are almost always **RHUI** (`rpm -q rh-amazon-rhui-client`),
not RHSM/BYOS. On RHUI, `subscription-manager status: Disabled` (or "Not
registered") is NORMAL — a red herring — and `dnf` works directly. Confirm per
host and size the work read-only before committing to a window:

```
# per host via AWS-RunShellScript: RHUI? pending? download size? reboot needed?
rpm -q rh-amazon-rhui-client          # RHUI present
dnf -q check-update; echo $?          # rc 100 = updates pending
dnf -q list --upgrades | grep -c '^kernel\.'   # kernel update pending -> will reboot
dnf update --assumeno 2>/dev/null | grep -i 'Total download size'  # size, installs nothing
needs-restarting -r; echo $?          # reboot already needed?
```

Download size (often ~1 GB if months behind) × serial host count drives the
window estimate: budget ~8–11 min/host (snapshot + ~1 GB dnf + reboot + verify)
→ ~1.5–2 h for 10 hosts serial, ~3–5 min downtime per host, one host down at a
time.

## Ansible companion path (manual / emergency)

Alongside the SSM runbook, an Ansible playbook gives a controlled/emergency path
and is the only way to validate the SSM-safe reboot pattern end-to-end. Repo:
`<project>/ansible`, `playbooks/linux_kernel_patch.yaml` + `roles/local_kernel_patch`.

- **Drop `rhel_subscription` on RHUI hosts** — use `roles: [local_kernel_patch]`
  only. The CAA template playbook ships with `rhel_subscription` (RHSM); on RHUI
  it would attempt a bogus register. The PTO playbook is the correct RHUI variant.
- Role default `aws_region: "{{ ansible_aws_ssm_region | default('us-west-2') }}"`
  makes it portable across inventories (CAA sets `aws_region`, PTO only
  `ansible_aws_ssm_region`).
- Reboot is the SSM-safe pattern (async `shutdown -r +1` + `meta: reset_connection`
  + `wait_for_connection` + boot-id compare); `ansible.builtin.reboot` is
  unreliable over the `aws_ssm` connection.
- **Run via the `ansible-aws:local` docker image** (no project `docker/run.sh`
  needed): mount the ansible repo to `/work`, `-v ~/.aws:/root/.aws:ro -e
  AWS_PROFILE=<profile> -e ANSIBLE_INVENTORY_ENABLED=aws_ec2,auto,yaml,ini`
  (the image does NOT auto-enable the aws_ec2 inventory plugin; without that env
  the dir fails to parse with "Invalid host pattern 'plugin:'"). No Vault token
  needed when group_vars has no hashi_vault lookups.
  `ansible-playbook -i inventory playbooks/linux_kernel_patch.yaml --become`
  (`serial: 1` in the playbook; omit `-l` to hit the whole fleet).
- To exercise the reboot path on an already-patched host: `-e
  kernel_patch_force_reboot=true`. Verify task tolerates *pre-existing* failed
  units (diff against the pre-patch baseline) so an unrelated failed unit doesn't
  abort a healthy host.

## Editing an MR branch without disturbing a dirty working tree

These Atlantis repos are often sitting on someone else's feature branch with
uncommitted changes. Use a `git worktree add /tmp/wt-x <branch>` to edit/commit
the target branch in isolation, then `git worktree remove --force`. Don't
`checkout` the shared working tree.
