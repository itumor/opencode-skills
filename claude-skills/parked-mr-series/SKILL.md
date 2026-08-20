---
name: parked-mr-series
description: Ship a batch of independent deliverables as one branch + one never-merged MR each, on a repo whose working tree must stay dirty, surviving a mid-run VPN/DNS drop. Use when the user says "one MR per task", "create the branches and MRs but don't merge", "park this for review", "the owner will merge when they're back", when fanning a backlog/task list out into many small review-ready MRs, or when a batch push half-failed and you need an idempotent resume. Covers the stage-locally-then-publish split, the glab MR-create + reviewer_ids traps, the dirty-file checkout trap that silently commits to main, and the mechanical per-doc verification pass.
---

# Parked MR series

One branch + one MR per deliverable, **nothing merged**, on a repo where `main` must end the run
exactly where it started and an intentionally-uncommitted file must survive in the working tree.

Built on a 15-MR run against `caa-architecture-ai` (2026-08-18). The hard-won part is not the git
commands — it is separating *staging* from *publishing* so a network drop costs nothing, and
asserting after every step that no work leaked onto `main`.

## When this applies

- The user wants review-ready work parked: "create MRs but don't merge", an absent owner decides.
- A task list fans out into many small, independent MRs (docs, per-service configs, per-module bumps).
- The repo has an intentionally-dirty working tree (a scratch/plan file the user keeps uncommitted).
- A prior batch half-published and you need to resume without duplicating MRs.

Do **not** use it for a single MR, or for anything you intend to merge in the same session.

## Rule zero

**Never merge.** No `glab mr merge`, no `--remove-source-branch`, no auto-merge flag, not even on
a green pipeline. If asked to "finish" the series, that means every MR is open, reviewed-ready and
listed back to the user — not merged.

## Shape: two planes

1. **Content plane** — produce every deliverable into a scratch directory first, mirroring the
   repo-relative paths (`$SCRATCH/drafts/<repo/relative/path>`). Nothing touches the repo yet.
   Parallelise freely here; subagents write files and return nothing but paths.
2. **Git plane** — strictly sequential, one checkout, `main` never advances.
   - `stage()` — branch from `main`, copy the drafts in, commit. **No push.** Append the MR
     title/description to a queue file.
   - `publish()` — for every queued entry without an `mr_iid`: push, create the MR, set
     reviewer/assignee, record the iid back into the queue. Idempotent: safe to re-run after a
     failure, skips what already has an iid.

That split is what makes a VPN drop mid-run a non-event: keep staging offline, publish when the
network returns. `references/mkmr.py` is a working implementation — copy it, adjust the constants
at the top (repo path, project id, reviewer id, scratch dir).

## The five traps

1. **`glab mr create` needs the repo as cwd.** Elsewhere it dies `No git remotes found` even with
   `-R owner/repo` and a correct `GITLAB_HOST`. Use `glab api projects/<id>/merge_requests -X POST`
   — no cwd dependency, and it works when the git remote's hostname is a CNAME glab doesn't know.
2. **`reviewer_ids` is silently dropped by `-f`/`-F`.** The MR opens with `reviewers: []` and
   returns 201, no error; the follow-up `PUT -F "reviewer_ids[]=<id>"` then 400s with "at least one
   parameter must be provided". Only a raw JSON body works — see `references/mkmr.py`. `assignee_id`
   (scalar) does survive `-f`. **Assert `reviewers` in the response every time.**
3. **A dirty file blocks `git checkout`, and the rest of the script keeps going.** `checkout` aborts
   with "Your local changes would be overwritten", the subsequent edit+commit then lands on
   whatever branch you were on — usually `main`. Guards: `set -e`, and assert
   `git branch --show-current` immediately after every checkout. Recovery when it happens: re-apply
   the change on the intended branch, `git checkout main && git reset --hard origin/main`, then
   restore the dirty file with `git checkout <branch> -- <file> && git restore --staged <file>`.
4. **Never `git add -A` / `commit -a`.** The dirty file leaks into an unrelated MR. Stage explicit
   paths, then assert `git diff --cached --name-only` equals the intended list — `mkmr.py` does.
5. **Collisions across never-merged branches.** Because `main` never advances, two branches editing
   the same file produce divergent versions nobody reconciles. Give each shared file exactly one
   owning MR, and allocate any sequential filenames (`07-`, `08-`, …) centrally *before* fanning
   out — parallel workers otherwise claim the same number.

## Bootstrapping a dirty file

When the uncommitted file is itself a deliverable (a plan, a status table), make it MR #1 and put
the working tree back afterwards:

```bash
git checkout -b <branch>            # the dirty change rides along
git add <file> && git commit -m "..." && git push -u origin <branch>
# create MR, then:
git checkout main
git checkout <branch> -- <file> && git restore --staged <file>   # dirty again, as the user had it
```

Later updates to that file (e.g. a final status sweep) **stack onto that same branch** and re-push —
MR #1 updates in place. Do not open a second MR for it.

## Verification before you report

Mechanical, per deliverable — a short Python pass beats eyeballing twenty files
(`references/verify.py` — `python3 references/verify.py <drafts-dir>`, exits non-zero on findings):

- Repo conventions: required header lines, section numbering, line-count band.
- **Every ID/reference claimed in a header appears in the body.** On the reference run, 2 of 20 docs
  cited requirement IDs they never used. Cheapest high-value check there is.
- Forbidden content: code blocks the repo bans, caveat phrasing, any name the user told you not to
  mention (scan only *changed* files — a tree-wide grep drowns in pre-existing hits).
- Structural: balanced mermaid `subgraph`/`end`, brackets, quotes.
- Twin/mirror files: `grep '^## '` on each and diff the skeletons.

Then per MR: `git diff --name-only origin/main..<branch>` equals the intended files; one commit
(or the known count); and via the API — `state == opened`, reviewer and assignee correct,
`target_branch == main`. Finally assert the whole set: N MRs, **zero merged**, and
`git rev-parse HEAD` on `main` still equals `origin/main`.

Fix findings by `commit --amend` on the affected branch **before** publishing; after publishing,
push a follow-up commit instead.

## Reporting back

A table of MR links with task and deliverable, then three things the user cannot see from the links:
what you deliberately **excluded** and why, findings you **surfaced rather than patched** (stale
lines in already-closed work belong to their own task), and what stays **blocked on which party**.
State plainly that nothing is merged and that `main` is untouched.
