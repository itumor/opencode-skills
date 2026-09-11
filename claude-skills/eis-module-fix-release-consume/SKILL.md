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
| **`publish_release` shows `skipped`, can't be played** | Its stage runs after `pre-commit`, so a red `pre-commit` on main blocks it. Usual cause is NOT your code — see the merge-commit lint bug below |
| Manual tag fallback | see memory semantic-release-ci-fallback |
| **Before releasing a breaking change** | `jq '.plugins[0][1].releaseRules' ci/.releaserc.json` must contain `{"breaking":true,"release":"major"}`, else the module CANNOT cut a major — back-fill it first (`~/.claude/scripts/releaserc-breaking-sweep.py`) |
| Consumer bump | edit ref in consumer, `terraform get` locally, validate, push → Atlantis replan |
| Local module fetch | `terraform get` works without GITLAB_TOKEN if git creds cached; `terraform init -backend=false` may still hit state — prefer `get` |

### Validating a consumer against a tag that doesn't exist yet

Chicken-and-egg: the consumer MR pins `?ref=vX.Y.Z`, but the tag isn't cut until the module MR
merges — so `terraform_validate` and `terraform_tflint` fail locally with
`invalid ref` / `pathspec 'vX.Y.Z' did not match`, and tflint additionally reports **every** module
in the directory as "not found" (one unresolvable source aborts the whole load).

Use the local-path source that these repos already carry commented out, run the hooks, then flip
it back before committing:

```hcl
# source = "git::https://...eis-backup.git?ref=v1.1.0"
source = "../../../../../../../terraform/modules/aws/eis-backup"
```

`terraform init -backend=false` then `pre-commit run --files <changed>` passes clean. Re-point to
the git ref before `git add` — and re-read the file afterwards, since `terraform fmt` realigns the
`=` when the source line length changes. Run pre-commit from the **repo root**, not the stage
directory, or every hook reports "no files to check" and silently does nothing.

### Post-merge `main` goes red and the release is skipped (merge-commit lint)

Several `eis-*` modules lint **every** commit in the push, including GitLab's auto-generated
`Merge branch 'x' into 'main'` — which is not a Conventional Commit and never can be. So `main`
turns red immediately after a perfectly good merge, `publish_release` is skipped, no tag is cut,
and the consumer's `?ref=vX.Y.Z` then fails with `invalid ref` / `pathspec did not match`.

Tell it apart from a real failure: in the job log every hook passes (`terraform validate`, `fmt`,
`tflint`, `checkov`, `terraform docs`) and your own feature commit passes both commit-msg lints —
only the merge commit fails. Retrying the job cannot help; the merge commit is still there.

Fix, in `.gitlab-ci.yml`, matching `terraform/template/module` (COEXT-105281, `540c69f`):

```bash
for COMMIT in $(git rev-list --no-merges ${TARGET_REV}..${CI_COMMIT_SHA}); do
```

Merging that fix is self-healing — the next main pipeline runs the corrected CI and skips the
merge commit. Diff the loop against the template's `.gitlab-ci.yml` to confirm they match.

Modules still missing `--no-merges` (checked 2026-08-13): `eis-asg`, `eis-vpc`, `eis-sftp`,
`eis-opensearch`, `eis-rds`, `eis-acm`, `eis-anfw`, `eis-cognito`, `eis-env-common-utility`. Each
will block its own next release. Detect fleet-wide with:

```bash
for f in $(grep -rln "rev-list" --include=".gitlab-ci.yml" terraform/modules/aws/); do
  grep -q "no-merges" "$f" || echo "MISSING: $f"
done
```

## The consumer-bump plan review (the part that prevents outages)

1. **Count adds/changes/destroys** and name every resource. Expected set only.
2. `grep "forces replacement"` — every hit on a resource that existed before the MR = STOP. Found live: `encrypted = false -> true # forces replacement` queued 5 production hosts (Jenkins, Keycloak, Atlantis...) for destroy.
3. **Zero-fleet-diff proof**: for map-based callers (`module.ec2[...]`), list distinct keys in the plan — only the keys you touched may appear.
4. New-default traps: a module fix that un-silences a previously-ignored input (or adds a default like `encrypted = true`) suddenly applies to EVERY caller. Defaults that change live state must be `null` (= preserve); features opt-in per caller.

## Upstream major-bump attribute traps

terraform-aws-modules majors rename inputs silently — object conversion fills missing attrs with `null`, no error, no plan-time hint. Known: ec2-instance v5→v6 `root_block_device` `volume_size`→`size`, `volume_type`→`type` (eis-ec2 ≤v2.2.0 dropped ALL caller disk settings → AMI-default unencrypted roots). When a wrapper bumps a wrapped module's major: diff the wrapped module's variable shapes, translate old key names in the wrapper, and **verify the real AWS resource post-apply** (`describe-volumes`, not the plan).

