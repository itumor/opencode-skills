---
name: ansible-fleet-kernel-patch
description: Patch a RHEL/RHUI EC2 fleet kernel CVE via the local_kernel_patch Ansible role (snapshot → dnf update → SSM-safe reboot → verify), executed in human-gated waves. Use for kernel CVE remediation MWs when the SSM auto-rollback runbook is not yet deployed (or as a complement to it). Validated end-to-end on CAA 12-host fleet for CVE-2026-43284 (COEXT-104202) on 2026-06-16.
---

# Ansible-driven fleet kernel patch

End-to-end pattern for patch+reboot of a RHEL/RHUI EC2 fleet, one host at a
time, with EBS-snapshot rollback. Distinct from the SSM-doc pattern in
[[ssm-auto-rollback-patching]] — this one is operator-driven via Ansible and
needs no Terraform apply.

## When to use this vs ssm-auto-rollback-patching

- Use **this** when: the SSM doc isn't deployed in the target account yet,
  OR the MW is one-off and adding TF is overkill, OR you want operator control
  per wave.
- Use **ssm-auto-rollback-patching** when: recurring MWs are wired into
  Terraform Patch Manager windows and you want hands-off auto-rollback.

## Architecture

- **Role**: `roles/local_kernel_patch` in any project's ansible dir.
  - `tasks/main.yml` orchestrates: preflight → snapshot → patch → reboot → verify.
  - `defaults/main.yml`: `kernel_patch_min_kernel`, `kernel_patch_snapshot=true`,
    `kernel_patch_update=true`, `kernel_patch_reboot_grace=150`,
    `kernel_patch_reboot_timeout=900`.
  - `tasks/snapshot.yml`: tags each EBS snap with `Ticket`+`Host`+`Purpose`+device.
  - `tasks/patch.yml`: `dnf state=latest update_only=true` over the whole package
    set + check `needs-restarting -r`, set `kernel_patch_needs_reboot`.
  - `tasks/reboot.yml`: SSM-safe pattern — `shutdown -r +1 &` async, then
    `meta: reset_connection`, `wait_for_connection`, confirm new `boot_id`.
  - `tasks/verify.yml`: kernel >= min via `sort -V`, no pending reboot, no NEW
    failed units (diff against pre-patch baseline), docker count back.
