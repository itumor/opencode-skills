# Brief: on-hold handoff pack for ONE Jira ticket
<!-- Template. Copy into the pack dir, replace docs/status-2026-10-29 with the pack dir. Used 2026-10-29 for 17 tickets. -->
<!-- Lessons baked in below: write results/<KEY>.json (agents often end without a report); comment draft file name avoids
     "jira-comment" (harness R12 denies any Bash command containing it, even ls/grep). -->


Goal: team switches to new work; this ticket may go ON HOLD. Produce everything needed so whoever comes back resumes from exactly where we stopped. You own ONE ticket (given in your prompt). Read-only on all live systems.

## Hard rules
- NEVER post/edit/transition anything in Jira, Slack, GitLab. No comments, no worklogs, no attachments. Draft only; user posts.
- No git commits/pushes/merges. No `atlantis apply`. No kubectl/aws mutations. Read-only `aws`/`kubectl`/`glab api` GET allowed if it settles a live fact (skill `aws-kubectl-readonly-access`); expired SSO = say so, do not `aws sso login`.
- No secrets/passwords/tokens in any output file.
- Write only inside `/Users/eramadan/gitwork/iac/docs/status-2026-10-29/`.
- Shell = zsh, BSD tools. `glab api` GET -> file, then `jq`. `export GITLAB_HOST=sfo-cvdevopsgit01.eqxdev.exigengroup.com; unset GITLAB_TOKEN` style only if needed (GITLAB_HOST already in env).

## Gather (be thorough, cite sources)
1. Jira: `python3 ~/.claude/scripts/jira-read.py <KEY>` (full dump: status, desc, links, comments). Also attachments list: GET `https://jira.eisgroup.com/rest/api/2/issue/<KEY>?fields=attachment,subtasks,worklog,timespent` via a small python urllib GET reusing token logic from jira-read.py (token from env or ~/.zshrc; disable redirects). Skip if blocked.
2. Local evidence: `ls /Users/eramadan/gitwork/iac/docs | grep -i <KEY>` (+ related keys), memory notes `grep -ril <KEY> ~/.claude/projects/-Users-eramadan-gitwork-iac/memory/`, `.remember` logs `grep -ril <KEY> /Users/eramadan/gitwork/iac/.remember/`, skills `grep -ril <KEY> ~/.claude/skills/`. qmd MCP search is fine too.
3. GitLab MRs: search group 1711 MRs mentioning the key: `glab api "groups/1711/merge_requests?search=<KEY>&in=title,description&state=all&per_page=100" > /path/in/scratch.json` then jq iid/project/state/title/web_url/merged_at. Note open MRs, unmerged branches, worktrees under `/Users/eramadan/gitwork/iac/.worktrees/` with matching name.
4. Lucid: load Lucid MCP tools via ToolSearch (`+6c33f820 lucid`), FIRST call get_mcp_resource `lucid://skills/readme` and follow it. Search existing docs for the key/topic (`search` / `lucid_search_document`). Links to existing diagrams also appear in Jira comments and memory notes — collect them.
   - If a good diagram exists: reuse, record URL.
   - If none: create ONE diagram showing current state (what is built/live, what is pending/blocked, components, next steps). For AWS-style architecture follow `~/.claude/skills/lucid-aws-architecture-diagram/SKILL.md`; otherwise `lucid_create_diagram_from_mermaid` is fine. Title: `<KEY> - <short> - status 2026-10-29`. Make a share link (`lucid_create_document_share_link`, view access within org) and record URL. If Lucid fails, write the mermaid into the doc and say Lucid failed + error.

## Deliverables (in `/Users/eramadan/gitwork/iac/docs/status-2026-10-29/`)
A. `<KEY>.md` - full detailed status doc:
   - Header: key, title, Jira URL `https://jira.eisgroup.com/browse/<KEY>`, Jira status, assignee, parent, last updated.
   - Goal / acceptance (from ticket).
   - Done so far (dated, with evidence: MR links + state, live checks, files).
   - In progress / open items (open MRs, unmerged worktrees/branches, pending tests).
   - Blockers + who owns them (team/person, linked request tickets).
   - Decisions taken + open decisions.
   - Links: Jira, MRs, Lucid diagrams, docs, Confluence, related tickets, memory notes, skills.
   - Lucid diagram URL(s) + mermaid copy if useful.
   - **Resume checklist**: numbered exact steps to restart (commands, what to verify first, what may have drifted e.g. expired tokens, deleted test resources, rotated passwords).
   - Cost/cleanup notes: anything live that costs money or should be torn down if on hold long.
B. `<KEY>.comment-draft.txt` - paste-ready Jira comment (Jira wiki markup: `h3.`, `*bold*`, `[text|url]`, `||h||` tables, `* bullets`). Caveman style: no filler, fragments OK, status first line. Content: `ON HOLD handoff 2026-10-29` header, status, done, open, blockers, links (MRs, Lucid, docs), resume steps. Under ~60 lines. Mention the attachments to add (`<KEY>.md`, diagram PNG if exported).
C. Optional: `<KEY>-diagram.png` export via `lucid_export_document_as_PNG` if it works.

## Return
FIRST Write the JSON below to `results/<KEY>.json` (Write tool), THEN end with the same JSON as your final message, nothing else.
One JSON object:
{"key":"","title":"","jira_status":"","assignee":"","pct_done":"rough %","state":"one of DONE|READY-TO-CLOSE|IN-PROGRESS|BLOCKED|NOT-STARTED","summary":"<=25 words what is done","blockers":"<=20 words or none","next_step":"<=15 words","open_mrs":["url"],"lucid":["url"],"doc":"path","comment":"path","notes":"anything that failed (Lucid, SSO, Jira) <=20 words"}