## Upstream provider-version traps (not just attribute renames)

A wrapped terraform-aws-modules pin can also silently hard-require a newer `hashicorp/aws` than the fleet's exact pin — no attribute changed, but the FIRST real consumer's `terraform init` fails on the provider constraint, and the naive fix (bump the consumer's aws pin) has fleet-wide blast radius. Found live: `eis-opensearch` v1.0.0 pinned upstream `terraform-aws-modules/opensearch/aws ~> 2.9.0` (needs `aws >= 6.41`); the fleet is on `6.28.0`/`6.38.0`. Fix in the wrapper, not the consumer — re-pin to the newest upstream tag whose `aws` constraint the fleet already satisfies, after confirming feature/variable/output parity at that older tag. Full method + the exact API calls: memory `terraform_provider_pinning_strategy` (second trap).

## Common mistakes

| Mistake | Fix |
|---|---|
| Merge module MR, assume tag exists | publish_release is manual — play it, then `git fetch --tags` and confirm |
| Bump consumer before tag exists | Atlantis init fails on missing ref; sequence: tag first, push second |
| Trust "Plan: N add, 0 destroy" headline | Replacements count as add+destroy pairs; grep "must be replaced" explicitly |
| Default a security attribute to `true` in a fix | Flips live resources → forced replacement; default `null`, opt in per caller |
| Validate consumer with `pre-commit run --all-files` locally | Unrelated dirs fail on missing `.terraform`; scope to changed files |
| README drift on module var changes | CI terraform-docs is pinned in `ci/.tf-docs.yml` (`version: "0.20"`); a newer local binary fails the hook with `Error: current version: 0.24.0, constraints: '0.20'` and does NOT regenerate. Use the pinned version — `docker run quay.io/terraform-docs/terraform-docs:0.20.0 --config ci/.tf-docs.yml .`, or grab the matching binary into a scratch dir (`terraform-docs-v0.20.0-<os>-<arch>.tar.gz` from the GitHub releases) and run `./terraform-docs --config=ci/.tf-docs.yml .`. Adding a var changes the README's Inputs table, Resources table AND the Usage snippet's optional-vars list, so always regen rather than hand-editing |
| `publish_release` 403s `git push` with "You are not allowed to push code to this project" even though the triggering user is Maintainer and `useJobToken: true`/`insteadOf` rewrite is correct | `CI_JOB_TOKEN` can only push to a **protected** ref on this instance. Compare `glab api "projects/<id>/protected_branches"` against a known-green sibling module — if the failing repo's default branch is missing from the list (e.g. `eis-opensearch`'s `master` was, unlike `eis-vpc`/`eis-ec2`'s protected `main`), protect it: `glab api -X POST "projects/<id>/protected_branches" -f name=<branch> -f push_access_level=40 -f merge_access_level=40 -f allow_force_push=false`. Not a token/URL misconfig — see memory `gitlab-job-token-push-needs-protected-branch` |
| Conventional-commit `!` breaking marker in the subject (`feat(scope)!: ...`) rejected by this repo's `jira-conventional-lint` regex | The old regex was `\(.*\): ` — it demanded `: ` immediately after the scope, so `!` failed. Fixed in template/module MR !6 to `\(.*\)!?: `; repos not yet back-filled still reject it. **Do NOT fall back to a `BREAKING CHANGE:` footer and assume you get a major** — see the releaseRules row below; on an unfixed repo the footer bumps *minor*. On an unfixed repo, add the breaking rule in the same MR, or plan to re-tag manually |
| A `feat!`/`BREAKING CHANGE:` commit merges into `main`/`master` but the release tags as `feat` (minor) instead of major | **Real cause: `ci/.releaserc.json` has explicit `releaseRules` with no `{ "breaking": true, "release": "major" }`.** Explicit rules *replace* the `conventionalcommits` preset defaults; the analyzer matches `{type: feat}`, returns minor, and only falls back to its built-in defaults when the custom rules match *nothing*. **This is NOT merge-commit footer loss** — that earlier diagnosis was wrong: `git log <lastTag>..HEAD` contains the original commit alongside the merge commit, so the marker IS seen (verified on `eis-opensearch` `4e4c9cc`, which carried `feat(opensearch)!:` intact and still released v1.1.0). Check the config BEFORE releasing: `jq '.plugins[0][1].releaseRules' ci/.releaserc.json`. See memory `semantic_release_release_rules_major` |
