---
name: eis-vdi-workspaces
description: Use for any EIS VDI / AWS WorkSpaces work - "deploy a WorkSpace", "VDI for <team/client>", "add a VDI user", "give X sudo on the VDI", "hand VDI to Serhii/Ansible", "EIS AD login for WorkSpaces", "AD Connector or trust", "WorkSpace replaced in plan", "can't reach GitLab/Nexus from WorkSpace". Covers the EIS pattern (own Managed AD per project, eis-workspaces module, aws_ws_environment Ansible), user/password ops without printing secrets, and the traps hit on COEXT-111852.
---

# EIS VDI (AWS WorkSpaces)

Reference build: COEXT-111852, PTO Tooling 811494801456, repo `iac/projects/aws/pto-tooling/terraform` `lower/infra/services` (MRs !2..!10). Memory: `eis_vdi_workspaces_pattern`, `aws_directory_service_options_workspaces`, `coext111852_vdi_workspaces_pto_tooling`.

## Pattern (do it this way)
1. **Network first.** VPC from NetBox/Markuss, not the old sheet; check every hub TGW route table in us-west-2 + us-east-1 (memory `pnt_cidr_two_registries_drift`). Private /26 subnets in WorkSpaces AZ IDs (usw2-az1/2/3), client-template copier formula.
2. **Directory = own AWS Managed AD per project** (`aws_directory_service_directory`, MicrosoftAD Standard, ~$88/mo). Client users never go into exigengroup.com. Simple AD is closed (fails at apply).
3. **Module `eis-workspaces`** with `directory_id`, and ALWAYS `volume_encryption_key = data.aws_kms_alias.workspaces.target_key_arn` (v1.0.0 alias default = WorkSpace replaced on every plan).
4. **Users:** `bash ~/.claude/scripts/vdi-ad-user.sh --dir <d-id> --user <sam> --given .. --surname .. --email .. [--group devops] [--vault-path rnd/cicd/3.0/<proj>/workspaces/<sam>]` - password generated into Secrets Manager `aws0tool/workspaces/<sam>`, set from there, optional Vault copy (hash-checked). First SSH login can fail ~30-60 s (AD replication).
5. **WorkSpace** for a user: add to `workspaces` map AFTER the user exists.
6. **Ansible hand-off (Serhii, role `cv-devops/ansible/ansible-roles/aws_ws_environment`):** directory local admin ON, SSH 22 ingress on the WorkSpaces SG (Markuss: 10.0.0.0/8 + 192.168.0.0/16), a sudo user (`%devops` in /etc/sudoers.d/eis-devops), inventory `project_ad_domain=<SHORT>`, `devops_group=devops`. Role then removes the VDI user's sudo. Role supports one sudo group only (OC team needs `oc-team` too).
7. **E2E:** from laptop `nc -z <ip> 22`; inside WorkSpace `getent hosts` + `curl -sk -o /dev/null -w '%{http_code}'` GitLab/Nexus/Jira (403/200/401 = reachable, 000 = routing).

## Secrets (never print)
- Clipboard: `aws secretsmanager get-secret-value --secret-id <id> --profile <admin> --region us-west-2 --query SecretString --output text | pbcopy`
- SSH: `SSHPASS="$(aws secretsmanager get-secret-value ...)" sshpass -e ssh '<SHORT>\<user>'@<ip> '<cmd>'`
- Remote sudo: `printf '%s\n' "$PW" | SSHPASS="$PW" sshpass -e ssh host "sudo -S -p '' <cmd>"`
- No `<placeholders>` and no `read -rs` prompts in commands for the user.

## Traps
- `000` from WorkSpace but DNS fine = return route; a more specific hub route (another region's /23) steals it.
- Deleting a Managed AD leaves ENI + `d-*_controllers` SG ~1h -> subnet destroy DependencyViolation; delete by hand.
- VPC re-IP: teardown / core / restore as 3 MRs (consumers look up subnets by Name tag).
- Managed AD passwords expire after 42 days.
- New/recreated WorkSpace: sshd offers only publickey/gssapi. First log in via WorkSpaces client as the WorkSpace user, `sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config && sudo systemctl restart sshd` (wiki step), then SSH/Ansible works. Recreate also drops any hand-made /etc/sudoers.d files.
- Cost (real, us-west-2): RHEL PowerPro AutoStop $18.98/WorkSpace/mo + $1.52/h; Managed AD ~$88/mo; TGW attachment ~$37/mo. Every WorkSpace rebuild re-charges the monthly fee. Cost Explorer by USAGE_TYPE from the account's admin profile; note to Girts is FYI only.
- EIS-account login: get Edhar Rybak's input first. AXA JP's trust to aws.eis.cloud is Failed.
  - **Trust:** for RHEL it must be `Two-Way` + `External`. A forest trust is unsupported by SSSD, and a one-way trust does not work with WorkSpaces (AWS docs). It needs the EIS side to trust our directory (security sign-off) and RPC 49152-65535, which the EIS firewall blocks from AWS. Add one all-protocol ingress per EIS DC /32; per-port rules hit the 60-rule SG quota.
  - **AD Connector (preferred, COEXT-111852 !12):** works over AWS->EIS 53/88/389, already open. OPS supplies a non-expiring service account delegated on an OU (read users/groups, create computer objects, join), the OU DN, and the password (Vault -> SM).
  - **Module wiring for the connector:** `eis-workspaces` with an `ad_connector` input and `create_default_role = false` (role already made by the first module instance). SSH 22 goes on `data.aws_workspaces_directory.<x>.workspace_security_group_id`; each directory has its own WorkSpaces SG.
  - DC list, firewall results and probe recipe: memory `eis_ad_exigengroup_dc_facts`. Probe from the WorkSpace subnet, never the laptop.
