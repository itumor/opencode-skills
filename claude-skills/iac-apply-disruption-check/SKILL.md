---
name: iac-apply-disruption-check
description: >-
  Use BEFORE handing back any `atlantis apply` / terraform apply / `aws ... update-*` for the user to run,
  and whenever asked "will this cause downtime?", "do we need a maintenance window?", "is it safe to apply
  now?". Classifies the change as NONE / BLIP / OUTAGE from evidence (AWS dry-run or docs + plan symbols +
  topology), states whether a window is needed, and gives the paste-ready window note. Covers OpenSearch
  (volume vs engine upgrade), SG-rule replacement, EKS node groups, RDS. Reference: COEXT-108169 (CAA UAT
  OpenSearch 2.17 -> 3.7, 2026-10-01).
---

# Disruption check before every apply

Rule: every apply handoff carries one line, **before** the `atlantis apply` command:

`Disruption: NONE | BLIP | OUTAGE — <why, with the evidence> — window: yes/no`

- **NONE** — applied dynamically/in-place, nothing restarts, no endpoint or target change.
- **BLIP** — seconds to minutes of higher latency, rejected requests, or a UI (Dashboards) unavailable; clients with retries recover. Window for prod/customer-facing; announce for UAT/test.
- **OUTAGE** — traffic or service stops (replaced ingress rule, reboot/failover, stateful replace). Window + customer comms.

**Never say "no downtime" from memory.** Cite command output or the AWS doc line. A wrong "blue/green" is as bad as a wrong "no downtime" (2026-10-01: I said an EBS grow was blue/green; AWS dry run said `DynamicUpdate`).

## Procedure
1. **Read the plan symbols.** `~` in-place, `-/+` replace (destroy then create = gap unless `create_before_destroy`), `+/-`, `-`. In-place does NOT mean safe: ask what the service does under the hood.
2. **Ask the service for the answer** (below). If it has a dry-run, run it (non-mutating).
3. **Multiply by topology.** Single node, no replicas, no Multi-AZ/standby, one target in a TG, one NAT => any blue/green or restart is felt. Multi-AZ with standby/replicas => usually absorbed.
4. **Label** NONE/BLIP/OUTAGE, decide the window, state it. For BLIP/OUTAGE also say the rollback (often none).
5. **After apply** verify the disruption actually ended (`Processing=false`, health green, metric back) — see the service's section.

## OpenSearch (AWS-managed) — verified 2026-10-01
Authoritative check for config changes (non-mutating; pass the CURRENT values for the rest of the block):
```bash
aws opensearch update-domain-config --domain-name <d> --ebs-options EBSEnabled=true,VolumeType=gp3,VolumeSize=60,Iops=3000,Throughput=125 \
  --dry-run --dry-run-mode Verbose --profile <admin> --region <r>
# DryRunResults.DeploymentType = DynamicUpdate (no blue/green) | Blue/Green | Undetermined | None
```
Watch/verify: `aws opensearch describe-domain-change-progress --domain-name <d>` (stages: "Applying volume related changes" = dynamic; "Provisioning new nodes / Copying shards" = blue/green) and `describe-domain` (`Processing`, `UpgradeProcessing`).

| Change | Class | Evidence |
|---|---|---|
| EBS size **increase**, gp3 IOPS/throughput increase | **NONE** (DynamicUpdate) | live dry run + apply on aws0caatestos01: 3 min, no restart, FreeStorageSpace 3.6 -> 35.8 GB |
| access policy, TLS policy, custom endpoint, tags, snapshot hour, HTTPS flag | NONE (usually) | AWS "Making configuration changes" doc |
| data node / UltraWarm node count | NONE (usually) | same doc |
| **Engine version upgrade** | **BLIP** (Blue/Green; Dashboards may be unavailable for part or all of it) | same doc; no dry-run exists for upgrades — use `upgrade-domain --perform-check-only` for eligibility only |
| service software update, instance type, dedicated master on/off, enable UltraWarm/cold, subnets/SG add-remove, advanced options, FGAC/encryption enable, audit logs enable | BLIP (Blue/Green) | same doc |
| volume **shrink**, volume type change, **second** EBS change within 6 h of the last or while one runs | BLIP (Blue/Green) | same doc — space EBS edits >= 6 h apart |

Single data node + no replicas (CAA UAT `aws0caatestos01`): AWS says search/index stay available during blue/green, but expect higher latency, some rejected requests and an endpoint cutover. State BLIP, schedule a quiet window, tell users of Dashboards (SAML login).
Version upgrades: 3.x reachable only from 2.19 (`get-compatible-versions`), so 2.17 -> 3.7 = two hops = two disruptions. No downgrade; AWS pre-upgrade snapshot is the only rollback (Support). Use `perform-check-only` + `get-upgrade-history` first; compare before/after state.

## Other recurring cases (from memory notes — confirm in the plan before relying)
- **SG rule / ingress path `-/+`** without create_before_destroy => **OUTAGE**. Live 2026-09-24 (CAA stage): ALB->node rule replaced, ALB answered 504 while targets stayed "healthy". Fix: in-place/CBD, or apply with a temp allow rule first ([[alb_healthy_targets_504_nodeport_window]]).
- **EKS node group** version/AMI/launch template/`force_*_upgrade` => rolling node replacement (**BLIP** per pod; PDBs can stall with PodEvictionFailure) ([[eks_nodegroup_podeviction_failure]]).
- **RDS** instance class / engine / static parameter change (`apply_method=pending-reboot`) => reboot or failover (**BLIP** Multi-AZ, **OUTAGE** single-AZ); `apply_immediately=false` defers to the maintenance window ([[rds_parameter_apply_method_convergence]], skill `eis-rds-postgres-extension`).
- Any stateful `-/+` (RDS, S3 with data, EFS, OpenSearch domain) => data-loss class, not just downtime. Stop and escalate.

## Window note template (user posts; caveman full)
```
Window request <ENV>: <resource> <change>.
Disruption: <BLIP|OUTAGE> — <what users see>. Duration ~<x>.
When: <date/time, low traffic>. Rollback: <none | steps>.
Verify after: <cmds>.
```
