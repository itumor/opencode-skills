---
name: cyberark-eis-install
description: Use when provisioning, installing, patching, or troubleshooting CyberArk PAM components (SIA, PSM, PSMP) in EIS SaaS environments — "CyberArk implementation for <client> env" tickets, SIA/PSM VM provisioning, PSMP connector install, openssh/PSMP auth failures ("failed to connect to all addresses", session drops), Ansible-over-CyberArk transfer failures, or onboarding databases/software into CyberArk.
---

# CyberArk install & ops in EIS environments

## What it is
EIS uses **CyberArk Privilege Cloud (SaaS)** — tenant `cyberark.cloud.34242`, vault `vault-eisgroup.privilegecloud.cyberark.cloud`. PAM for stage/prod access: JIT access, session recording, ephemeral users. Per-account (client) footprint = **2 connector VMs in the `infra` zone**:

| Component | Role | OS | Size (AWS) | Disk | ~Cost |
|-----------|------|----|------------|------|-------|
| **SIA** (`cyberarksia01`) | DB read access w/ ephemeral users; PSMP SSH proxy | RHEL 9 | t3a.medium | 50 GB | $36/mo |
| **PSM** (`cyberarkpsm01`) | Admin access gateways: database / ssh / browser (RDP-based) | Windows Server 2025 | t3a.2xlarge | 100 GB | $359/mo |

(Specs per Denys Zvenyhorodskyi, COEXT-105281.) Network: SIA/PSM sit in infra, need egress 443 to CyberArk SaaS + ssh/443/db-port reach into stage/prod/cicd.

Host naming: `<site><client>infra[cyberark]sia01` — live examples: `aws0plwbinfrasia02.aws0.plwb.cloud` (AWS precedent), `az03aaebinfracyberarksia01.az03.aaeb.cloud`, `az05ageainfracyberarksia01`. The infix varies per client — **confirm the exact hostnames with the CyberArk team in the ticket before provisioning**; the table specs are defaults, the ticket comment is authoritative. Note: "for <env> UAT" tickets still place the VMs in **infra** — the env name only scopes which stage the connectors must reach (CAA UAT = test-stage targets `aws0caatest*`).

## New-environment workflow (e.g. CAA UAT = COEXT-105281)
1. **Read ticket comments** — CyberArk team (Denys Zvenyhorodskyi, Vadym Chernetskyi, Volodymyr Glushchak) posts exact VM requests there.
2. **Provision the 2 VMs** in the client terraform repo (`projects/aws/<client>/terraform`) with the `eis-ec2` module. Placement = the **infra (shared-services) stage** (`lower/infra/services`), NOT the target stage — connectors reach into stage VPCs via TGW (arch: COEXT-101187; precedent `aws0plwbinfrasia02`). Atlantis MR flow. **Reference implementation (production-live 2026-06-12, CAA MR !74 merged): credit-agricole/terraform `lower/infra/services/` — ec2 map entries + `ec2_settings` CUSTOM blocks + `cyberark_custom.tf` (PSM secret only) + ADR `docs/terraform/custom/cyberark-infra-vms.md`.**
   - Use the **fleet `var.ec2` map pattern** (team preference, matches all other infra EC2s): `cyberarksia01 = {}` / `cyberarkpsm01 = {}` in the `ec2` map (terraform.tfvars) + `cyberarksia`/`cyberarkpsm` entries in `ec2_settings` (variables.tf), both inside `BEGIN/END CUSTOM` marker blocks (template-owned files).
   - **Pin eis-ec2 ≥ v2.2.2.** v2.1.1 fixed Windows AMI platform detection (AWS returns `platform` lowercase; pre-fix Windows got ssh SG not RDP); v2.2.0 added `admin_ingress_rules` (`null`=auto, `[]`=SSM-only); v2.2.1/v2.2.2 fixed root_block_device for ec2-instance v6 (pre-fix ALL disk settings silently ignored → AMI-default unencrypted roots) with encryption opt-in. **Scrutinize the bump plan for `encrypted = false -> true # forces replacement` on LIVE fleet instances before apply** — partial root_block_device overrides historically lost the encryption flag.
   - SIA settings: `instance_type t3a.medium`, `root_block_device { volume_size = 50, volume_type = "gp3", encrypted = true }`, `admin_ingress_rules = []` (SSM-only; re-enable `["ssh-tcp"]` when PSMP goes live). RHEL 9 AMI = module default.
   - PSM settings: `t3a.2xlarge`, `root_block_device { volume_size = 100, ... encrypted = true }`, `ami_id = "<pinned Windows_Server-2025-English-Full-Base id>"` (data lookups impossible in variables — pin and update manually; us-west-2 2026-06: ami-02df557e4e9e6c1ea), `ignore_ami_changes = true`. Platform auto-detect → rdp-tcp+rdp-udp from `administrative` PL.
   - **No `Backup` tag** — connectors are stateless; rebuild path = remove from CyberArk → rebuild → re-onboard (COEXT-104333).
   - Post-apply: VERIFY volumes (`aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=<id>`) — don't trust plan's "known after apply".
