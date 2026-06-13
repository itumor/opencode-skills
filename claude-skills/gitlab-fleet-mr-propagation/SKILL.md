---
name: gitlab-fleet-mr-propagation
description: Use when an identical small change (1-2 files, e.g. .gitlab-ci.yml or .pre-commit-config.yaml) must land in many GitLab repos at once — template-alignment fixes across the eis-* terraform module fleet, CI lint/policy rollouts, copier-template drift hotfixes — or when a batch of MR pipelines fails with "API rate limit exceeded" on tflint plugin install, or when batched glab loops return bogus "404 Project Not Found"/"404 Not found" errors.
---

# GitLab Fleet MR Propagation

## Overview

Propagate a small identical change to N repos **server-side via the Commits API** — no clones, no worktrees, no local state touched. GET raw file → deterministic patch → `POST /repository/commits` → `POST /merge_requests`. Proven 2026-06-12: 18 repos (template/module + 17 eis-* modules), COEXT-105281.

**Fix the template first** (`iac/terraform/template/module`), tag a release, then propagate the same diff to generated repos directly (copier update is overkill for 1 line; next update is a no-op).

## Core recipe (per repo, ~3 API calls)

```bash
export GITLAB_HOST=sfo-cvdevopsgit01.eqxdev.exigengroup.com   # ALWAYS — see traps
PROJ="iac%2Fterraform%2Fmodules%2Faws%2F${name}"
glab api "projects/${PROJ}/repository/files/%2Egitlab-ci%2Eyml/raw?ref=main" > ci.yml
# Patch with python (assert exactly-1 match; abort on drift). NOT sed -i (BSD/GNU).
# Skip-guards: grep new-content already present → SKIP; old line count != 1 → MANUAL.
jq -n --rawfile content ci.yml --arg branch "$BRANCH" --arg msg "$MSG" \
  '{branch:$branch, start_branch:"main", commit_message:$msg,
    actions:[{action:"update", file_path:".gitlab-ci.yml", content:$content}]}' > commit.json
glab api -X POST "projects/${PROJ}/repository/commits" -H "Content-Type: application/json" --input commit.json
glab api -X POST "projects/${PROJ}/merge_requests" -f "source_branch=${BRANCH}" \
  -f "target_branch=main" -f "title=${MSG}" -f "remove_source_branch=true" -f "description=..."
```

Commit msg must pass org lint: `type(scope): COEXT-000 - msg` (types `feat|fix|chore|docs|refactor|test`; `ci` NOT a valid type — use `fix(ci)`/`chore(ci)`).

## Traps (each one burned a real session)

| Trap | Symptom | Fix |
|------|---------|-----|
| **zsh no word-split** | `for e in $LIST` loops ONCE with whole string → mangled `${e##*:}` → 404s that look like auth/sandbox failures | Literal quoted lists `for e in "a:1" "b:2"`, arrays, or `while read` |
| **glab host from cwd** | Same command works in repo dir, `404 Project Not Found` from /tmp (falls back to gitlab.com) | `export GITLAB_HOST=<internal>` in every script |
| **GitHub anon rate limit** | N parallel pipelines → tflint plugin install `403 API rate limit exceeded` (60 req/hr/runner-IP); ~12 at once guarantees it | Expected on launch; retry FAILED JOBS (`POST /jobs/:id/retry`, returns new job id — verify it) staggered 45-60s AFTER `rate reset in Xm` from trace; last-in-queue may need a second round |
| **Patching with regex/sed** | Silent wrong edit on drifted file | python exact-string replace + `assert count == 1` |
| **Pre-existing red repos** | One repo fails for unrelated reasons (e.g. job-token module fetch) | Diagnose from trace BEFORE blaming your change; see skill `unblocking-job-token-module-fetch` |

## Verify + merge

- Poll MR `head_pipeline.status` (not branch pipelines) until terminal.
- Mass auto-merge (`merge_when_pipeline_succeeds` across the fleet) is a policy-gated escalation — open MRs, report list, let human merge.
- Module repos: `publish_release` is `when: manual` — after merge, PLAY it (`POST /jobs/:id/play`); semantic-release usually works, manual tag fallback only on EGITNOPERMISSION.

## When NOT to use

- Change differs per repo → per-repo MRs by hand or copier update.
- Multi-file/templated change → bump the copier template + `copier update` per repo instead.
