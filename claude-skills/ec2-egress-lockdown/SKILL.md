---
name: ec2-egress-lockdown
description: Use when a security/CyberArk team asks to restrict an EIS EC2 host's outbound traffic ("build server must only reach Jenkins/git/nexus", "bastion reaches things it shouldn't", "isolate the host from prod data"), when a connectivity test (nc) from a host proves it can reach hosts it must not, or when enabling eis-ec2 restrict_egress anywhere. Covers the no-NAT-VPC trap, the /32-vs-subnet decision, interface-endpoint prerequisites, the two-MR no-op gate, and the SSM verification battery. Reference: COEXT-105998, aws0caatestbld01, 2026-08-07.
---

# EC2 Egress Lockdown (eis-ec2 restrict_egress)

## Overview

Convert an EIS EC2 host from allow-all outbound to deny-by-default + explicit allow-list,
without breaking builds, logins, EDR, or SSM. First fleet use: CAA UAT build host
(COEXT-105998, MRs !116/!117 in credit-agricole/terraform; ADR
`docs/terraform/custom/build-host-egress-restriction.md` in that repo).

**Core principle: recon the live host BEFORE writing a single rule.** Every outage this
skill prevents was found by looking at what the host actually talks to, not what the
repo says it should.

## Direction sanity check (before anything)

A `nc` test FROM host A TO host B measures **B's inbound** + A's outbound. With
allow-all egress (the eis-ec2 default), "A can reach B" only proves B's ingress is
open. Don't let a stakeholder's connectivity test be framed as "A has agreed access" —
and don't promise "closing A's inbound" fixes it. SG rules are allow-only and stateful.

## Phase 1 — Live recon (SSM, read-only)

Resolve every real dependency before designing:

| Check | Command (via `aws ssm send-command`) | Decides |
|---|---|---|
| Package repos | `dnf repolist -v` (RHUI vs RHSM baseurls) | what break-glass must restore |
| AD DCs | `getent ahostsv4 exigengroup.com` | 389/tcp /32 list (SSSD ldap ⇒ NO Kerberos ports) |
| Live connections | `ss -tn state established` | surprises — this is how Wazuh was found |
| EDR | `grep -A4 '<server>' /var/ossec/etc/ossec.conf` | Wazuh manager IP:port (CAA: 10.23.12.173:53/tcp!) |
| Docker registry | `/root/.docker/config.json` auths | registry /32 + port |
| vault-agent | `systemctl status vault-agent` | skip rule if disabled (bld hosts: disabled) |
| NTP | `chronyc sources` | must be 169.254.169.123 (link-local, SG-exempt) |
| resolv.conf | `cat /etc/resolv.conf` | must be VPC resolver (SG-exempt) |

Also resolve toolchain host IPs via `aws ec2 describe-instances --filters Name=tag:Name...`.

## Phase 2 — Design rules

- **No-NAT/no-IGW VPC ⇒ SG is the ONLY enforcement point.** Everything non-local rides
  the TGW; you cannot express "internet-except-X". Therefore **never add 0.0.0.0/0** —
  it would re-open the very cross-VPC path you're closing (any RFC1918 host ⊂ 0.0.0.0/0).
- **/32s, not subnets, when a forbidden host shares the subnet** with allowed ones
  (CAA: ta01 shares 10.34.84.0/22 with git/nexus/sonar). Hardcode /32s in locals with a
  maintenance comment. Do NOT use `data.aws_instance` by Name tag: DescribeInstances
  returns terminated twins ~1h after a host rebuild → "multiple instances matched" →
  every plan in that state hard-fails on shared Atlantis.