3. **Credentials — keyless, SSM-first (no SSH key pairs by policy):**
   - SIA needs NO standing creds and NO secret: SSM Session Manager shell, `ssm-user` has sudo (every eis-ec2 instance has `AmazonSSMManagedInstanceCore`).
   - PSM `Administrator` password: set post-boot via SSM PowerShell (`net user Administrator '<pw>'`), store in the ONE TF-created empty Secrets Manager shell (`<prefix>cyberarkpsm01/credentials`) with `put-secret-value` — values never in TF state, Atlantis plan role needs no `GetSecretValue`. RDP needs this password even over an SSM tunnel (SSM doesn't bypass Windows auth). Hand the SM path in a ticket comment, never plaintext.
   - Connection guide (all live-tested): SIA `aws ssm start-session --target <id>`; PSM RDP = SSM port-forward (`AWS-StartPortForwardingSession portNumber=3389,localPortNumber=13389` → RDP localhost:13389) or direct 3389 from administrative networks. Headless/non-TTY shells: wrap in `script -q /dev/null aws ssm start-session ...`.
4. **Network verification before handover:** tenant portal 443 (`eisgroup.cyberark.cloud`, `eisgroup.privilegecloud.cyberark.cloud`) must be OPEN from the SIA; **vault port 1858 will time out until the CyberArk team registers the account's NAT egress IP** (get it: `curl ifconfig.me` from the SIA) — include the IP in the handover comment. `cyberark.cloud` apex gives cert errors (not a service endpoint) and `www.` doesn't resolve — don't test those.
5. CyberArk team installs PSMP/connectors and onboards hosts into Privilege Cloud.
6. **Verify**: SSH chain login works end-to-end (format below); session recorded.
7. **Pin openssh** on the SIA host (see gotcha #1) so patching doesn't break PSMP.

## Access chain format (SSH through SIA/PSMP)
```
ssh <user>@cyberark.cloud.34242@<target-user>@<target-fqdn>@<sia-fqdn>
# e.g. vchernetskyi@cyberark.cloud.34242@cyberark-sudo@az03aaebstagesisense01.stage.az03.aaeb.cloud@az03aaebinfracyberarksia01.az03.aaeb.cloud
```
MFA = email link/code at password prompt.

## PSMP install/upgrade (on SIA, RHEL 9)
```bash
cd /opt/psmp-install-<ver>           # e.g. 14.1.5.4
rpm -Uvh ./IntegratedMode/CARKpsmp-infra-<ver>.x86_64.rpm   # infra first
rpm -Uvh CARKpsmp-<ver>.x86_64.rpm                          # then main (configures SELinux)
```
Healthy log line: `PSMPPS035I PSM SSH Proxy [...] is up and working with Vault [...]`.

## Gotchas (all hit in production)
1. **OpenSSH ≥9.9 breaks PSMP on RHEL 9** (CyberArk KI00026176; COEXT-105077). Symptom: `Invalid user`, pam_psmp `Get entity server details returned error [Error: failed to connect to all addresses]`, instant session drop. Fix: downgrade openssh to 8.7 (`dnf downgrade openssh-server`) and **versionlock it** — fleet kernel patching (`dnf update`) will re-break it otherwise.
2. **Ansible over PSMP: `copy` module unreliable** (COEXT-103434, open). sftp + scp transfer mechanisms fail; piped sometimes works but can fail checksum (`Copied file does not match the expected checksum`). Workaround: fetch artifacts on target via URL, or use the dedicated psmp connector (COEXT-105077) and expect transfer issues.
3. **GUI/RDP on RHEL SIA needs xrdp + smbd** — install per wiki "Remote GUI on RHEL based on xrdp Cyberark SIA" (page 872196211); needs 445/tcp inbound to the SIA host.
4. **SIA VM rebuild order** (COEXT-104333): remove host from CyberArk first → rebuild VM → re-onboard → test. Don't rebuild while still onboarded. The openssh pin (gotcha #1) is mandatory on every fresh/rebuilt SIA. PSMP is only validated on RHEL 9 in EIS — newer RHEL = check CyberArk support matrix first.
5. **PSM/PSMP security patching** is a per-client chore driven by CyberArk bulletins (CA26-xx); upgrade = same rpm -Uvh pair on SIA, PSM patched separately on Windows.

## DB onboarding pattern (COEXT-104540 template)
- DB roles to pre-create: `cyberark_stage_admin`, `cyberark_prod_admin`, `database_administrator`, `database_operator`.
- AD groups `psql_<client>-<env>_r` (request via `[~jira.cvsupport]` in ticket; for new AD groups generally → EISHELP Access Request, OPS team).
- Configure SIA read policy (permanent: DevOps/CICD groups; temporary: app teams), strong accounts in SIA with approval policy, 2 privileged accounts in PSM (browser + DB manager), migrate static DB users → ephemeral.

## References
- Wiki (CoreVelocity space): `CyberArk` root page id **779979207**; `Azure CyberArk Architecture` id **859906663**; xrdp GUI id **872196211**. (wiki.eisgroup.com — Jira PAT does NOT authenticate here.)
- Key Jira: COEXT-101187 (architecture master), COEXT-86653 (Ageas PAM reference impl), COEXT-105281 (CAA UAT — mine), COEXT-104763 (CAA UAT env parent), COEXT-105077 (PSMP/openssh), COEXT-103434 (ansible copy), COEXT-104540 (DB onboarding), COEXT-103325 (xrdp).
- Jira sweep: `text ~ "CyberArk"` ≈ 700 issues, mostly access requests; filter with `AND issuetype in ("Action Item", "Action Item sub-task", Task)` for implementation work.
