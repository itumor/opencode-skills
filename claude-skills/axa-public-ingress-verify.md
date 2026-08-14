---
name: axa-public-ingress-verify
description: Pre-merge verification for EISSAASDEV-302 public ingress MRs — Istio boundary, prefix list, IGW status
---

# AXA Public Ingress Pre-Merge Verification

Verify that infrastructure for the public-ingress stack (NLB→ALB→WAF→Istio) is ready before merge.

## Checklist

### 1. **Istio VirtualServices boundary**

All services claiming the `-axajp-dev01.dev.aws0.axajp-eis.cloud` hostname suffix must belong to the `axajp-dev01` namespace.

```bash
export AWS_PROFILE=axajp
CLUSTER_NAME="aws0axajpdeveks01"
REGION="us-west-2"

# Update kubeconfig
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION

# List all VirtualServices in axajp-dev01 namespace
kubectl get vs -n axajp-dev01 -o wide

# Verify each host ends in -axajp-dev01.dev.aws0.axajp-eis.cloud
# If any host doesn't match, it will be blocked by the WAF hostname rule
```

**Pass criteria:** All hosts match the suffix; no cross-namespace hosts.

---

### 2. **WAF IP allowlist**

The managed prefix list must contain all six AXA-approved source networks and must match the Terraform `waf_allowed_prefix_list` variable.

```bash
export AWS_PROFILE=axajp

# Find the prefix list (named aws0axajpdev-axajp)
PLIST_ID=$(aws ec2 describe-managed-prefix-lists \
  --filters "Name=prefix-list-name,Values=aws0axajpdev-axajp" \
  --region us-west-2 \
  --query 'PrefixLists[0].PrefixListId' \
  --output text)

# List entries
aws ec2 get-managed-prefix-list-entries \
  --prefix-list-id $PLIST_ID \
  --region us-west-2 | jq -r '.Entries[] | "\(.Cidr) - \(.Description)"'
```

**Expected entries (6 AXA CIDRs):**
- 131.229.128.0/17
- 208.65.144.0/21
- 185.125.224.0/22
- 208.81.64.0/21
- 185.212.104.0/22
- 185.221.68.0/22

**Pass criteria:** All 6 CIDRs present; state is `create-complete`.

---

### 3. **VPC Internet Gateway**

The Internet Gateway must be attached to the `AWS0-AXAJP-Dev` VPC for public traffic ingress.

```bash
export AWS_PROFILE=axajp

# Find the VPC
VPC_ID=$(aws ec2 describe-vpcs \
  --region us-west-2 \
  --filters "Name=tag:Name,Values=AWS0-AXAJP-Dev" \
  --query 'Vpcs[0].VpcId' \
  --output text)

# Check IGW attachment
aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --region us-west-2 \
  --query 'InternetGateways[*].[InternetGatewayId,Attachments[0].State]' \
  --output table
```

**Pass criteria:** At least one IGW with state `available`.

---

## Sign-Off

All three checks pass → **safe to merge and apply**.

**Post-merge tasks:**
1. Run Atlantis apply on MR !11
2. Provision NLB/ALB/WAF (Terraform execution order: infra → core → services)
3. **Day-1 operational:** Review WAF CloudWatch Logs group (`/aws/wafv2/…`), confirm no false positives from legitimate AXA traffic, then toggle WAF managed rules from COUNT mode to BLOCK mode via follow-up MR

## Related

- [[eissaasdev302_public_ingress_architecture]] — full architecture & rationale
- MR: `iac/projects/aws/axa-japan/terraform` !11 (COEXT-106502)
