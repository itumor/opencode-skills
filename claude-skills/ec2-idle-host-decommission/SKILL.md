---
name: ec2-idle-host-decommission
description: Prove an EC2 instance is unused, then decommission it safely (snapshot, terminate, Route53 cleanup, rollback record, Jira cost-change fields). Use when someone asks "do you need this EC2?", "X has been running since <date>, can we decommission?", "is anyone using this sandbox/clone/upgrade host?", flags an idle/forgotten instance, or a ticket asks to terminate a non-Terraform host. Covers read-only AWS + on-host evidence, stop-then-wait, shared-SG trap, stale DNS of sibling hosts, and savings math. Not for Terraform-managed stages (use fv-cluster-decommission).
---

# EC2 idle host decommission

Reference run: COEXT-110589 (`aws0caanexus01-upgrade-sandbox`, CAA lower 691064586749, us-west-2, 2026-09-29).

## 0. Answer the question before touching anything
- Asker usually wants a yes/no. Draft reply (caveman full, user sends it) = "not needed → ok to decommission" or "keep, reason". Don't conflate with unrelated asks (e.g. "upgrade prod Nexus?" is a separate security-driven question).
- Is it in Terraform? `grep -r <name>` across iac repos + sibling `*_custom.tf`. If TF-managed → remove via MR, not this skill.
- Region: CAA `aws0*` infra hosts live in **us-west-2**, not eu-west-3. Wrong region = "not found", not "gone".
- SSO expired ≠ no access: `aws sso login --profile <p>`, rerun.

## 1. Evidence (read-only)
```bash
bash ~/.claude/skills/ec2-idle-host-decommission/scripts/evidence.sh <ReadOnly-profile> <region> <i-id>
bash ~/.claude/skills/ec2-idle-host-decommission/scripts/onhost.sh <Admin-profile> <region> <i-id> <TICKET>   # SSM send-command needs Admin; script only reads
```
Proof of "unused" = all of:
- CPU flat <1%, no inbound traffic pattern (compare with the prod twin: prod Nexus ~100 GB/day in vs sandbox ~1 GB/day = OS updates only).
- CloudTrail: only instance-profile AssumeRole. SSM session history empty (GC'd ~30d, so weak).
- On host: `lastlog` empty, `last` shows reboots only, no established inbound, only `:22` listening, no custom cron, app container down/crash-looping.
- Not in any target group, no EIP.

Can't prove from AWS: a client still resolving the DNS name, a CI job pointing at it. Ask the team, or stop-and-wait.

## 2. Traps
- **Shared SGs.** Sandbox clones reuse the prod SGs (sandbox shared both SGs with prod `aws0caanexus01`). Never delete SGs; evidence.sh lists other ENIs.
- **DeleteOnTermination=true** → volume dies with instance. Snapshot first, always.
- **Sibling stale DNS.** Other `*-upgrade-sandbox` A records may point at IPs with no instance (`aws0caagit01-upgrade-sandbox` → 10.34.84.135, removed). Search the zone for the name pattern, prove no instance in any region/account, then delete.
- Crash-looping nginx `host not found in upstream "nexus:8081"` after reboot = compose depends_on race (see COEXT-104202 memory). Means app has been dead since last reboot, i.e. nobody noticed = unused.
- zsh: `echo =====` fails (`= not found`), which kills the rest of a `;` chain. Use `echo "---"`.

## 3. Decommission (destructive; user confirms each step)
1. Stop instance. Tell asker. Wait (hours to a week) for complaints.
2. Dry run, then apply:
```bash
bash ~/.claude/skills/ec2-idle-host-decommission/scripts/decommission.sh <Admin-profile> <region> <i-id> <TICKET>
bash ~/.claude/skills/ec2-idle-host-decommission/scripts/decommission.sh <Admin-profile> <region> <i-id> <TICKET> --apply
```
   Aborts unless state=stopped. Snapshots every volume with tags `Ticket`, `Host`, `DeleteAfter=+30d`, then terminates and deletes only A records whose single value == instance IP. Backups go to `~/.claude/decommission-backups/<TICKET>/` (instance.json, r53_*.json, snapshots.txt), **not scratch**, which is ephemeral.
3. Verify: instance `terminated`, volume gone, record gone, prod twin still `running`.
4. Follow-up: delete `DeleteAfter` snapshots after the date. Not automated, so put a date in the Jira/calendar.

## 4. Jira close-out (paste-ready; user posts)
Comment: what it was, proof of unused, what was done, rollback (snapshot IDs + DNS record), snapshot delete date.
Cost-change form fields: Resolution=Fixed · Resources Changed=Cloud resources reduced · Currency=USD · Monthly Cost Change=-<instance $/mo> · Variable Usage Cost Change=-<EBS $/mo>.
Math (us-west-2 on-demand): m6a.large ~$63/mo, m6a.xlarge ~$126/mo list price. COEXT-110589 used -70 instance / -15 EBS (150 GB gp3 ≈ $12-15). Check the current price, don't reuse the numbers.
