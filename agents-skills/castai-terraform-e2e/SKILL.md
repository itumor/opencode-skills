---
name: castai-terraform-e2e
description: Use when validating CAST AI Terraform EKS onboarding modules end-to-end, especially when dealing with EU API endpoints, API token authentication failures, read-only versus full-access modes, or ferment scope reductions.
---

# CAST AI Terraform E2E

## Overview
Validate CAST AI Terraform modules against an existing EKS cluster without committing secrets. Distinguish read-only (Helm-only) and full-access (CAST AI provider + IAM) modes, and handle EU-region token/auth edge cases safely.

## When to Use
- Running `terraform plan/apply` against `castai-eks-readonly` or `castai-eks-full` examples
- CAST AI provider returns HTTP 401/403 during initialization
- Need to choose between read-only observability mode and full-access onboarding mode
- Target cluster is in an AWS region paired with CAST AI EU (`https://api.eu.cast.ai`)
- A ferment or task requires documenting scope reductions for live apply/E2E blockers

## Core Pattern

### 1. Export token as TF_VAR, never commit it
```bash
export TF_VAR_castai_api_token="$CASTAI_API_KEY"
# Validate token scopes before plan:
curl -s -H "X-API-Key: $CASTAI_API_KEY" https://api.eu.cast.ai/v1/auth/tokens
```

### 2. Match API URL to key region
| Key region | `castai_api_url` | Console org hint |
|---|---|---|
| EU | `https://api.eu.cast.ai` | `console.eu.cast.ai` |
| US (default) | `https://api.cast.ai` | `console.cast.ai` |

### 3. Mode differences
| Aspect | Read-only | Full-access |
|---|---|---|
| Provider | no `castai/castai` provider | uses `castai/castai` |
| Resources | `helm_release` only | IAM role, instance profile, EKS access entry, cluster registration, Helm release |
| Token validation | only via Helm values at runtime | during `terraform plan` (provider init) |
| Negative test error | AWS STS `InvalidClientTokenId` | CAST AI provider `status=401 Authorization Required` |

## Quick Reference

### Validate both example roots
```bash
cd terraform/examples/castai-eks-readonly
terraform fmt -check && terraform init && terraform validate
terraform plan -var-file=terraform.tfvars

cd terraform/examples/castai-eks-full
terraform fmt -check && terraform init && terraform validate
export TF_VAR_castai_api_token="$CASTAI_API_KEY"
terraform plan -var-file=terraform.tfvars
```

### Common auth errors
- `status=401 Authorization Required` from `castai/castai` → token invalid or belongs to a different org/region
- `403 Forbidden` on cluster registration → token lacks cluster-management scope or org mismatch
- AWS `InvalidClientTokenId` → AWS credentials invalid; not a CAST AI error

## Scope Reduction Rules
When live apply is impossible due to token/auth blockers:
1. Document the exact HTTP error and endpoint.
2. Record a formal decision (e.g., `D001`, `D002`) in the coordination file.
3. Verify as much as possible at plan level (AWS resource types, Helm release count).
4. Capture negative tests for invalid credentials.
5. Never commit secrets or literal tokens.

## Common Mistakes
- Storing `castai_api_token` directly in `terraform.tfvars` instead of using `TF_VAR_castai_api_token`
- Assuming a token that passes `/v1/organizations` can register clusters (registration needs broader scope)
- Running full-access `terraform apply` without first verifying provider init with `terraform plan`
- Leaving `.tfplan`, `.tfstate`, or `.backup` files in example roots after validation
