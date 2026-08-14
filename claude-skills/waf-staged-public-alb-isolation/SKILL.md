---
name: waf-staged-public-alb-isolation
description: Use when deploying WAFv2 customer/tenant isolation on EIS public ingress (eis-waf module) — either a staged narrow-SG → WAF → open-L3 rollout on a public ALB (GENESIS-428120, FV demo aws0fvdemoeks01) or the internet-NLB → internal-ALB variant used when the public subnets are /28 (COEXT-106502, AXA Japan aws0axajpdeveks01). Covers MR-chain review, consolidating MRs, cross-stack core→services apply, the eis-alb SG prefix-list replacement failure, the eis-waf first-plan association trap, IGW exposure gate, exact-host vs namespace-suffix host rules, rate-rule NAT blocking, live WAF testing, and merge.
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
| Module pin | `eis-waf v1.0.4` (v1.0.3+ has `hosts=[]` IP-only rule; v1.0.4 assoc trap — see variant); `eis-alb v1.0.3` for `output "arn"` on AWS ~>5 stacks |
| WAF rules | tenant allow (host ENDS_WITH + IP set), corp IP-only allow (`10/8`,`192.168/16`, any host), managed groups `Common`+`KnownBadInputs` **count-only**, per-IP rate 2000/5min, default **block** |
| Apply | `export AWS_PROFILE=fv AWS_SDK_LOAD_CONFIG=1`; `-var-file=../terraform.tfvars.json -var-file=terraform.tfvars.json` |
| Module fetch | no `GITLAB_TOKEN` → temp `GIT_CONFIG_GLOBAL` https→ssh (see [[tf_local_module_download_ssh_rewrite]]) |

## Variant: internet NLB → internal ALB (public subnets too small for an ALB)

Reference: COEXT-106502 / EISSAASDEV-302, AXA Japan, `aws0axajpdeveks01`, profile `axajp`, account `586117079971`. Atlantis-driven, not manual apply.

Reach for this when the env's public subnets are `/28` (EIS `eis-vpc` default) — an ALB needs `≥/27` with 8 free IPs, an NLB fits a `/28`. Shape:

```
AXA CIDRs → internet NLB (public /28s, SG = tenant prefix list, no EIP)
          → internal ALB (private /26s, SG ingress ONLY from NLB SG, WAF attached here)
          → Istio NodePort 32080 (HC 32639) via aws_autoscaling_attachment on the system/kubesystem node ASGs
```

What is different from the plain public-ALB flow:

