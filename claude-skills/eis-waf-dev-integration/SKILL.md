---
name: eis-waf-dev-integration
description: End-to-end playbook for eis-waf module development, eis-iac dev/services consumption (WAF POC on internal ALB), Terraform apply/verify, and post-merge health checks for EKS, ArgoCD capability, and Velero on aws0iacdeveks01. Use when reviewing or deploying eis-waf, waf.tf, GENESIS-428120 POC, or verifying dev/services after WAF/Velero MRs.
---

# eis-waf + eis-iac dev/services — integration playbook

## Repos and pins

| Repo | Path | Notes |
|------|------|-------|
| Module | `terraform/modules/aws/eis-waf` | SemVer tags; pin consumers `?ref=vX.Y.Z` |
| Consumer | `projects/aws/eis-iac/terraform/lower/dev/services` | **Not Atlantis** — local `terraform plan/apply` |
| Current pin | `eis-waf v1.0.3` (iac still on v1.0.1 — no diff needed) | Tag pushed manually when CI `publish_release` lacks push token |

Cluster: `aws0iacdeveks01` · Profile: `iac` · Region: `us-west-2` · Account: `182399717428`

## Module conventions (eis-waf)

- Wraps `terraform-aws-modules/waf/aws` (~> 5.x); provider AWS ~> 6.x in eis-iac stack.
- **`host_ip_rules`**: one WAF rule per host when `hosts` has multiple entries (priorities `priority`, `priority+1`, …). Leave gaps (10, 20, 30).
- **`hosts = []`** (v1.0.3+): degrades to IP-only rule (bare `ip_set_reference_statement`, no host filter). Use for "trust this CIDR range to reach ANY domain on ALB" patterns (EIS corp internal CIDRs via TGW). Single rule emitted at `priority` (no `idx` spread).
- **`negate_ip`**: not implemented — document as reserved; use `default_action = "block"` + `action = "allow"` rules instead.
- **Validations** (v1.0.1+): `ip_set_name` must exist in `ip_sets`; rule names unique.
- **Logging**: static `depends_on = [module.ip_set]` on log group — **not** `concat(...)` (invalid in module).
- **CI gotcha**: merge commits fail commit-msg lint unless `.gitlab-ci.yml` uses `git rev-list --no-merges` for semantic-release.

## Consumer pattern (waf.tf)

`eis-alb v1.0.2` has **no `arn` output** — do not use `module.alb_eks[].arn` until eis-alb v2.x (needs `dns_zone_name` API change; provider conflict with v1.0.3 on AWS ~>5).

```hcl
data "aws_lb" "eks_internal" {
  for_each = var.eks
  name     = module.alb_eks[each.key].name
}

module "eis_waf" {
  source   = "git::.../eis-waf.git?ref=v1.0.1"
  for_each = var.eks
  alb_arns = [data.aws_lb.eks_internal[each.key].arn]
  depends_on = [module.alb_eks]
  # POC IPs/host in var.waf_poc (terraform.tfvars.json), not hardcoded
}
```

POC (GENESIS-428120): `default_action = "allow"` + targeted **block** rule for tester IP set + one host. Internal ALB only sees **corp VPN NAT** (`10.31.252.10/32`); public laptop IP in set is for future public ALB promotion.

## Terraform apply (dev/services)

**Always both var-files** (parent has `domain_name`, stack has `eks`, `waf_poc`, `velero`):

```bash
export AWS_PROFILE=iac AWS_REGION=us-west-2 AWS_SDK_LOAD_CONFIG=1
cd projects/aws/eis-iac/terraform/lower/dev/services

# Refresh SSO if backend fails with expired session
aws sso login --profile iac

terraform plan  -var-file=../terraform.tfvars.json -var-file=terraform.tfvars.json
terraform apply -var-file=../terraform.tfvars.json -var-file=terraform.tfvars.json
```

**Credentials trap**: backend has `profile = "iac"`. Do **not** `eval "$(aws configure export-credentials ...)"` alongside profile — Terraform prefers profile and may still use stale SSO cache.

## Post-apply verification checklist

Copy and run:

