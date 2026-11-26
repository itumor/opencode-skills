---
name: mr-human-review-gate
description: Use when AI-generated or AI-assisted code or IaC changes are about to go to other people - before `glab mr create`, before undrafting an MR, before assigning or pinging a reviewer, before saying "ready for review" or delivering a solution - and when Ebrahim says "open the MR", "ship it", "looks good, push it", "I'm in a hurry, just open it", "self-review", "review my changes before the MR". Applies even when scanners, CI and the review bot are green.
---

# MR human-review gate

AI wrote it, Ebrahim owns it. Scanners, CI and PR-Agent check rules; they do not judge
whether the change is the right one. That judgment is his, and Claude cannot do it for him.
Claude's job: make the diff small, show where judgment is needed, then wait.

**No reviewer is assigned and no MR is undrafted until Ebrahim replies `reviewed`.**
A hurry, "looks good", or green scanners are not that reply.

## Steps

1. **Diff.** `git -C <repo> diff origin/<default>...HEAD` (stat + full). Read all of it.
2. **Trim.** Remove everything the ticket did not ask for, then re-run the tests:
   - variables, flags, locals and outputs nothing uses today ("for later")
   - permissions wider than the ask (wildcards, write when the ask is read)
   - comments that restate the code, debug leftovers, unrelated formatting
   - a second way to do something the repo already does one way
   Note the diff size before and after.
3. **Test.** Run what is relevant (skill `verify-iac-changes`, repo CI locally, plan, unit tests).
   Write the command and the result. Not run = `NOT RUN: <reason>`, never silence.
4. **Review sheet.** Output exactly this, 25 lines max:

   ```text
   REVIEW SHEET  <repo>  <branch>  <KEY>
   Ask -> diff:   <each acceptance point> -> <file:line> | NOT COVERED
   Size:          <N files, +a/-b>  (before trim +c/-d; removed: <what>)
   Read first:    <file:line> - <what a human must decide>      (max 5, riskiest first)
   Security:      <IAM / SG / secrets / public exposure touched: file:line> | none
   Architecture:  <new pattern, module or dependency vs how the repo does it> | follows existing
   Edge cases:    checked: <...>   not checked: <...>
   Tests:         <cmd> -> <result>   NOT RUN: <...>
   AI guessed:    <values or assumptions with no evidence: account IDs, names, defaults> | none
   ```
5. **Stop.** Ask: `Read the diff and the sheet. Reply "reviewed" or tell me what to change.`
6. **After `reviewed`:** open or undraft the MR (description: skill `terse-mr-descriptions`),
   add `Self-review: author read full diff. Tested: <cmds>.` Write that line only after his reply.

## Before the diff: is the branch base right?

- `git -C <repo> fetch --prune origin`, then check any MR you believe exists: `glab api projects/<id>/merge_requests/<iid>`
  (state, merged_at). A memory note or `ahead 1` of a tracking ref is not proof (2026-11-24: "open MR !52" had been
  squash-merged a week earlier; the ref was stale because the fetch did not prune).
- The sheet uses the three-dot diff (`origin/<default>...HEAD`), which is what GitLab shows. If it is larger than the
  change (a 2-line edit showed 669 lines), the branch still carries a squash-merged MR: `git switch -c <new> origin/<default>`,
  cherry-pick the commit, push with an explicit refspec, and review that branch instead.

## If the repo has NO Atlantis and no CI (e.g. `feature-validation/terraform`)

- Run the plan yourself, read-only, as evidence for the sheet: `terraform plan ... -lock=false -input=false`, output to a
  scratch file, never `-out`. Put `N add / N change / N destroy` under `Tests`.
- Tag every planned change MR-caused or environment-carried. Carried changes (addon version bumps on a shared cluster)
  go under `Read first` with the choice: full apply, or `-target` on the MR's own resources.
- **Do not write the apply command in the sheet message.** Single-line `bash` blocks get a Run button and it was clicked
  before the MR existed. The command (absolute paths, `terraform -chdir=...`) comes only after `approved:true` on the
  current head, with the `Approval:` / `Cost:` / `Disruption:` lines.

## If the repo has `atlantis.yaml`

**Check first that this Atlantis plans drafts.** On `vending-test/terraform` !8 (bot `pnt_terraform_build`,
2026-11-12) a `Draft:` MR got no autoplan; the plan came within a minute of removing the prefix. If no plan
note or `atlantis/plan` status shows up after ~2 minutes: remove `Draft:`, keep **no reviewer**, read the plan,
and assign the reviewer only after `reviewed`. The gate is the missing reviewer, not the Draft flag.

The plan is evidence for the review. Open the MR as **Draft, no reviewer**, let Atlantis plan,
put the plan summary (add / change / destroy, anything unexpected) on the sheet under `Tests`.
The gate then sits before undraft and reviewer assignment.

## If he is short on time

Give the sheet anyway and say: `2 minutes to read. MR stays draft / unopened until "reviewed".`
Then stop. The MR waiting an hour costs less than a reviewer finding what he did not read.

"Give me the MR" after the sheet, without `reviewed` (2026-11-24, pto-reference/ansible !13): open it as
**Draft, no reviewer**, also in a repo without Atlantis, and say the gate now sits at undraft. He may merge
the draft himself; that is his act. Verify `state: merged` by API, then carry on. No self-review line was
written on that MR, and none is added after the fact.

## Not a review

| Thought | Reality |
|---|---|
| "Scanners are green" | They check rules, not whether the change fits the ask. |
| "PR-Agent will review it" | A bot reviewing AI code is zero humans. |
| "He said looks good" | That is not `reviewed` after reading the sheet. |
| "Diff is tiny" | Then the sheet takes 30 seconds. |
| "Reviewer will catch it" | The reviewer's time is what this gate protects. |
