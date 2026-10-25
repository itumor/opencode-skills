---
name: mr-bot-feedback-loop
description: Use after EVERY push to a GitLab MR branch, MR open, or rebase, in any repo where PR-Agent posts. Covers waiting for the "PR Reviewer Guide" and "PR Code Suggestions" notes (and Atlantis where atlantis.yaml exists), reading them in full, and then fixing each item or answering it with evidence. Also use when the user says "check the PR-Agent comments", "read the reviewer guide / code suggestions", "address bot feedback".
---

# MR bot feedback loop (PR-Agent + Atlantis)

User rule (2026-10-19, global): a push is not finished until PR-Agent's **PR Reviewer Guide** and **PR Code Suggestions** for the current head SHA have been read and every item is either **fixed** or **answered with evidence**. Atlantis plan notes are handled the same way where the repo has `atlantis.yaml`.

## 0. Automatic (iac harness, since 2026-10-19)
Hook `harness/iac/hooks/push-feedback.sh` starts the step-1 watcher by itself on every agent `git push`, every
user `!` push (UserPromptSubmit `<bash-input>`), and every MR create. It returns the log + dump paths as context.
The Stop hook blocks once per watcher result that is not all-pass until `touch <record>.ack` (do steps 2-4 first).
Records: `.claude/state/push-fb/<session8>/`. Escape: `HARNESS_SKIP_PUSHFB=1`. Manual step 1 stays the fallback
(outside the iac harness, or when the context says "no open MR yet").

## 1. Wait (background, after the push lands)
```bash
python3 ~/.claude/scripts/mr-feedback.py watch --repo <repo-or-worktree> --iid <IID> --key <TICKET> \
  --sources atlantis,pr-agent,pr-agent-improve --timeout-min 20 --dump <scratchpad>/fb-<IID>
```
- Run with `run_in_background`; do other work, then read the result.
- It binds feedback to the **current head SHA** (versions API), so notes from before the push don't count. It trusts only the bot authors `project_<pid>_bot_*` and `pnt_terraform_build`.
- Drop `atlantis` from `--sources` when there is no `atlantis.yaml` (the script does this itself).
- **Repo without PR-Agent:** if no recent MR in the project has a `project_<pid>_bot_*` note, the watch would only time out. Pass `--sources atlantis` (or skip) and say "PR-Agent not onboarded" in the hand-back. Onboarding is skill `pr-agent-repo-onboarding`, a separate ask.
- `TIMED_OUT` = no feedback. Say so; never report "bot happy" without notes.

## 2. Read in full
Read every dumped file (`<src>-<note>.md`). For the Reviewer Guide, also read "Requires further human verification" and the ticket-compliance list, not just the headline.

## 3. Triage each item
| Verdict | When | Action |
|---|---|---|
| **fix** | correct and in scope | edit, re-verify (render/plan/tests), commit, push, back to step 1 (new SHA) |
| **reject** | wrong, or would break something | reply on the MR with **evidence** (render output, plan line, doc link): one short note per item |
| **verify** | a "human verification" ask the agent can check live | check it read-only, then reply with the evidence |
| **human** | needs the user's decision, out of scope, or touches security posture | list it in the hand-back; no change |

- Evidence beats opinion: a suggestion that contradicts a render or plan you produced is rejected **with that output**. Example: PR-Agent called `limits.cpu: null` invalid on argocd !506. In Helm, `null` deletes the inherited key, the render showed no CPU limit, and removing the line would re-enable the chart default `800m`, so it was rejected with the render.
- Repair cap: 2 fix rounds per MR (the script tracks it). After that, hand the open items to the user.
- Scope rule still applies: no unrelated fixes because a bot suggested them.

## 4. Replies
- Allowed (user 2026-10-19): post reply notes on **your own MR** answering bot items. Caveman-full style, one note per item, evidence quoted.
- Never: resolve discussions, approve, merge, apply via Atlantis, or edit the bot's notes.

## 5. Hand-back table (always)
`| Source | Item | Verdict | Evidence / commit |` plus the line `PR-Agent: <n> items, <fixed> fixed, <rejected> rejected, <human> for you` and the head SHA the notes belong to.

## Gotchas seen (2026-10-19/20)
- PR-Agent ticket compliance overclaims: on argocd !527 it said "Fully compliant" incl. "components/ MR second" + "cutover plan" that were NOT done. Never forward its verdict as sign-off; post a correction note naming what is not done and where the doc says so.
- No pipeline is not a failure in repos whose `workflow:` rules use `changes:` (argocd/argocd skips docs-only MRs): check `merge_requests/<iid>/pipelines` = [] + `detailed_merge_status: mergeable`, say so on the MR, and do not wait for one (a poll loop will just time out).
