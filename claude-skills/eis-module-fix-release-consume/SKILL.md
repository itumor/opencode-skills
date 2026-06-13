---
name: eis-module-fix-release-consume
description: Use when fixing a shared eis-* terraform module (iac/terraform/modules/aws/*) and rolling the new version into a consumer project — module MR + review, the manual publish_release job, version bump in the consumer, and validating the bump plan for hidden fleet damage (forced replacements, attribute drift across module major bumps). Also use when a consumer plan shows "forces replacement" on instances nobody touched, or when wrapped upstream modules (terraform-aws-modules) renamed attributes across a major version.
---

# eis-module fix → release → consume

## Overview
Shared eis-* modules are consumed at pinned tags by many customer projects. A module fix is only half the work — the release mechanics and the consumer-bump plan review are where outages hide. Core principle: **a green consumer plan is not enough; read WHY each resource changes, and treat any `# forces replacement` on a pre-existing resource as a stop signal.**

## Quick reference

| Step | Command / fact |
|---|---|
| Branch + commit | `fix(scope): COEXT-### - msg` (JIRA lint: `type(scope): TICKET - msg`, scope REQUIRED, `ci` type not allowed) |
| MR | `glab mr create` + `glab api -X PUT "projects/:fullpath/merge_requests/<iid>?reviewer_ids[]=<uid>"` (mzivarts=253) |
| tflint CI 403 rate-limit | GitHub API limit on shared runner IP; wait for "rate reset in Xs" then `glab api -X POST .../pipelines/<id>/retry` |
| Release | `publish_release` on the main pipeline is `when: manual` — PLAY it (`glab api -X POST .../jobs/<id>/play`); merge alone produces NO tag |
| Manual tag fallback | see memory semantic-release-ci-fallback |
| Consumer bump | edit ref in consumer, `terraform get` locally, validate, push → Atlantis replan |
| Local module fetch | `terraform get` works without GITLAB_TOKEN if git creds cached; `terraform init -backend=false` may still hit state — prefer `get` |

## The consumer-bump plan review (the part that prevents outages)

1. **Count adds/changes/destroys** and name every resource. Expected set only.
2. `grep "forces replacement"` — every hit on a resource that existed before the MR = STOP. Found live: `encrypted = false -> true # forces replacement` queued 5 production hosts (Jenkins, Keycloak, Atlantis...) for destroy.
3. **Zero-fleet-diff proof**: for map-based callers (`module.ec2[...]`), list distinct keys in the plan — only the keys you touched may appear.
4. New-default traps: a module fix that un-silences a previously-ignored input (or adds a default like `encrypted = true`) suddenly applies to EVERY caller. Defaults that change live state must be `null` (= preserve); features opt-in per caller.

## Upstream major-bump attribute traps

terraform-aws-modules majors rename inputs silently — object conversion fills missing attrs with `null`, no error, no plan-time hint. Known: ec2-instance v5→v6 `root_block_device` `volume_size`→`size`, `volume_type`→`type` (eis-ec2 ≤v2.2.0 dropped ALL caller disk settings → AMI-default unencrypted roots). When a wrapper bumps a wrapped module's major: diff the wrapped module's variable shapes, translate old key names in the wrapper, and **verify the real AWS resource post-apply** (`describe-volumes`, not the plan).

## Common mistakes

| Mistake | Fix |
|---|---|
| Merge module MR, assume tag exists | publish_release is manual — play it, then `git fetch --tags` and confirm |
| Bump consumer before tag exists | Atlantis init fails on missing ref; sequence: tag first, push second |
| Trust "Plan: N add, 0 destroy" headline | Replacements count as add+destroy pairs; grep "must be replaced" explicitly |
| Default a security attribute to `true` in a fix | Flips live resources → forced replacement; default `null`, opt in per caller |
| Validate consumer with `pre-commit run --all-files` locally | Unrelated dirs fail on missing `.terraform`; scope to changed files |
| README drift on module var changes | CI terraform-docs pinned (0.20) vs local; regen via `docker run quay.io/terraform-docs/terraform-docs:0.20.0 --config ci/.tf-docs.yml .` |
