---
name: iac-change-loop
description: >-
  Use for ANY multi-step infra change that crosses human gates (push, atlantis apply, merge, Jira post, Slack
  approval): the agent runs a closed loop around the gates instead of waiting for the user to type "applied, verify,
  next step". Protocol = state file + gate sheet + watcher + auto-verify + failure table + defaults. Use at the
  start of a ticket with more than one apply, when the user says "loop", "do the next step", "stop asking me", or
  when you are about to write "tell me when it's applied". Reference: COEXT-108169 (6 apply/verify cycles, ~10
  gate inputs the user had to type that a loop removes).
---

# Closed loop around human gates

Hard rules stay: the agent never applies, merges, pushes (guard) or posts to Jira/Slack. The loop automates everything BETWEEN gates and makes each gate one cheap action for the user.

## The loop (per step)
1. **Do** all non-gated work (code, local CI, MR open, plan read). Cite evidence.
2. **Hand off one gate sheet** (not prose): ordered steps for the user with exact commands, expected result, `Disruption:` line (hook `handoff-gate.sh` blocks an apply handoff without it). For several gates write `~/.claude/change-runs/<ticket>.gates.sh` sourcing `~/.claude/scripts/gates-lib.sh` (`gate`, `gate_mr_merge`, `gate_atlantis`; y/N per gate, user runs it in their own terminal; the agent never runs it).
3. **Arm the watcher in the same turn**, `run_in_background`:
   `~/.claude/scripts/gate-watch.sh mr-note <repo> <iid> 'Ran Apply' <since-utc>` | `mr-merged <repo> <iid>...` | `domain <d> <profile> <region> <OpenSearch_X.Y>`.
4. **On the watcher result, verify and continue without being asked**: run the verify commands for that service, diff against the before-state, write evidence to the state file, prepare the next step (branch, CI-local, MR), hand off the next sheet. Stop only at the next gate.
5. **Update `~/.claude/change-runs/<ticket>.md`** after each step (template below) so a new session resumes from it. Tick the step `[x]` and REPLACE the single `next action:` line (never append a second one): `/next` (next-pane mod) reads exactly these; unticked steps showed COEXT-110747 as 0/7 after T1-T3 were done.

## State file template
```
# <TICKET> change run
goal: ...            approvals: <who/when/what>
steps: [ ] id | what | gate(user/none) | evidence | status
next action: ...
before-state: <path to snapshot>
failures seen: <error> -> <what fixed it>
```

## Failure table (retry once, then escalate with exact text)
| Signal | Action |
|---|---|
| Atlantis `Plan Failed: locked by ... !N` | holder MR open+applied -> ask user to merge it; merged/closed -> skill `atlantis-lock-troubleshooting`. The lock can pass to the NEXT open MR planned on the same dir (CAA stage services went !174 -> !183 -> !186 in one day): re-read the holder from the fresh note each time, then rebase + replan once it merges |
| Apply `unexpected state 'FAILED'` on OpenSearch upgrade, domain unchanged | `check-only` again; fresh `atlantis plan` then apply once at a quiet time; if it repeats, console "View details" code (skill `eis-opensearch-engine-upgrade`) |
| pre-push `exceeded 100s` | run `ci-local-scratch.sh`, give the user the exact `git -C <wt> push` |
| Atlantis plan has extra changes/destroys | stop, tag MR-caused vs carried (CLAUDE.md rule 4), do not hand off apply. After a rebase, a `for_each`-wide attribute also hits entries other MRs added (COEXT-110321: expected 2 distributions, plan showed 4 incl. the `.pt` portals; fixed with `contains([...], each.key) ? x : null`) |
| MR `pre-commit` CI job red with `early EOF` / `SSL_read: unexpected eof` on a module `git clone` | transient runner network: `glab api -X POST projects/<id>/jobs/<job>/retry`, watch the NEW job id; only dig in if it fails twice |
| own Monitor/`glab api` poll loop times out silent while the event already happened | do not hand-roll it: use `gate-watch.sh mr-note <repo> <iid> 'Ran Plan' <since-utc>`. The hand-rolled loop piped `echo "$body"` into python under zsh (echo expands `\\n` in JSON strings -> invalid JSON) with errors swallowed by `2>/dev/null`, so a 2-minute plan was missed twice (10-min timeouts). Check the MR notes directly before re-arming |
| SSO expired | ask user for `aws sso login --profile <p>` (only thing the loop cannot do) |
| watcher timeout | report state with one command, do not poll in a tight loop |

## Defaults instead of questions
If a sensible default exists, take it and write `Assumed: X` in the reply and state file. Ask only if the answer changes cost, customer impact, scope or is irreversible. Questions this removes: scope/order, window (use `iac-apply-disruption-check` + owner approval pattern), branch/MR naming, which profile.

## Answers
User asks yes/no -> first word is Yes or No, then one line why, with evidence.
