---
name: autoapprove-demo-session
description: Use when recording (or re-recording) a promo/demo video of AutoApprove auto-approving Claude Code desktop prompts, or when asked to "run a demo task", "give the demo session something to do", "show plan approval + tool prompts being auto-approved". Recipe for a throwaway worktree side session doing tiny visual tasks in hook/autoapprove.py.
---

# AutoApprove demo session (screen recording)

Goal: on camera, a Claude Code desktop session hits plan-approval + Bash/Edit prompts and AutoApprove clicks/approves them. Task content is filler; prompts are the show.

## Setup
- Side session on a throwaway worktree branch (e.g. `claude/demo-*`); never merge, never push.
- Repo-only: no other projects, company names, credentials, files outside repo. Shown on screen.
- Own window, Do Not Disturb on, AutoApprove.app running (fresh heartbeat; hook fails closed otherwise) and Accessibility granted to the clicker.

## Task shape (one per take)
Brief the session like:
> Add a `--<flag>` flag to `hook/autoapprove.py` that <prints X> and exits 0. Short plan first (ExitPlanMode), then implement, run `python3 hook/autoapprove.py --<flag>` and `--selftest` as two separate Bash calls, then commit. Keep replies short.

- Plan mode -> ExitPlanMode = plan-approval card for the clicker.
- Edit + separate Bash calls = several tool prompts for hook.
- Flags go in the `if/elif` chain in `__main__`; `--selftest` is the only test. Keep diff a few lines.

Used already (branch `claude/demo-version-flag-b219ad`): `--version`, `--help`, `--log-path`. Fresh ideas: `--state-path`, `--status` (print enabled/heartbeat age), `--dry-run` on stdin payload.

## Watch for
- Clicker pressed plan "Accept" / "Always allow" in OTHER sessions unrequested before: keep only the demo session with pending prompts during recording.
- Throwaway work never lands on main; cherry-pick deliberately if wanted.
