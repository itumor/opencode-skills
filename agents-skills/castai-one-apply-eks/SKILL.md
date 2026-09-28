---
name: castai-one-apply-eks
description: Use when working in /Users/eramadan/Documents/castai on the CAST AI one-apply EKS onboarding Terraform stack. Triggers on mentions of castai, EKS onboarding, one-apply, the repo path, or when editing root Terraform files in this project. Always consult this skill before modifying main.tf, data.tf, variables.tf, providers.tf, outputs.tf, versions.tf, tests/, scripts/, or brain/ in this repo.
---

# CAST AI One-Apply EKS Onboarding

## Project Snapshot
- **Repo**: `/Users/eramadan/Documents/castai`
- **Type**: Terraform stack for connecting one existing Amazon EKS cluster to CAST AI in a single apply.
- **Main modules**:
  - `castai/eks-cluster/castai` v14.6.1
  - `castai/eks-role-iam/castai` v2.0.4
- **Providers**: AWS `~> 6.23`, CAST AI `~> 8.53`, Helm `~> 3.1`
- **Terraform**: `>= 1.11, < 2.0`

## What the Stack Does
1. Registers the EKS cluster with CAST AI (`castai_eks_clusterid`).
2. Creates the CAST AI IAM role, instance profile, and policies via the IAM module.
3. Adds an EKS Access Entry of type `EC2_LINUX` for CAST AI nodes.
4. Onboards the cluster via the CAST AI EKS cluster module, which installs CAST AI Helm components.
5. Enables node autoscaling with Spot preference and on-demand fallback.

Default capacity policy:
- Spot-first (`spot = true`, `use_spot_fallbacks = true`).
- Optional products disabled: workload autoscaler, Kvisor, Egressd, Omni, AI Optimizer, CAST AI Live.

## Root File Responsibilities
- `versions.tf` — Terraform version constraint, S3 backend block, provider pins.
- `providers.tf` — AWS, CAST AI, and Helm provider configuration. Helm uses `aws eks get-token`.
- `variables.tf` — All inputs with validation. `castai_api_token` is sensitive.
- `data.tf` — Reads EKS cluster, subnets, security groups; defines `terraform_data.preflight` with lifecycle preconditions.
- `main.tf` — Core resources and module calls.
- `outputs.tf` — Cluster/org IDs, role/instance-profile ARNs, EKS auth mode.
- `README.md` — User-facing setup, install, verify, disconnect, and troubleshooting.
- `terraform.tfvars.example`, `backend.hcl.example` — Templates for local configuration.
- `.gitignore` — Excludes state, plans, `terraform.tfvars`, `backend.hcl`, and `.terraform/`.

## Directory Map
- `brain/` — Standing context, runbooks, notes, roadmap. Start here for project knowledge.
  - `BRAIN.md` — Main context, workflow, access notes, safety rules.
  - `notes/cast-ai-product-map.md` — Feature flags and product reference.
  - `notes/support-runbook.md` — Common EKS onboarding issues and fixes.
  - `roadmap.md` — Backlog/in-progress tracker.
- `scripts/` — Operational helpers (not invoked by Terraform).
  - `tf-check.sh` — fmt, validate, test, plan gate.
  - `k8s-diag.sh` — Post-apply CAST AI pod diagnostics.
  - `jira.py` — Jira Cloud helper for support workflow.
- `tests/` — Offline validation.
  - `stack.tftest.hcl` — Native Terraform tests with mocked providers.
  - `contract.sh` — CI gate enforcing file list, pinned versions, and hygiene.
- `support/` — Empty placeholder for ticket drafts/response templates.
- `.remember/` — Claude session handoff memory. The remember plugin is currently broken (missing `claude` CLI), so `remember.md` is maintained manually.

## Daily Agent Workflow
1. Check `.remember/remember.md` for handoff notes.
2. Read `brain/BRAIN.md` for standing context.
3. Classify incoming work: engineering bug, onboarding issue, config question, escalation.
4. Investigate using Terraform, AWS CLI, kubectl, Helm, and CAST AI docs.
5. Run validation before applying: `terraform fmt -check`, `terraform validate`, `terraform test`.
6. Update `brain/` if durable knowledge is gained.
7. Update `.remember/remember.md` before ending the session.

## Access & Secrets
- **CAST AI API token**: supply via `TF_VAR_castai_api_token` environment variable only. Never commit it.
- **AWS credentials**: standard SDK chain, or set `aws_profile` in `terraform.tfvars`.
- **Jira**: `JIRA_TOKEN` env var, but token lacks Browse Projects permission as of 2026-09-11. Use `scripts/jira.py` for JQL queries.
- **Local tools**: terraform, aws, kubectl, helm are available.

## Safety Rules
- Never commit `terraform.tfvars`, `backend.hcl`, plans, `.tfstate`, or `.terraform/`.
- Never print or log `castai_api_token`.
- Test destructive changes against non-production clusters first.
- `delete_nodes_on_disconnect` defaults to `false` to preserve nodes on destroy.

## Common Validation Checklist
Before any apply in this repo:
1. `terraform fmt -check -recursive`
2. `terraform validate`
3. `terraform test`
4. `terraform plan -out=castai.tfplan`

## Key External References
- CAST AI Terraform docs: https://docs.cast.ai/docs/terraform
- CAST AI Terraform troubleshooting: https://docs.cast.ai/docs/terraform-troubleshooting
- AWS EKS access entries: https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html
- CAST AI console: https://console.cast.ai
