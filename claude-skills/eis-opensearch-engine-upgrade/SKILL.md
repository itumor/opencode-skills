---
name: eis-opensearch-engine-upgrade
description: >-
  Use when upgrading the engine version of an AWS-managed OpenSearch domain (2.x -> 2.19 -> 3.x, "update
  OpenSearch to 3.7 and install security patches", COEXT-108169-style SaaS ELK security updates, "upgrade-domain",
  "engine_version bump", UpgradeDomain). Covers the upgrade path rules, pre-flight (check-only, index versions,
  packages, local docker compat test), the Terraform/Atlantis flow (one hop per MR), disruption class, monitoring,
  verification, and the traps hit on CAA UAT + share (first real attempt failed validation, compat flag flip,
  squash-title lint). Reference: COEXT-108169, credit-agricole/terraform !112 !207 !208 !211, 2026-10-01.
---

# AWS OpenSearch engine upgrade (Terraform + Atlantis)

Disruption: **BLIP** (blue/green; Dashboards may be unavailable; single node/no replica = rejected requests at cutover). Follow skill `iac-apply-disruption-check` for the handoff line. Ask the log/app owner "logs only? app in request path?" — CAA UAT was approved with no window on that answer.

## 1. Rules (verified 2026-10-01)
- **3.x only from 2.19.** `aws opensearch get-compatible-versions --domain-name D` is truth: 2.17 listed only 2.19 → **two hops = two MRs/applies**. 2.19 listed 3.1/3.3/3.5/3.7. 3.7 announced 2026-07-30, all regions.
- Indices created on 1.x / ES 7.10 must be reindexed first (`_all/_settings/index.version.created`; 2.17 = 136387827). Snapshots from those versions incompatible. Deprecated knn index settings fail the check on 2.19 → 3.x.
- Optional packages (`list-packages-for-domain`) can block. T3/Graviton instance types are fine for 3.x; check `list-instance-type-details --engine-version OpenSearch_3.7` for your types.
- Terraform: `engine_version` change = `UpgradeDomain` + wait, **update timeout 180 min**; module `eis-opensearch` regex and aws provider 6.38/6.62 accept 3.7 (no module/provider change). Async upgrade survives an Atlantis timeout: check `describe-domain`, re-plan, never blind re-apply.
- No downgrade. Automatic pre-upgrade snapshot is the only rollback (AWS Support).

## 2. Pre-flight (all read-only/non-mutating)
1. `aws opensearch upgrade-domain --domain-name D --target-version V --perform-check-only` then `get-upgrade-history` (PRE_UPGRADE_CHECK SUCCEEDED). **Check-only passing does NOT guarantee the real run passes** (UAT: passed 3x, first real run failed in Validation, retry succeeded; cause never shown; JVM 73% vs 75% limit was the suspect). Re-run it right before apply; pick a quiet time.
2. Disk: pre-check blocks >90% disk. CloudWatch `FreeStorageSpace` is the number to trust. Grow EBS first as its own apply (gp3 increase = DynamicUpdate, no blue/green; verify with `update-domain-config --dry-run --dry-run-mode Verbose`). Never stack volume + engine in one plan. Space EBS edits >= 6 h apart.
3. Snapshot data plane before/after: `~/.claude/scripts/os-state-snapshot.sh <out>` (indices, docs, templates, ISM, role mappings, plugins, SAML 302 via curl). Diff after each hop (compare role-mapping JSON semantically, not as strings).
4. Local compat test (docker, throwaway): `opensearchproject/opensearch:3.7.0` + the shipper image; replay the repo's in-domain JSON (pipeline, templates, ISM, FGAC role) on 2.19.3 vs 3.7.0 and diff HTTP results. ISM warm/cold actions are AWS-only (400 locally on both). Legacy `_opendistro/*` endpoints still 200 on 3.7; `_type` in bulk rejected on both.
5. Logstash `opensearchproject/logstash-oss-with-opensearch-output-plugin:8.9.0` (newest tag ever; plugin 2.0.1) works on 3.7; only a non-fatal startup ERROR "Failed to install template ... ecs-v8/3x.json" (plugin <2.1.1). Silence: `manage_template => false`.

## 3. Flow per hop (user gates apply/merge; push from user's terminal)
1. Worktree off explicit `origin/main` (never the shared checkout). After `git worktree add`, `git branch --unset-upstream` if it tracked another branch.
2. One-line change (`opensearch_custom.tf` engine_version, or share `opensearch_custom.auto.tfvars`). Commit msg must match `type(scope): TICKET-N - msg`.
3. `~/.claude/scripts/ci-local-scratch.sh <worktree> <branch> <new-scratch-dir>` (terraform_validate/tflint/checkov fail locally from missing job token; real CI on main is the baseline). User pushes; harness pre-push guard blocks Claude pushes (100s budget; env prefix useless).
4. `glab api --method POST .../merge_requests -H "Content-Type: application/json" --input mr.json` with `reviewer_ids:[861]`. **MR title becomes the squash commit subject — it must pass lint**, else main CI goes red (!112 happened).
5. `~/.claude/scripts/atlantis-wait-plan.sh` → expect `0 add, 1 change, 0 destroy` (`~ engine_version`). Share plan also showed `aws_opensearch_domain_policy ... (known after apply)` with identical content: artifact, dynamic.
6. User: `atlantis apply -p <project>`. Monitor: `~/.claude/scripts/os-wait-upgrade.sh D PROFILE REGION OpenSearch_X.Y` in background (UAT hop 34 min, share 29 min). A hop 2 MR is a NEW MR after hop 1 merged (squash). Merge promptly: Atlantis lock stays until merge, and the next MR's base must contain applied changes or its plan reverts them.

## 4. Verify (cite output)
`describe-domain` (version, Processing false, UpgradeProcessing false, ServiceSoftwareOptions), `get-upgrade-history` (UPGRADE+SNAPSHOT+PRE_UPGRADE_CHECK SUCCEEDED), `describe-domain-health` (Green, 0 unassigned for multi-AZ), data-plane diff vs before-state, SAML `/_dashboards/` 302, shipper still indexing (doc count grows). Share (IAM master role): assume `role/<domain>` from Admin SSO with session name containing `-`, `curl --aws-sigv4 "aws:amz:<region>:es"`; unsigned GET / = 401.

## 5. Side effects seen
- AWS flipped `AdvancedOptions.override_main_response_version` false → true on both domains; root `GET /` then reports `7.10.2`. Not in TF, no drift; shipper unaffected.
- Multi-AZ upgrade: `ClusterStatus.red` = 1 for ~5-10 min mid-upgrade (primary relocation), green after. Empty domain = no impact.
- Atlantis log lines `ephemeral.* Opening.../Closing...` (fivetran_hybrid, sftp secret) are normal noise, not errors; the real error is the last `Error:` line.

## 6. After the upgrade
Apply the in-domain runbook (share: `docs/terraform/custom/opensearch-stage.md` steps 2-5, idempotent, as master role) on the new version once. Patterns there were stage-only after the share move (no prod pattern/role).
