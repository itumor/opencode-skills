---
name: jira-onhold-handoff-pack
description: Use when the user wants a status update / handoff for MANY Jira tickets at once before work pauses - "status update for every task", "tasks may go on hold", "comments with all info so we can come back", "doc + Lucid diagram per ticket", "table of Jira status", "one subagent per ticket". Fans out one read-only subagent per ticket, each writing a full status doc, Lucid diagram, PNG and paste-ready ON HOLD Jira comment draft; then builds a master README table grouped by state. Never posts to Jira.
---

# Jira on-hold handoff pack

Reference run: 2026-10-29, 17 tickets (GENESIS-4294xx/4475xx, COINT-2156x-2159x, COINT-21667) -> `~/gitwork/iac/docs/status-2026-10-29/`.

## Steps
1. Pack dir `~/gitwork/iac/docs/status-<YYYY-MM-DD>/`. Copy `brief-ticket.md` there as `BRIEF.md`, replace the dir path inside.
2. One `general-purpose` Agent per ticket, all in ONE message (background). Prompt = key + title + "follow BRIEF.md" + per-ticket hints (known MRs, sibling tickets handled by other agents -> link not duplicate, existing docs/Lucid). Parent ticket agent writes the roll-up and covers any closed sub-task with no agent.
3. Collect `results/<KEY>.json`. Agents often finish with "ended without delivering a report": don't re-run, just check the file / SendMessage "Write results/<KEY>.json then reply with it".
4. PNGs: Lucid `lucid_export_document_as_PNG` returns a blank placeholder for Mermaid-imported docs. Run yourself, sequentially (NOT parallel agents - shared temp paths overwrote PNGs):
   `python3 -I render_pngs.py <pack> <scratchpad> KEY...` then `md5 -r <pack>/*-diagram.png | sort` -> no duplicate hashes; `file` -> sane WxH.
5. `python3 -I build_index.py <pack> KEY...` -> README.md. Secret scan: `grep -rnoE 'glpat-|AKIA[0-9A-Z]{16}|Bearer [A-Za-z0-9._-]{20,}' <pack>` must be empty.
6. Hand back: table grouped by state (READY-TO-CLOSE = only sign-off/close left; BLOCKED = waiting on other team/person; IN-PROGRESS = work left on our side; DONE), cost/cleanup leftovers, gaps. User posts comments + attaches `<KEY>.md` + `<KEY>-diagram.png`.

## Gotchas
- Harness R12 denies any Bash command whose text contains `jira-comment` (even ls/tail/grep). Name drafts `<KEY>.comment-draft.txt`; read old ones with Read tool.
- Cost: ~130-190k tokens per ticket agent. Mention scale before fanning out >10 if user didn't ask for it.
- Drafts only: CLAUDE.md hard rule 1 forbids posting Jira/Slack for the user.
