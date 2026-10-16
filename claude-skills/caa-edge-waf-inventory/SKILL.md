---
name: caa-edge-waf-inventory
description: Use when asked to prove, list or summarise the live CloudFront and WAF rules for Credit Agricole (CAA) portals or dxp-api, whether geo restriction or WAF logging is on, or whether rules are "sufficient" for CAA sign-off. Read-only aws CLI recipe for account 144905517910 (upper), with the expected results and gotchas.
---

# CAA edge WAF inventory (read-only)

Account `144905517910` (upper), profile `CAA-Upper-ReadOnly`. WAF scope CLOUDFRONT lives in **us-east-1**, even though workloads are eu-west-3. Do not mutate anything.

## 1. Identity check
```bash
export AWS_PROFILE=CAA-Upper-ReadOnly
aws sts get-caller-identity --output json   # Account must be 144905517910
```
If this fails with an expired session, run the real command and then `aws sso login --profile CAA-Upper-ReadOnly`. Don't mint creds by hand (see memory `aws_profiles`).

## 2. ACLs and rules
```bash
aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --output json
aws wafv2 get-web-acl --scope CLOUDFRONT --region us-east-1 --name <name> --id <id> \
  --query 'WebACL.{Default:DefaultAction,Rules:Rules[].{Name:Name,P:Priority,Override:OverrideAction,MG:Statement.ManagedRuleGroupStatement.Name,Overrides:Statement.ManagedRuleGroupStatement.RuleActionOverrides}}' --output json
```
Do **not** pass `--page-size` to `wafv2 list-web-acls`; this CLI rejects it. Four ACLs are expected: `aws11caa{stage,prod}-{portals,dxp-api}-waf`.

## 3. Expected results, 2026-10-08
- stage portals: common, bad-inputs, ip-reputation, bot-control, sqli (all enforcing).
- stage dxp-api: common (SizeRestrictions_BODY -> Count), bad-inputs, ip-reputation, sqli (enforcing).
- prod portals: same groups, sqli **Override Count**.
- prod dxp-api: common (SizeRestrictions_BODY -> Count), bad-inputs, ip-reputation. **No sqli.**

Any difference means something changed since 2026-10-08. Report the diff, don't assume the TF is right.

## 4. Geo restriction (on distributions, not in WAF)
```bash
aws cloudfront list-distributions --query 'DistributionList.Items[].{Id:Id,Alias:Aliases.Items,WebACL:WebACLId,Geo:Restrictions.GeoRestriction}' --output json
aws cloudfront get-distribution-config --id <dist-id> --query 'DistributionConfig.Restrictions.GeoRestriction.Items' --output text
```
Expected: `whitelist`, 27 EU countries (AT BE BG CY CZ DE DK EE ES FI FR GR HR HU IE IT LT LU LV MT NL PL PT RO SE SI SK). GB, CH and the French overseas codes are absent, which is an open question for CAA.

## 5. Logging
```bash
aws wafv2 get-logging-configuration --region us-east-1 --resource-arn <acl-arn>
```
`WAFNonexistentItemException` = **no logging configured** (expected on all four ACLs as of 2026-10-08). That is a valid answer, not an access error.

## 6. Report
Give a table: ACL, rules and modes, geo, logging. Cite the command output. Mention doc drift: `docs/terraform/custom/portals-cloudfront-waf-shield.md` says 28 geo entries.

Related memory: `caa_edge_waf_live_inventory_20261008`, `caa_waf_sufficiency_escalation_20261008`.