- **eis-ec2 v2.3.0+ only** (v2.2.2 hardcodes all-all; additive SGs can't subtract).
  `restrict_egress = true` with all three egress vars EMPTY passes validation and
  creates ZERO egress rules on module.sg — a clean all-all killer. `sg_admin` has no
  egress rules in any version.
- **Don't use the module's `egress_custom_rules`/`egress_cidr_blocks`**: one shared CIDR
  list cross-products every port with every destination (~70% spurious grants).
- **Whole policy in one `<host>_custom.tf`**: dedicated `aws_security_group` + one
  `aws_vpc_security_group_egress_rule` per destination×port (described, reviewable),
  attached via `extra_security_group_ids`. SG ids can't transit `var.ec2_settings`
  (static defaults) — wire with `locals { ec2_extra_sgs = { <key> = [sg.id] } }` and
  `extra_security_group_ids = lookup(local.ec2_extra_sgs, each.key, [])` in ec2.tf.
- **S3 needs a prefix-list rule** (`data.aws_prefix_list` com.amazonaws.<region>.s3):
  gateway-endpoint traffic targets public S3 IPs, not the VPC CIDR. Covers SSM agent
  updates, ansible bucket, ECR layer blobs.
- **Interface endpoints prerequisite** (separate core-state change, apply FIRST):
  `kms sts eks ecr.api ecr.dkr secretsmanager logs` (~$14.60/mo each at 2 AZs). ECR
  auth does NOT call STS (IMDS-signed); `eks get-token` signs locally; `update-kubeconfig`
  needs the eks endpoint. Legacy SDKs hitting global `sts.amazonaws.com` hang — note
  `AWS_STS_REGIONAL_ENDPOINTS=regional`.
- SG-exempt (never need rules): VPC DNS, Amazon Time Sync, IMDS (all link-local).
- Jenkins-agent hosts: controller connects IN over SSH; no outbound-to-Jenkins rule.

## Phase 3 — Ship as two MRs

1. **MR A: module bump only** (v2.2.2→v2.3.0). Gate: Atlantis plan must show ZERO
   `module.ec2[*]` changes (restrict_egress default false renders identical literals).
   Isolates version-churn risk from behavior change — if churn appears you know which.
2. **MR B (stacked): endpoints (core) + egress SG + `restrict_egress=true` (services).**
   Expected plan shape: core +N endpoints; services +1 SG +rules, instance
   "updated in-place" (SG membership), module egress-all rule destroyed. NO replacement.
   Ordered apply: core → services (endpoints must exist before egress closes).

Rebase before every apply — a stale branch plans REVERTS of colleagues' merged+applied
work (shows as deletions of resources you never touched; check `git log ..origin/main`).

## Phase 4 — Verification battery (SSM)

- **Replicate the security team's exact test** (same FQDN, same ports) — must now time
  out. `timeout 7 nc -zv <host> <port>; echo exit=$?` → `exit=124` + only the Ncat
  version banner = blocked. "Connected to" = still open.
- Negative: internet (8.8.8.8:443), another VPC → blocked.
- Positive: git (443+ssh-port), nexus (443+5000), registry, sonar, `aws sts/eks/
  secretsmanager/ecr` calls, `kubectl get nodes`, AD `getent passwd <user>`,
  `systemctl is-active wazuh-agent`, S3.
- **kubectl trap**: SSM runs as root with no kubeconfig → `localhost:8080 connection
  refused` is NOT a network failure. Test with
  `KUBECONFIG=/tmp/kc aws eks update-kubeconfig ... && kubectl get nodes`.
- **S3 AccessDenied = network OK** (request reached S3, IAM said no) — don't misread.

## Known breaks (document, don't fight)

| Breaks | Handling |
|---|---|
| RHUI/RHSM patching, EPEL, pip, tool downloads | break-glass: short-lived MR flipping `restrict_egress=false` for the patch window; long-term = Nexus rpm/pypi proxy |
| `docker pull` docker.io / public.ecr.aws | pull through project Nexus :5000 instead; unqualified pulls HANG (no clear error) |
| rhsmcertd background noise | known-benign connection-failure logs |

## Phase 5 — Close-out comms (two audiences, drafts only — user sends)

- **Engineer/Jira version**: what changed + verification evidence + operational notes
  (break-glass, docker-via-nexus, /32 maintenance rule).
- **Network-security version**: zero Terraform vocabulary. Two tables — CLOSED
  (direction/port/was-open-to) and OPEN NOW (inbound table + outbound table with
  destination/port/purpose). End with "net effect" one-liner. Anticipate their two
  questions: DNS/NTP (link-local, bypasses SG filtering) and SSH return traffic
  (SGs are stateful).
- **Evidence format that lands**: replicate the stakeholder's own test verbatim
  (same FQDN, same ports) and show before/after — `Ncat: Connected to X` vs
  `exit=124 timeout`. Their test, inverted, is the most persuasive artifact.

## Common mistakes

| Mistake | Reality |
|---|---|
| "Allow 443 to 0.0.0.0/0 for AWS APIs" | Re-opens every internal host on 443; use interface endpoints |
| Subnet-wide toolchain rule | Forbidden host shares the subnet — the whole point dies |
| Skipping recon, writing rules from repo docs | Wazuh-on-port-53 and GitLab-SSH-on-2224 only visible live |
| One MR for bump + behavior | Can't attribute plan churn; no no-op gate |
| Trusting `0 to destroy` | Read the change lines; and re-plan after ANY main merge |
