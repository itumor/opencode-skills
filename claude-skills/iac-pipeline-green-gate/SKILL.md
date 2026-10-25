---
name: iac-pipeline-green-gate
description: >-
  Use after opening, pushing, rebasing or updating ANY GitLab MR in an EIS iac repo, and BEFORE saying
  "ready", asking for review, or handing back an `atlantis apply`: the MR pipeline must be GREEN in ALL
  stages and jobs (GitLab says `mergeable`, not `ci_must_pass`). Also use when the user pastes a failed
  job URL, says "pipeline failed", "make sure the pipeline is green", "job NNN failed", or when Atlantis
  plans fine but CI is red. Reference: pto-reference !50 (GENESIS-425582), job 2599038, 2026-10-16.
---

# Pipeline must be green, all stages

**Rule.** An MR is not "ready" until its newest pipeline shows every job `success` and the MR reports
`detailed_merge_status: mergeable`. Green Atlantis plan, green local `gitlab-ci-local`, or "only a known
local failure" do NOT count. Never hand back an apply, ask for merge, or say "done" on a red or still-running
pipeline. Same for unread bot feedback: PR-Agent Reviewer Guide + Code Suggestions for the head SHA must be read and
triaged first (skill `mr-bot-feedback-loop`). Name the pipeline id and job ids in the hand-back.

## Loop (repeat until green)
```bash
export GITLAB_HOST=sfo-cvdevopsgit01.eqxdev.exigengroup.com; unset GITLAB_TOKEN   # stale env token overrides glab
P="projects/<url-encoded group%2Frepo>"
glab api "$P/merge_requests/<IID>" | jq '{sha,detailed_merge_status,pipe:.head_pipeline.status,id:.head_pipeline.id}'
glab api "$P/pipelines/<PID>/jobs" | jq -r '.[]|"\(.stage) \(.name) \(.status) \(.id)"'
glab api "$P/jobs/<JOBID>/trace" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\r' > job.log   # file, never echo/$VAR
grep -n -E '\.{6,}(Passed|Failed|Skipped)' job.log        # per-hook result in pre-commit jobs
```
Read the actual error text of EVERY failed hook before touching anything. Fix the cause, push, wait for the NEW
pipeline (new sha), re-check. Poll with a loop that matches the real terminal values (`success|failed|canceled`;
`rebase_in_progress` is `None`, not `False`).

## Known causes (check these first)
| Symptom in the job log | Cause | Fix |
|---|---|---|
| `terraform_validate` + `terraform_providers_lock` "files were modified by this hook", provider version in `.terraform.lock.hcl` changed (e.g. aws 6.68.0 -> 6.69.1) | CI runs `terraform init -upgrade`; a new provider release lands; branch is behind main and lacks the exact-version pin in `versions.tf` (pto-reference !49 added `hashicorp/aws = 6.68.0`) | Rebase the MR onto main (server-side: `glab api -X PUT $P/merge_requests/<IID>/rebase`, no force-push). Do NOT commit the `-upgrade` lock churn (rejected before, see memory). Fix at the source = pin the provider exact in `versions.tf` |
| `pre-commit: error: argument command: invalid choice: 'sh'` | image ENTRYPOINT is `pre-commit` | `entrypoint: [""]` in the CI image block (local `gitlab-ci-local` only; real runner passes) |
| `Authentication by CI/CD job token not allowed from X to <module>` / `Failed to download module` 403 | per-module job-token inbound allowlist | skill `unblocking-job-token-module-fetch` |
| `terraform fmt`, `tflint`, `checkov` Failed | real code finding | fix the code, re-run locally with own creds (`terraform init -backend=false`, validate, tflint, `checkov --config-file <repo>/.checkov.yaml`) |
| argocd/argocd: `registry.scaleops.com` 401 in `render_manifests*` | credential only in real CI | judge by `[RENDER] <your-release>` having no `[ERROR]`; real CI must still be green |

## Rules
- A job that is `allow_failure: true` and red is still red: report it; do not call the pipeline green.
- After ANY push or rebase, Atlantis autoplans the new head and replaces saved plans (including a targeted
  plan). Re-run the exact targeted plan, re-read it, only then hand back the apply.
- Local `gitlab-ci-local` is a pre-push gate, not a substitute: its validate/tflint hooks always fail without a
  job token. The real MR pipeline is the gate.
- Never merge or apply on the user's behalf; hand back with: pipeline id = success, merge status = mergeable,
  plan summary, disruption line.
- Do not retry a red job blindly. A retry is only valid after a cause is identified (flaky runner, token
  race) and written down.

## Hand-back line
`Pipeline #<id> success (all <n> jobs), MR mergeable, head <sha7>. PR-Agent: <n> items, <f> fixed, <r> rejected, <h> for you.`