- **Playbook**: `playbooks/linux_kernel_patch.yaml` — `hosts: all`, `serial: 1`,
  `roles: [rhel_subscription, local_kernel_patch]` (drop `rhel_subscription` on
  RHUI-only fleets that don't use RHSM; it works fine on dual-config CAA hosts).
- **Runner**: `./docker/run.sh` wrapper around the `ansible-aws:local` Docker
  image (see [[ansible-docker-runner-macos]]).

## Pre-MW checklist (day before, zero downtime)

1. **EBS snapshots** every host:
   ```bash
   aws ec2 create-snapshots \
     --instance-specification "InstanceId=$ID,ExcludeBootVolume=false" \
     --description "<TICKET> pre-patch <NAME> <YYYYMMDD>" \
     --tag-specifications "ResourceType=snapshot,Tags=[
       {Key=Ticket,Value=<TICKET>},
       {Key=Host,Value=<NAME>},
       {Key=Purpose,Value=pre-kernel-patch}]" \
     --copy-tags-from-source volume     # NOT volume_tags
   ```
2. **Pre-cache RPM**:
   ```bash
   ansible all --become -m shell -a \
     "dnf install --downloadonly -y kernel-<NVR>"
   ```
3. **Sandbox dry-run** with full reboot on an upgrade-sandbox host
   (`aws0caanexus01-upgrade-sandbox` for CAA).
4. **JIRA worklog** logged for MW day. Use `started: <MW-day>T20:00:00.000+0300`
   — Jira -0700 will see it on the correct day (earlier UTC times slip into
   the previous day in Jira UI). See [[eis-jira-rest-ops]].
5. **Confirm SSM `Online`** on all in-scope hosts.

## MW execution

```bash
cd <repo>/ansible
git checkout feature/<TICKET>-kernel-patch
# Refresh VAULT_TOKEN — it expired since prep day
source .env   # contains VAULT_ADDR, VAULT_TOKEN, ANSIBLE_HASHI_VAULT_URL, AWS_PROFILE

# Wave 0 — sandbox (validate reboot path)
./docker/run.sh playbook playbooks/linux_kernel_patch.yaml \
  --limit aws0caanexus01-upgrade-sandbox --become

# Wave 1 — low-risk
./docker/run.sh playbook playbooks/linux_kernel_patch.yaml \
  --limit "<low_risk_csv>" --become

# Wave 2 — build/CI
./docker/run.sh playbook playbooks/linux_kernel_patch.yaml \
  --limit "<build_csv>" --become

# Wave 3 — critical (one host at a time, human gate)
./docker/run.sh playbook playbooks/linux_kernel_patch.yaml \
  --limit aws0caajnk01 --become
./docker/run.sh playbook playbooks/linux_kernel_patch.yaml \
  --limit aws0caaatlantis01 --become
./docker/run.sh playbook playbooks/linux_kernel_patch.yaml \
  --limit aws0caakeycloak01 --become
```

## Live progress (since `serial:1` buffers in piped output)

While ansible runs, probe each host via SSM RunCommand from another shell:
```bash
for HOST in <wave-hosts>; do
  ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$HOST" \
       --query 'Reservations[].Instances[].InstanceId' --output text)
  CMD=$(aws ssm send-command --instance-ids $ID --document-name AWS-RunShellScript \
        --parameters 'commands=["uname -r"]' --query 'Command.CommandId' --output text)
  sleep 1
  echo "$HOST: $(aws ssm get-command-invocation --command-id $CMD --instance-id $ID \
                 --query 'StandardOutputContent' --output text)"
done
```
Hosts already on the new kernel = done. Hosts on the old kernel = still in queue or in flight.

## Post-MW verification

1. **Kernel sweep** across the fleet (table form, target >= min).
2. **Service URL probe** via FQDN from one in-VPC host (cross-host probe via
   atlantis01 works well — single SSM RunCommand iterating curls):
   ```bash
   for u in <URLS>; do
     printf '%-50s ' "$u"
     curl -k -s -o /dev/null -w 'HTTP=%{http_code} TIME=%{time_total}s\n' \
       --max-time 10 https://$u/
   done
   ```
3. **Per-host post-checks** already done by the role (boot_id, kernel,
   failed-units diff, docker count). Trust the PLAY RECAP `ok=28 failed=0`.

## Traps observed in CAA fleet (COEXT-104202)

- **VAULT_TOKEN expires** between prep day and MW. Refresh at MW start, save
  back to `.env`.
- **`-e kernel_patch_update=false` is ignored** — string "false" evaluates
  truthy in `when:`. Don't rely on partial-run flags without `| bool` casting.
- **`dnf state=latest` installs newer-than-pinned kernel** when RHUI offers
  one. Verify uses `>=` so it passes. Document this in the MR.
- **Wide blast radius from `dnf update *`** — updates glibc + everything, not
  just kernel. Acceptable for CVE remediation scope, but tell the customer.
- **Playbook stops on first failure mid-wave** (`serial:1` + default
  `any_errors_fatal`). Remaining hosts NOT processed. Retry the rest solo.
- **macOS Ansible "worker dead state"** intermittent. Retry the failing host
  alone; recovers.
- **Docker-compose service-order race** (e.g. nexus-nginx → nexus-app): nginx
  starts before app, DNS lookup for upstream fails, restart loop. Manually
  restart the dependent container after the upstream healthchecks. Durable
  fix: `depends_on: { app: { condition: service_healthy } }`.
- **Mid-MW host additions** (other tickets termed/recreated 2 instances
  overnight in COEXT-104202). Snapshot + pre-cache on-the-fly works.

## Rollback (if a host doesn't come back)

```bash
# 1. Stop instance
aws ec2 stop-instances --instance-ids <ID>
# 2. Get the pre-patch snapshot
SNAP=$(aws ec2 describe-snapshots --owner-ids self \
       --filters "Name=tag:Host,Values=<HOST>" "Name=tag:Ticket,Values=<TICKET>" \
       --query 'Snapshots[0].SnapshotId' --output text)
# 3. Create volume from snap (same AZ), detach broken volume, attach restored
#    at the same device name, start instance.
```

## Reference

- CAA execution: COEXT-104202 (CVE-2026-43284 "Dirty Frag"), 12 hosts on
  2026-06-16, MR !11 merged. See [[coext104202-mw-execution-lessons]].
- Related: [[ssm-auto-rollback-patching]] (TF/SSM-doc alternative);
  [[ansible-docker-runner-macos]] (the runner); [[eis-jira-rest-ops]]
  (worklog/transition); [[ansible-aws-ssm-reboot-pattern]] (SSM-safe reboot
  internals).
