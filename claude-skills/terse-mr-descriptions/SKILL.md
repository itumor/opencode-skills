---
name: terse-mr-descriptions
description: Use when writing an MR description, commit message body, bugfix summary, or chat reply about a code/IaC change for the team to review. Triggers on "fix", "bugfix", "MR", "merge request", "what changed", or any response describing a change you just made. Keeps the reply to fix + one-line reason — no paragraphs of reasoning, tradeoff discussion, or narrated exploration unless the reader asks for it.
---

# Terse MR/Bugfix Descriptions

## Why

Team feedback (2026-09-07): multi-paragraph reasoning in front of a simple
bugfix makes MRs hard to review — reviewer has to read past the reasoning to
find the actual reason for the change. See
[[feedback_terse_mr_bugfix_replies]] in memory.

## Rule

For a simple bugfix/MR, give:

```text
<what changed>
<one-line why>
```

Nothing else, unless the reader has follow-up questions — then answer those
when asked, not preemptively.

## When NOT to compress

- The change is genuinely complex/high-risk and the reasoning IS the review
  (e.g. a Terraform plan with hidden blast radius, a drift call like
  [[eis_iac_core_drift_warning]]) — there the "why" is load-bearing, keep it.
- The user explicitly asked for a walkthrough, report, or per-phase notes.
- Security-relevant or destructive changes where the reviewer needs the
  reasoning to approve safely.

## Red flags — rewrite before sending

- More than ~3 sentences of prose before or after the diff/fix
- Explaining alternatives you didn't take
- Narrating the investigation ("I first checked X, then looked at Y, then
  realized Z...") instead of just stating the root cause
- Restating what the code already shows (well-named diffs don't need a
  paragraph of "what")

## Example

❌
> I dug into the failing pipeline and found that the commit-msg lint step
> runs `git rev-list` without excluding merge commits. Since merge commits
> don't follow conventional-commit format, this causes the lint job to fail
> whenever a merge lands on main. I considered disabling the lint job
> entirely but that would remove a useful guardrail, so instead I added the
> `--no-merges` flag to the git rev-list invocation, which is the same fix
> already applied upstream in the client template...

✅
> Added `--no-merges` to the commit-lint git rev-list in `.gitlab-ci.yml` —
> merge commits don't follow conventional format and were failing main.
