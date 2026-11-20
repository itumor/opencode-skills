---
name: council-review-evidence-pack
description: Use when Council Mode is on (mcp__council__review) and the work to judge is a code or MR review, a diff, or live facts (CI status, pipelines, SHAs). Builds the plain-file evidence pack the blind reviewers can actually read, because they have only Read/Grep/Glob and no git or network.
---

# Council evidence pack

Council reviewers are 3 fresh blind agents (security, correctness, reliability) with Read/Grep/Glob only. They cannot run git, glab, terraform or curl, and their checkout may be on another branch. Anything not in a readable file is "unverified" and scores low.

## Build the pack BEFORE the first `mcp__council__review`
Folder: `<scratchpad>/council/` (absolute path in `artifacts`).
1. `mrNN.diff` per unit, `fixes-*.diff` for fix commits only (`git diff <old-head> <new-head>`). Big diffs: reviewers only grep them, so also add:
2. Head-version copies of the key files: `git show <sha>:<path> > council/<name>`. Quote path names that contain `[% yield %]`.
3. `CHECKS.txt`: live facts you fetched (pipeline ids + job list + status, head SHA == diff_refs.head_sha, mergeable, gitleaks result, required_version, what CI really runs and the script that does it, copied in). Say what was NOT run (no local plan).
4. `REVIEW.md`: the verdict being judged, <=15 lines: verdict, heads, table `claim | where to verify | status`, limits. Reviewers judge a verdict, not a pile of evidence.
5. Secret-looking values: a display scrubber can show a Secrets Manager name as `[REDACTED:...]`. Put `xxd` of the committed line in `*_hexdump.txt` and say so in the criteria.

## Rules for the call
- `criteria`: numbered, checkable, each pointing at a file. No words earlier/previous/round/score/target (tool rejects: reviewers must stay blind). The `LEAK` regex in `council-mod/hooks/gate.ts` also rejects `N/10`, `round N`, `target N`, and `score` followed by a digit, so "score 0-10" in criteria for council-mod itself gets denied: write "the 0-to-10 range" or point at the file line instead.
- `checks`: only commands you really ran, with results. Never claim a check you did not run.
- Re-submit the WHOLE pack each round; add new evidence to CHECKS.txt, do not mention rounds.
- The reliability lens may sit near 0.8-0.9 with only low findings when no `terraform plan` ran. After the budget (5 rounds) report NEEDS HUMAN DECISION with scores, unresolved findings and limits. Never claim success.

## Approval is the user's act
Harness hook R2 denies approving an MR (CE self-approval satisfies Atlantis). Hand back MR links + head SHAs; user approves. Verify afterwards read-only: `glab api projects/<id>/merge_requests/<iid>/approvals` -> `approved:true`.

Reference run: template/client !58/!59/!60 (GENESIS-432129), 2026-11-17. Memory: feedback_council_reviewers_need_evidence_pack_files.
