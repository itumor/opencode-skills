---
name: checkov-scanning
description: Generic Checkov static-analysis usage for IaC (Terraform, CloudFormation, Kubernetes manifests, Helm, Dockerfile, ARM, Bicep) — running scans, reading a CKV_* finding, suppressing a check inline vs via config, baseline files, custom policies in Python/YAML, and the module-download caching gotcha where cached .terraform/modules get scanned even with --skip-download. Use whenever the user mentions Checkov, a CKV_AWS_*/CKV_K8S_*/CKV2_* finding ID, "checkov failed in CI", suppressing a specific check, or wants a repo/module scanned for IaC security misconfigurations — even if they just say "the security scanner flagged this" without naming Checkov explicitly. Not tied to any one company's baseline; check for a repo-local .checkov.yaml or verify-iac-changes-style skill first if one exists.
---

# Checkov

Checkov is a static analysis scanner for infrastructure-as-code — it parses Terraform/CloudFormation/K8s/Helm/Dockerfile/ARM/Bicep without ever touching a cloud API, and flags configurations that violate a large built-in policy library (encryption at rest, public exposure, IAM wildcard actions, missing logging, etc.).

## Running it

```bash
checkov -d .                          # scan a directory recursively
checkov -f main.tf                    # scan a single file
checkov -d . --framework terraform    # restrict to one framework (faster, less noise)
checkov -d . --compact                # condensed output
checkov -d . -o json > results.json   # machine-readable output for CI gating
```

## Reading a finding

```
Check: CKV_AWS_20: "S3 Bucket has an ACL defined which allows public READ access"
    FAILED for resource: aws_s3_bucket.data
    File: /main.tf:12-18
```

The check ID prefix tells you the framework: `CKV_AWS_*` (Terraform AWS resources), `CKV_K8S_*` (Kubernetes manifests), `CKV2_*` (graph-based checks that reason across multiple resources, not just one block in isolation — these can't be understood by reading a single resource, they trace a relationship like "is this security group actually attached to a public-facing load balancer").

## Suppressing a check

**Inline, scoped to one resource** (preferred — keeps the reason next to the code):
```hcl
resource "aws_s3_bucket" "logs" {
  #checkov:skip=CKV_AWS_18:access logging not required for this internal scratch bucket
}
```

**Repo-wide, via config file** (`.checkov.yaml` at repo root, or `--config-file`):
```yaml
skip-check:
  - CKV_AWS_18
```

Always suppress with a reason, and prefer the inline scoped form over repo-wide skip — a repo-wide skip silently blinds the scanner to that class of finding everywhere, including future resources that genuinely need the check.

## Baseline files

```bash
checkov -d . --create-baseline
checkov -d . --baseline .checkov.baseline
```

A baseline freezes today's known findings so CI only fails on *new* violations introduced going forward — useful for adopting Checkov on a large existing codebase without a big-bang remediation, but it's a ratchet, not a fix: findings in the baseline still exist and should get tracked separately for cleanup.

## Custom policies

Checkov supports custom checks in Python (subclass `BaseResourceCheck`) or in a simpler YAML DSL for attribute-based rules, loaded via `--external-checks-dir`. Reach for YAML custom checks first for simple attribute assertions; drop to Python only when the logic needs to reason across resources or do something the YAML DSL can't express.

## The module-cache scanning gotcha

`--skip-download` only stops Checkov from *fetching* remote Terraform modules it hasn't seen — it does **not** stop Checkov from scanning module source already present in `.terraform/modules/` from a prior `terraform init`. If a scan surfaces findings inside a third-party module's internals that "shouldn't be ours to fix," check whether `.terraform/` is present in the scan path: either run from a clean checkout (no `.terraform/`), pass `--skip-path .terraform`, or accept that vendored module code is in scope and suppress/track those findings separately from your own resources.

## CI integration pattern

Run Checkov with `-o json`, fail the pipeline on any `FAILED` result outside the baseline, and post a compact summary (not the full JSON) as a PR comment or check annotation — full JSON output in a PR comment is unreadable past a handful of findings.
