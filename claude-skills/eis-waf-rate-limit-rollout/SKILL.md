---
name: eis-waf-rate-limit-rollout
description: Use when asked to add a call limit / rate limit / DoS protection to an API or portal "from the AWS side" with eis-waf (pen test finding "no rate limiting", "add call limitation", "limit per IP", "limit per user not IP"), when rolling a WAF rate rule count -> block across UAT/preprod/prod, when testing a rate rule end to end ("test the block"), or when a client asks whether WAF can limit per portal user. Covers placement per environment, the two-MR count-then-block rollout, cost and disruption lines, the burst test script, what the test shows, and the per-user answer. Reference run COEXT-113348 (CAA DXP member/broker, 2026-11-20/24).
---

# eis-waf rate limit rollout (count -> test -> block -> test)

Reference: COEXT-113348, CAA terraform MRs !297 (preprod, count), !298 (UAT, count), !299 (UAT, block).

## 1. Where the rule goes
| Environment shape | Placement |
|---|---|
| CloudFront in front (CAA preprod/prod) | existing `waf_*` module, scope CLOUDFRONT: add `rate_rules` |
| No edge, internal ALB only (CAA UAT, lower stages) | new REGIONAL web ACL on the cluster ALB: `scope = "REGIONAL"`, `alb_arns = [module.alb_eks["01"].arn]`, `default_action = "allow"`, file `waf_custom.tf` |

The cluster ALB serves every namespace. Limit only the wanted hosts with `scope_down_hosts`.
With N hosts the module makes N rules (`<name>-h0`, `-h1`, priority `p`, `p+1`), each with its own counter. PR-Agent reads it as one shared rule: answer with the plan output.

```hcl
rate_rules = [{
  name             = "rate-per-ip"
  priority         = 10
  limit            = 1000        # per 5 minutes per source IP
  action           = "count"     # MR 2 flips to "block"
  scope_down_hosts = local.dxp_rate_limit_hosts
}]
```
`eis-waf` (v1.0.6, v2.0.0) keys rate rules on IP only. Any other key = module MR first.

## 2. Rollout
1. MR 1: `action = "count"`. Plan: new ACL = `2+ to add`; existing ACL = `1 to change`, other rules shown removed and re-added identical (cosmetic).
2. Cost approval before apply (skill `cloud-cost-change-approval`). Price: web ACL $5/mo, each rule $1/mo (N hosts = N rules), $0.60 per 1M requests on everything the ACL inspects. Get the request volume from CloudWatch `AWS/ApplicationELB RequestCount` for the ALB, 30 days. Monthly Cost Change = fixed part, Variable Usage = request part. Public price list needs no AWS login: `https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/awswaf/current/<region>/index.json`.
3. Disruption for count mode and for count -> block: NONE (ACL attach and rule edit do not touch listeners or targets). Evidence = plan + `get-web-acl-for-resource` showing no ACL attached before.
4. Apply (user), then count test (section 3).
5. MR 2: `"count"` -> `"block"`. Plan `0 to add, 1 to change`. `Cost: NONE` (no resource added). Apply, then block test.
6. Lower stages use `atlantis apply -p <project>`, upper stages `atlantis-upper ...`. One open MR per dir holds the Atlantis lock.

## 3. End-to-end test
```bash
bash ~/.claude/scripts/waf-rate-e2e.sh <limited-host> 2400 <other-limited-host>
```
Then read:
```bash
aws wafv2 get-rate-based-statement-managed-keys --scope REGIONAL --web-acl-name <acl> --web-acl-id <id> --rule-name <rule> --profile <ro> --region <r>
# CloudWatch AWS/WAFV2: CountedRequests (count mode) or BlockedRequests (block mode), dimensions WebACL, Region, Rule
# AWS/ApplicationELB: HTTPCode_ELB_5XX_Count must stay empty
```
Pass = limited host trips, control host stays clean (per-host counters), no ALB 5xx, and in block mode the host answers again without any action.

What the CAA run showed, expect the same:
- **Detection lag.** First 403 came at request ~1460 with limit 1000. About 460 requests pass above the limit. Tell the pen testers before they report it as a miss.
- **Self-recovery.** Block lifted ~4.5 min after the burst ended.
- **Block answer.** `403`, `server: awselb/2.0` (regional ACL on ALB).
- **Count mode only counts requests above the limit**, so no metric appears until the limit is passed.
- **Source IP is the VPN NAT.** On CAA UAT every VPN user reaches the ALB as `10.31.252.3`. One counter for all of them; a block-mode test blocks every VPN user on that host for the window. Warn first.
- Any path works for the test; the rule matches the host header.

