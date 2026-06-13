---
name: waf-staged-public-alb-isolation
description: Use when deploying WAFv2 customer/tenant isolation on an EIS public ALB (eis-waf module) with a staged narrow-SG → WAF → open-L3 rollout — e.g. GENESIS-428120 AFA isolation on FV demo (aws0fvdemoeks01). Covers MR-chain review, consolidating MRs, cross-stack core→services apply, the eis-alb SG prefix-list replacement failure, live WAF testing, and merge.
---

# Staged WAFv2 customer-isolation on a public ALB

End-state = **defense-in-depth**: ALB SG narrow at L3 **and** WAFv2 Web ACL (default_action=block) at L7. Roll out in gates so a WAF misconfig never coincides with an open L3.

Reference deploy: GENESIS-428120, FV demo, `aws0fvdemoeks01`, profile `fv`, account `207414098330`, `us-west-2`. FV = **manual apply** (no Atlantis), double var-file. See [[eis_waf_module]], [[eis_alb_arn_output_versions]], [[eis_alb_sg_prefixlist_replace_and_waf_test]], [[tf_local_module_download_ssh_rewrite]].

## The staged sequence (do NOT collapse the gate)

1. **core**: create the `<tenant>` managed prefix list (the tenant egress IPs).
2. **services**: SG → `[administrative, <tenant>]` (still narrow) + deploy WAFv2 (`eis-waf`, default block).
3. **Verify the WAF live** while L3 is still narrow (see test recipe below).
4. **services**: SG → `["all"]` (L3 = 0.0.0.0/0; WAF carries all L7) — only after step 3 passes.

One MR cannot preserve gate 3↔4 (steps 2 and 4 edit the same `alb_public_allowed_prefix_lists` line). Two valid shapes:
- **Defense-in-depth MR**: combine steps 1+2 (narrow SG + WAF), keep `["all"]` a separate follow-up.
- **Stacked MRs**: open-L3 MR targets the WAF-MR branch (clean diff `[admin,tenant]→[all]`); GitLab auto-retargets to main only if the parent's source branch is **deleted** on merge — else retarget manually (`glab mr update <n> --target-branch main`).

## Cross-stack apply ordering (mandatory)

`eis-alb` resolves SG names via a **live `data "aws_ec2_managed_prefix_list"` lookup by name** (`alb_eks_public/main.tf`). So the core prefix list MUST exist in AWS before `services` can even `plan`. Order is always **core → services**.

## eis-alb SG prefix-list replacement failure (expect it)

Changing `alb_public_allowed_prefix_lists` replaces the 80/443 `aws_security_group_rule.ingress_rules[*]` (`prefix_list_ids` forces replacement). The module uses `create_before_destroy`.

- **Superset change** (`[admin]`→`[admin,tenant]`): create-new re-authorizes `admin` while old rule still holds it → `InvalidPermission.Duplicate: ... peer: pl-..., from port 443 ... already exists`. First `apply` half-finishes (WAF resources made; SG rules + **association NOT made**).
  - **Recovery (worked):** re-run apply — a targeted `terraform apply -target=module.eis_waf` pulls in `module.alb_eks_public` as a dep and replaces the SG rules cleanly + creates the association. Then full `plan` = No changes.
- **Disjoint change** (`[admin,tenant]`→`[all]`): no overlap → CBD succeeds first try.

After any partial apply, check: is `aws_wafv2_web_acl_association` in state? If absent, the WAF exists but is **inert** (not attached).

## Live WAF test (while SG narrow OR after open)

Narrow SG blocks your host at L3, so temp-allow your /32, then `curl --resolve` to control Host/SNI:

```bash
MYIP=$(curl -s https://checkip.amazonaws.com); ALB_IP=$(dig +short <alb-dns> | grep '^[0-9]' | head -1)
aws ec2 authorize-security-group-ingress --group-id <alb-sg> \
  --ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$MYIP/32,Description=TEMP}]
# unknown IP, any host  -> 403 (default block)
curl -sk -o /dev/null -w '%{http_code}\n' --resolve h.<domain>:443:$ALB_IP https://h.<domain>/
# tenant host + non-tenant IP -> 403 (host match alone insufficient)
# allow-path proof: add /32 to the relevant WAF IP set (aws wafv2 update-ip-set, needs LockToken), curl -> non-403 (e.g. 404 backend), then REVERT the set
aws ec2 revoke-security-group-ingress --group-id <alb-sg> --security-group-rule-ids <sgr-id>
```
`update-ip-set` bumps `lock_token` → next `plan` shows 1 benign in-place change (addresses are a Set, unchanged). After opening L3, retest from your real internet IP (no temp rule): unknown → still 403 = WAF enforcing.

## Quick reference

| Item | Value |
|------|-------|
| Module pin | `eis-waf v1.0.3` (has `hosts=[]` IP-only rule); `eis-alb v1.0.3` for `output "arn"` on AWS ~>5 stacks |
| WAF rules | tenant allow (host ENDS_WITH + IP set), corp IP-only allow (`10/8`,`192.168/16`, any host), managed groups `Common`+`KnownBadInputs` **count-only**, per-IP rate 2000/5min, default **block** |
| Apply | `export AWS_PROFILE=fv AWS_SDK_LOAD_CONFIG=1`; `-var-file=../terraform.tfvars.json -var-file=terraform.tfvars.json` |
| Module fetch | no `GITLAB_TOKEN` → temp `GIT_CONFIG_GLOBAL` https→ssh (see [[tf_local_module_download_ssh_rewrite]]) |

## Common mistakes

- Opening L3 (`["all"]`) before verifying the WAF live — defeats the gate.
- Forgetting core→services order → `services plan` errors `no managed prefix list found`.
- Treating the `InvalidPermission.Duplicate` as a config bug — it's CBD ordering; re-apply fixes.
- Leaving managed rule groups in `count` mode and assuming they block — they only observe until flipped to `block`.
- Bumping eis-alb to v1.0.3 on an AWS ~>6 stack (eis-iac) — its `~> 5.0` constraint conflicts; use v2.0.1+ there.

## Verify / rollback

- Verify: `aws wafv2 get-web-acl-for-resource --resource-arn <alb-arn>` (Name + DefaultAction=Block); rule list `aws wafv2 get-web-acl`; full `terraform plan` = No changes; live curl 403.
- Rollback: re-narrow SG (revert `["all"]` → `[administrative,<tenant>]`) — reversible. Disassociate WAF by removing `alb_arns`/module if needed.