- **Client IP survives the NLB** (`target_type = "alb"` preserves it and can't be turned off), so a WAF IP set on the ALB matches the real tenant IP. The ALB SG still legitimately references the NLB SG. Both facts + the health-check corollary: [[nlb-alb-client-ip-preservation]].
- **`eis-waf` v1.0.4 keys its internal association by the ALB ARN**, unknown on a first plan when the ALB is born in the same apply → `for_each` failure. Pass `alb_arns = []` and own a statically-keyed association yourself:
  ```hcl
  resource "aws_wafv2_web_acl_association" "alb_eks_public" {
    for_each     = local.eks_public
    resource_arn = module.alb_eks_public[each.key].arn
    web_acl_arn  = module.eis_waf[each.key].web_acl_arn
  }
  ```
  Then `depends_on = [aws_wafv2_web_acl_association.alb_eks_public]` on the **NLB** — that is what replaces the staged SG gate here. The ALB exists before the association but is internal with no public path, so there is no open hole. `depends_on = [module.eis_waf]` is NOT enough: the module can exist with the ACL unattached.
- **The IGW is the real gate, not the SG.** These envs start with `create_igw = false`. Before applying core, prove the public subnets are empty — `aws ec2 describe-network-interfaces --filters Name=subnet-id,Values=<pub1>,<pub2>` must return nothing. Adding the IGW + `0.0.0.0/0` route otherwise exposes whatever is already sitting there.
- **Keep a host condition on the ALB listener rule**, not just in WAF: `host_header = ["*-<namespace>.<zone>"]` with a `fixed_response` 404 default. Losing it (e.g. switching to `path_pattern = ["/*"]`) makes the whole boundary rest on one WAF association surviving forever.
- **Public wildcard + private wildcard = split horizon.** `*.<stage-zone>` A-alias → NLB in the *public* zone; the private zone keeps its `*.` → internal ALB, so EIS-internal traffic bypasses WAF as before (expected). Model the record per **zone**, not `for_each` over clusters — the name is a zone-level constant and a second cluster duplicates it.
- **Namespace suffix beats exact host.** `host_match = "EXACTLY"` on one hostname 403s the app's other hosts (auth callback, API, static assets) and reads as "the site is broken". `ENDS_WITH "-<namespace>.<zone>"` (leading hyphen included, blocks near-match namespaces) is the FV-parity choice — at the cost that the boundary becomes a hostname convention any namespace can claim. Platform hosts using a different suffix (`grafana-monitoring.<zone>`) fall outside it correctly.
- **Rate rules in `count` for the first rollout**, same as the managed groups. `aggregate_key_type = "IP"` + preserved client IP + corporate NAT means one office is one IP; 2000/5 min ≈ 6.7 rps blocks real users mid-rollout.
- **NLB alias records need the NLB canonical zone, not `data.aws_elb_hosted_zone_id`.** That data source returns the ALB/Classic zone (us-west-2 `Z1H1FL5HABSF5`); NLB DNS names live in a different zone (us-west-2 `Z18D5FSROUN65G`). The mismatch plans clean and fails mid-apply with `InvalidChangeBatch: ... alias target name does not lie within the target zone` — after the NLB/ALB/WAF already exist. Use `data "aws_lb_hosted_zone_id" { load_balancer_type = "network" }`; no `eis-nlb` tag (≤v2.3.0) exports `zone_id` (its `output "name"` is actually the DNS name).
- **Don't add the public TG ARN to `irsa_alb_target_group_arns`.** Terraform owns registrations via the `aws_autoscaling_attachment`; granting the alb-controller Register/DeregisterTargets on that TG is the only thing that makes an accidental argocd `alb.targetGroupARNs` (TargetGroupBinding) conflict actually reachable — reconciler vs attachment fight over targets.
- **`eis-nlb` v2.0.0 facts** (verified in source): SG = TCP 80+443 from the tenant prefix lists only, no other ingress possible; it injects the ONLY ingress rules on the ALB SG (80/443 from NLB SG); `nlb_internal = false` is undocumented-but-working (AXA is the first external consumer); its known multi-prefix-list duplicate-SG-rule bug isn't triggered with a single list.

## Common mistakes

- Opening L3 (`["all"]`) before verifying the WAF live — defeats the gate.
- Forgetting core→services order → `services plan` errors `no managed prefix list found`.
- Treating the `InvalidPermission.Duplicate` as a config bug — it's CBD ordering; re-apply fixes.
- Leaving managed rule groups in `count` mode and assuming they block — they only observe until flipped to `block`.
- Bumping eis-alb to v1.0.3 on an AWS ~>6 stack (eis-iac) — its `~> 5.0` constraint conflicts; use v2.0.1+ there.
- Relying on `eis-waf` `excluded_rules` — silently a no-op in ≤v1.0.4 (module emits singular `rule_action_override`, upstream wafv2 v1.3.0 reads plural `rule_action_overrides`). Needs a module fix before any per-rule exclusion matters.
- `eis-waf` with `create_log_group = false` — the BYO-log-group branch builds a `:*`-suffixed ARN that WAF `PutLoggingConfiguration` rejects. Let the module create the group (`aws-waf-logs-` prefix handled) until fixed.
- Leaving `sample_requests` on for the allow rule while relying on log redaction — redaction does NOT apply to sampled requests; sampled copies of allowed traffic (incl. `Authorization`/`Cookie`) stay console-visible. Set `sample_requests = false` on that rule.

## Verify / rollback

- Verify: `aws wafv2 get-web-acl-for-resource --resource-arn <alb-arn>` (Name + DefaultAction=Block); rule list `aws wafv2 get-web-acl`; full `terraform plan` = No changes; live curl 403.
- Rollback: re-narrow SG (revert `["all"]` → `[administrative,<tenant>]`) — reversible. Disassociate WAF by removing `alb_arns`/module if needed.