CloudFront-scope run (CAA preprod !297, 2026-11-25), differences from the ALB run:
- **One rule without `scope_down_hosts` = one counter per IP across every distribution on the ACL.** Burst on the member host also blocked the broker host for that IP. The "control host stays clean" check only applies when hosts have their own rules.
- **Lag is time, not request count.** 2400 requests in 44 s: first 403 at request 2205 (~35 s). Slower burst on UAT: first 403 at ~1460.
- Recovery ~5.5 min. Source IP = the caller's public IP (the laptop's egress), not the VPN NAT.
- Low-traffic env: skip the count stage when 14 days of `AllowedRequests` (Rule=ALL, 5-minute Sum) show the busiest window for all IPs far under the limit. State that evidence in the MR.
- CloudFront metrics: `AWS/WAFV2` dimensions `WebACL` + `Rule` only (no Region), region us-east-1; `AWS/CloudFront` `5xxErrorRate` per `DistributionId`, `Region=Global`.
- PR-Agent `describe` rewrites the MR description on every push and keeps the first "User description". Update the description after the last push, then answer any "description/code mismatch" finding on the MR.
- The push watcher does not see the upper Atlantis bot (`caa_tf_build`, statuses `atl-upper/plan`): it ends `TIMED_OUT missing=atlantis`. Read the plan note from the MR.
- Update an open MR branch with `git merge origin/main` and a `chore(merge): NOJIRA-001 - ...` message: no force-push.

Prod and template (CAA !300 + template/client !62, 2026-11-25):
- **Template first, or same day.** `portals.tf` and `variables.tf` under `upper/<stage>/services` are template-owned. The wiring (`waf_rate_rules` in `portals.dxp_api`, `rate_rules = local.dxp_api.waf_rate_rules` on `module "waf_dxp_api"`) belongs in `iac/terraform/template/client` too; reviewer asks for it. Template MR carries wiring + empty default only; test `bash ci/mock-test.sh`; its push is the user's (pre-push hook cannot pass on raw Jinja). Memory `feedback-client-edit-in-template-owned-file-needs-template-mr`.
- **Prod stage dir is behind prod-guard:** I cannot read or edit it. User ports the merged stage diff (`git diff <a> <b> -- upper/stage/services | sed ... | git apply --exclude=<tfvars> -`), then inserts the tfvars block with a script file I hand over, commits, pushes. Every step for him = ONE line. Recipe in memory `harness-prod-path-guard-blocks-reads`.
- **Wiring-only head plans `No changes`.** If the plan says that, the tfvars values commit is missing.
- **Verify "pushed" on the remote** (`git ls-remote --heads`, `git diff --stat origin/main...origin/<branch>`) before opening the MR.
- **Cost approval per env.** Approval for UAT ($7) does not cover preprod and prod (+$1 each). Send the updated amount before the first upper apply; on COEXT-113348 the upper rules were applied on the old approval and the gap had to be reported.
- **Close-out:** read all three ACLs live (`get-web-acl`, `get-web-acl-for-resource`), state per env "live and tested" or "live, not load tested", then the resolution comment.

## 4. "Limit per user, not per IP"
Pen testers ask for it right after the IP limit. Answer used on COEXT-113348: per-user limit belongs to the application team, inside the API; WAF keeps the IP limit as the first layer.
- WAF sees IP, headers, URL. It cannot read a verified user.
- WAF can key a rate rule on a header or cookie, but that is per login token, not per user: new login = new counter, random token per request = fresh bucket every time. Do not sell it as per-user.
- Traps: "API Gateway maps JWT `sub` to a header and WAF keys on it" and "CloudFront Function decodes the JWT for WAF". WAF on CloudFront runs before both (second one not checked against the AWS doc).
- A real per-user limit at platform level = Istio gateway rate limit on the validated JWT claim. Needs a rate limit service in the cluster and the app team's token details.
- Before building anything token-keyed, get from the app team: header or cookie name, JWT or not, anonymous endpoints, normal calls per user.

## 5. Traps from the run
- `gitlab-ci-local` cannot run the repo's `pre-commit` job (image entrypoint rejects `sh`). Record NOT RUN; rely on local `pre-commit run --files ...` plus the real GitLab job.
- verify-gate keeps failing on the stage dir for an old checkov finding in another file. State it, do not ack, and remove the merged worktree when the user agrees.
- ACL tags come from `local.tags`, so the `Issue` tag is the stage default, not the ticket.
- `aws sso login` for one CAA profile makes the other CAA profiles work.
