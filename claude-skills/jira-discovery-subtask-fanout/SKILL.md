---
name: jira-discovery-subtask-fanout
description: Use when a Jira discovery/design ticket must be split into N problem sub-tasks, each with problem, options, recommendation, a Lucid diagram per option and an attached doc (.md + PDF), and the parent updated with the full plan. Triggers - "create subtasks for KEY, each with problem/solution/options/recommendation", "diagram for every option attached to jira", "use subagents per task", "N problems = N subtasks = N lucid diagrams = N docs", "add the full plan to the main task". Reference run COINT-21561 (2026-10-21, 7 sub-tasks).
---

# Jira discovery → N sub-tasks with Lucid + doc (fan-out)

Reference: COINT-21561 (ArgoCD for upper), 2026-10-21. 7 sub-tasks COINT-21576..21582, Lucid folder 452954239.

## Hard constraint first
Hook **R12 denies every Jira POST/PUT from Claude**, including subagents, even when the user says "write directly". Don't route around it (Python urllib, `run_in_terminal`, another session). The split:
- **Claude and agents:** research, docs, diagrams, `create.json` payloads.
- **User:** runs `~/.claude/scripts/jira-subtask-publish.py`.

Say this up front so nobody expects Claude to write the issues. Memory: `feedback_no_ai_jira_slack_comms`.

## Steps
1. **Research once (main loop)** before splitting. Use 2-3 Explore agents for repo, memory and docs. Put all facts in one `research.md`. Ask the user to confirm the problem list (N) with AskUserQuestion.
2. **Read the parent's field schema (GET only).**
   - `GET /rest/api/2/issue/createmeta/<PROJ>/issuetypes` gives the Sub-task type id.
   - `.../issuetypes/<id>` lists required fields. COINT requires `customfield_18240` Customer name and `customfield_42440` Environment Type.
   - Copy their values from the parent (`GET issue?fields=customfield_...`).
   - Wrap every token call as `zsh -ic 'curl ... -o file'`, alone in its own Bash call (R15).
3. **Workdir (scratchpad):**
   - Copy `md2pdf.py` from `~/.claude/scripts/`, or call it from there.
   - Create a Lucid folder with `lucid_create_folder`.
   - Write `brief.md`, the per-agent contract: fill in `brief-template.md` from this folder. It covers the doc sections, Lucid rules, payload shape and return block.
4. **One `general-purpose` subagent per problem, background, all in one message.** Each produces in `P<n>/`:
   - `P<n>.md` with sections Problem, Facts (source + PROVEN/UNPROVEN), Options, Comparison, Recommendation, Open questions/owners, Acceptance criteria, Next steps, Sources.
   - One Lucid doc: a page per option plus "Recommended". Follow the `lucid-aws-architecture-diagram` rules. Export `P<n>-<page>.png` and look at each one.
   - `P<n>.pdf` via `md2pdf.py`.
   - `create.json` = `{"fields":{project, issuetype, parent, summary, components, priority, required customfields, assignee, labels, description (Jira WIKI markup)}}`.
   - `recommendation.txt`: one line for the parent table.
   - Tell agents explicitly: **no Jira POST/PUT**.
5. **Parent (main loop):**
   - `parent/description.wiki` with the `{SUBTASK_TABLE}` placeholder plus goal, current state, target, decisions/owners, roadmap and risks.
   - `parent/<PARENT>-plan.md/.pdf`.
   - One overview Lucid doc from an extra agent: `parent/<PARENT>-overview-*.png`.
6. **Publish (user):**
   ```bash
   python3 -I ~/.claude/scripts/jira-subtask-publish.py --parent <KEY> --base <workdir> --dry-run
   python3 -I ~/.claude/scripts/jira-subtask-publish.py --parent <KEY> --base <workdir>
   ```
   It is idempotent (exact-summary match, attachments skipped by filename), so the user can run it as each payload lands.
7. **Verify (Claude, GET only):**
   - `issue/<KEY>?fields=subtasks,description&expand=renderedFields`. Request `description` in `fields`, or `renderedFields` lacks it.
   - Sub-task count = N; each sub-task has md + pdf + all PNGs.
   - `lucid_list_folder_contents` lists N docs + the overview.
   - Look at one PNG.

## Traps seen
- **Renaming a summary between runs creates a duplicate.** Freeze summaries after the first publish.
- **A changed file with the same name is NOT re-uploaded.** Bump the filename (`-v2.png`) to replace it.
- **Lucid:**
  - The create call has no folder argument, so move the doc with `lucid_update_document(parent=)`.
  - An ~87 KB spec created only the headings; keep specs ≤45 KB or split them.
  - Lucid can't delete docs: failed drafts get renamed `OLD DRAFT (delete)` for the user to remove.
- **Agents' facts beat the brief:** they re-verify live. Merge their corrections into the parent (e.g. D-21 PrivateLink replaced, GitLab CE has no enforced approvals).
- **Parallel agents:** 7 ran in parallel without conflicts. Each took 10-23 min and 250-370k tokens.
- **`chk-*.png` and other helper files** in `P<n>/` are not attached, because only `P<n>.md`, `P<n>.pdf` and `P<n>-*.png` are picked up.

Related: `lucid-aws-architecture-diagram`, `eis-jira-rest-ops`, memory `coint21561_argocd_upper_discovery`.