```bash
export AWS_PROFILE=iac AWS_REGION=us-west-2 AWS_SDK_LOAD_CONFIG=1
CLUSTER=aws0iacdeveks01

# EKS
aws eks describe-cluster --name $CLUSTER --query 'cluster.{status:status,version:version}'
aws eks update-kubeconfig --name $CLUSTER --region us-west-2
kubectl get nodes
kubectl get pods -n kube-system --field-selector=status.phase=Running | wc -l

# WAF
ACL_ARN=$(aws wafv2 list-web-acls --scope REGIONAL --query "WebACLs[?contains(Name,'deveks01')].ARN|[0]" --output text)
aws wafv2 list-resources-for-web-acl --web-acl-arn "$ACL_ARN" --resource-type APPLICATION_LOAD_BALANCER
# Block metric (last hour)
NAME=$(echo "$ACL_ARN" | awk -F'/' '{print $(NF-1)}')
aws cloudwatch get-metric-statistics --namespace AWS/WAFV2 --metric-name BlockedRequests \
  --dimensions Name=WebACL,Value=$NAME Name=Region,Value=us-west-2 Name=Rule,Value=poc-block-tester-on-dashboard \
  --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 --statistics Sum --region us-west-2

# ArgoCD (EKS managed capability — not in-cluster argocd ns)
aws eks list-capabilities --cluster-name $CLUSTER
ARGO_URL=$(terraform output -json argocd_capabilities | python3 -c "import sys,json;print(json.load(sys.stdin)['01']['server_url'])")
curl -sk -o /dev/null -w '%{http_code}\n' "$ARGO_URL/healthz"

# Velero
kubectl get pods -n velero
kubectl get backupstoragelocation -n velero
kubectl get backup -n velero --sort-by=.metadata.creationTimestamp | tail -3
aws s3 ls s3://aws0iacdevvelero-backups/backups/ | tail -3
```

**Pass criteria**: EKS ACTIVE + nodes Ready; WAF associated to `aws0iacdeveks01-alb`; ArgoCD capability ACTIVE + healthz 200; Velero pods Running, BSL `Available`, recent `Completed` backups.

## Known benign plan drift

After apply, plan may still show **3 in-place changes** (cosmetic, safe to ignore unless chasing empty plan):

1. `module.s3["gitlab-runner-cache"].…server_side_encryption_configuration`
2. `module.s3["velero-backups"].…server_side_encryption_configuration`
3. `module.eks["01"].…aws_eks_addon.this["coredns"]` (release version churn)

Fix later with `lifecycle { ignore_changes }` on SSE blocks or pinned addon version — not a failed apply.

## MR history (May 2026 session)

| Repo | MR | Summary |
|------|-----|---------|
| eis-waf | !4 | Validations, logging depends_on, docs |
| eis-waf | !5–!6 | CI commit-msg + publish_release visibility |
| eis-iac | !11 | waf.tf best practices, waf_poc var, outputs |
| eis-iac | !12 | bump eis-waf v1.0.1 |
| eis-iac | !6 | Velero native dev + ArgoCD CodeConnections ARNs (merge kept both Velero outputs and eis_waf) |

## Promotion path (POC → AFA)

1. Validate block metrics + host rule on dev internal ALB.
2. Bump module tag; pin in target env (`aws0fvdemoeks01` per GENESIS-428120).
3. For public ALBs, public tester IPs in `ip_sets` will match; internal ALB POC does not exercise public IP path.

## Module release fallback (when CI publish_release fails EGITNOPERMISSION)

CI runs as `gitlab-ci-token` which lacks push on protected `main`. Semantic-release fails. Tag + release manually:

```bash
cd terraform/modules/aws/eis-waf
git fetch --tags
git checkout main && git pull --ff-only
git log --oneline -3   # confirm merge SHA

git tag vX.Y.Z -m "vX.Y.Z - <jira> - <one-line>" <merge-sha>
git push origin vX.Y.Z

glab api -X POST "projects/1569/releases" \
  -f "tag_name=vX.Y.Z" \
  -f "name=vX.Y.Z" \
  -f "description=<markdown release notes>"
```

## Backwards-compat validation before tagging

Before merging a module change with backwards-compat claims:

```bash
# In consumer repo (eis-iac), local-only branch
git checkout -b test/<module>-vNNN-validation
# Edit waf.tf: swap source ref to feature branch
#   source = "git::..../<module>.git?ref=<feature-branch>"
terraform init -upgrade
terraform plan -var-file=... -target='module.eis_waf'
# Expect: "No changes." → safe to merge + tag
git restore <changed files> && git checkout main && git branch -D test/...
```

## Sequential MR plan dependency

Chains where each MR references resources the prior MR creates (data lookups): plan order = apply order. Downstream MR plans fail with `Error: no matching <resource>` until upstream is applied to AWS. State doesn't cross branches. Document apply sequence in MR description; rebasing alone doesn't fix it.
