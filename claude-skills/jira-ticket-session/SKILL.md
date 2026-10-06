---
name: jira-ticket-session
description: Use when a session is started for ONE assigned Jira ticket (spawned by the scheduled task jira-ticket-dispatcher, or the user says "work ticket KEY" / "pick up KEY" / "close out KEY"). Runs the per-ticket loop - read, move status, work up to the human gates, end-to-end verify, verdict, ledger time, paste-ready Jira draft. Never posts Jira comments.
---

# One ticket, one session

Input: ticket KEY (e.g. COEXT-110747). Start in `~/gitwork/iac` so the harness is active. Hard rules in the root CLAUDE.md stay: no `atlantis apply`, no merge, no push past the guard, **no Jira comments/Slack** (drafts only).

Jira writes allowed here = transitions + local time ledger, ONLY through `~/.claude/scripts/jira-ticket-ops.py` (never raw curl POST: R12 denies it).

State dir: `~/.claude/change-runs/jira-routine/`. Files: `KEY.md` (state), `KEY.evidence.md` (raw proof), `KEY.draft.md` (Jira comment draft).

## Loop
1. **Start clock + read.** `date +%s` into `KEY.md` (`started:`). Read the ticket: `python3 ~/.claude/scripts/jira-read.py KEY`. Read `KEY.md` if it exists (resume), grep memory/qmd for the key, list linked MRs (`glab` inside the nested repo, `GITLAB_HOST` per CLAUDE.md). Name the routed skill from the root CLAUDE.md table on line 1 of your reply.
2. **Move to working state** if status is Open/To Do/Reopened: `jira-ticket-ops.py transitions KEY`, then `jira-ticket-ops.py transition KEY "In Development"` (GENESIS) or `"Start Progress"` (COEXT). Re-run `transitions` after every change: ids are per-project (see skill `eis-jira-rest-ops`). Already In Progress/In Development: leave it.
3. **Work** everything that needs no human gate: code, local CI (`gitlab-ci-local`), MR open, plan read. Multi-gate work follows skill `iac-change-loop` (gate sheet + watcher + state file). Stop at each gate with the exact commands for the user.
4. **End-to-end verify before ANY "done".** Live evidence, not source/MR count: use agent `iac-live-verifier` (AWS/EKS/GitLab state) and skill `eis-onesuite-e2e-verify` for OneSuite envs. Paste raw command output into `KEY.evidence.md`, one block per acceptance criterion. Then spot-check every "zero/not found" yourself.
5. **Verdict** (exactly one, in `KEY.md`):
   - `DONE`: every acceptance criterion proven live, all linked MRs merged AND applied, no gate left. Add the line `E2E: PASS` to `KEY.evidence.md`, then resolve: `jira-ticket-ops.py transition KEY Resolved --evidence ~/.claude/change-runs/jira-routine/KEY.evidence.md` (COEXT: from In Clarification chain `Clarify`->Reopened->Resolve per `eis-jira-rest-ops`; GENESIS Close can 400 for Story Points/Primary Client: do not guess values, hand the user the close payload instead). The script refuses without the evidence marker.
   - `IN-PROGRESS`: work continues, status stays In Progress/In Development.
   - `BLOCKED-ON-USER`: only a human gate remains (apply, merge, approval, VPN/SSO login). State which. Status stays.
   - `NOT-DONE`: E2E failed or criteria unproven. Never write `E2E: PASS`. Say what failed.
   Never write `E2E: PASS` to get a transition through.
6. **Time.** Elapsed minutes = `(now - started)/60`, minus obvious idle waits. `python3 ~/.claude/scripts/jira-ticket-ops.py ledger KEY <minutes> "<what was done, <=80 chars>"`. The 18:00 `log-time-to-jira` task posts the day's worklogs from this ledger, capped at 8h. Do not post worklogs yourself.
7. **Draft** `KEY.draft.md`: Jira wiki markup, caveman full (no articles/filler, status on first line, IDs/URLs exact). Sections: Status, Done (with evidence pointers), Remaining/gates, Next. Also give it as ONE fenced block in your final reply. The user posts it.
8. **State.** Update `KEY.md`: verdict, last action, `next action:` (single line, replace not append), evidence path, ledger minutes.

## Final reply shape
`KEY | verdict | Jira status now` / what changed (one line each, with evidence) / user gates with exact commands / draft block. Ticket not worth more than one session's effort? Say so in one line; do not pad.
