---
name: eis-jira-rest-ops
description: Use when transitioning, logging or editing worklog time, commenting on, or attaching files to issues on the self-hosted Jira Data Center at jira.eisgroup.com (GENESIS/COINT/etc). The cloud Atlassian MCP cannot reach this on-prem instance — drive the REST API v2 directly with the JIRA_TOKEN bearer PAT.
---

# EIS Jira (Data Center) REST ops

## Overview
`jira.eisgroup.com` is **self-hosted Jira Data Center**, NOT Atlassian Cloud. The `plugin:atlassian` MCP (mcp.atlassian.com) only talks to cloud → it cannot touch this instance. Use REST API v2 + a Personal Access Token.

**Auth:** env var `JIRA_TOKEN` is a Jira DC PAT. Send `Authorization: Bearer $JIRA_TOKEN`. Verified working. Base: `https://jira.eisgroup.com/rest/api/2`.

## Quick reference

| Action | Call |
|--------|------|
| Read issue | `GET /issue/{KEY}?fields=summary,status,assignee,timetracking,worklog` |
| List transitions | `GET /issue/{KEY}/transitions` → returns ids + target status names |
| Transition | `POST /issue/{KEY}/transitions` body `{"transition":{"id":"<id>"}}` → 204 |
| Add comment | `POST /issue/{KEY}/comment` body `{"body":"...wiki markup..."}` → 201 |
| Log time | `POST /issue/{KEY}/worklog` body `{"timeSpent":"8h","started":"<ts>","comment":"..."}` → 201 |
| Edit a worklog | `PUT /issue/{KEY}/worklog/{worklogId}` body `{"timeSpent":"3h"}` → 200 |
| Get worklog ids | `GET /issue/{KEY}/worklog` → each `worklogs[].id` |
| Delete a worklog | `DELETE /issue/{KEY}/worklog/{worklogId}` → 204 |
| Find own worklogs by date | `GET /search?jql=worklogAuthor = currentUser() AND worklogDate >= 2026-06-06 AND worklogDate <= 2026-06-08` → issues; then GET each issue's worklog list and filter `author.name` |
| Attach file | `POST /issue/{KEY}/attachments` multipart, header `X-Atlassian-Token: no-check`, field `file` → 200 |

## Gotchas
- **No literal "In Progress"** in GENESIS workflow. Working state = **"In Development"** (transition name "Clarify to In Development"). Always `GET .../transitions` first — ids/names are workflow-specific, not global.
- **GENESIS close path (verified GENESIS-428897, 2026-06-10):** from "In Clarification" only `Clarify to *` transitions exist — no direct close. Chain: `951` (→ In Development) then `421` ("Close" → Closed). Transition 421 **requires** `resolution` (e.g. `{"name":"Done"}`) AND `customfield_28240` "Primary Client" (option, e.g. `{"value":"Market-driven"}` — copy from the issue's existing field). Discover required fields with `GET .../transitions?expand=transitions.fields` and jq-filter `.fields[]|select(.required)`. NOTE: a different GENESIS resolve path needed `customfield_47242` "Resources Changed" — required fields vary per transition, never assume.
- **Worklog "started" format:** `YYYY-MM-DDThh:mm:ss.000-0700` (offset, no colon). Missing/malformed → 400.
- **Worklog day = Jira profile TZ, NOT local TZ (verified 2026-06-12):** Jira profile for eramadan renders worklogs in `-0700` (Pacific). Local machine offset is `+0300` — sending `09:00:00.000+0300` lands the worklog on the PREVIOUS day (23:00 -0700). Always send `started` with `-0700` offset and a mid-day hour (e.g. `09:00:00.000-0700`) so timesheet day matches intent. Fix a wrong day with `PUT .../worklog/{id}` body `{"started":"..."}`.
- **`JIRA_TOKEN` not auto-exported in non-interactive shells:** extract from `~/.zshrc` first: `export JIRA_TOKEN=$(grep -o 'JIRA_TOKEN=[^ ]*' ~/.zshrc | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'")`. A 401 with XML body = token missing, not expired.
- **To change logged time, edit the existing worklog** (`PUT .../worklog/{id}`), don't add a second one. `8h` shows as `1d` in timetracking; `3h` stays `3h`.
- **Attachment** requires `X-Atlassian-Token: no-check` and multipart `file=`. Set filename: `-F "file=@/path;filename=nice-name.md;type=text/markdown"`. Reference it in a comment with `[^nice-name.md]`.
- **Timesheet reconciliation recipe (verified 2026-06-12):** the Salesforce PSA timesheet (Time Entry grid) is fed FROM Jira worklogs by "Integration User" sync — fix hours in Jira, never in PSA. To find which issue holds a misplaced day's hours: JQL `worklogAuthor = currentUser() AND worklogDate = <day>`, then list each candidate issue's worklogs and match `timeSpent` + `started`. PSA "Actual Hours" lags until next sync run. Timesheet target: 8h per working day Mon–Fri, zero on weekends.

## Working examples
```bash
# transition (discover id first)
curl -s -H "Authorization: Bearer $JIRA_TOKEN" "https://jira.eisgroup.com/rest/api/2/issue/GENESIS-427822/transitions"
curl -s -X POST -H "Authorization: Bearer $JIRA_TOKEN" -H "Content-Type: application/json" \
  --data '{"transition":{"id":"951"}}' \
  "https://jira.eisgroup.com/rest/api/2/issue/GENESIS-427822/transitions"

# log 8h today, then later shrink to 3h via PUT
curl -s -X POST -H "Authorization: Bearer $JIRA_TOKEN" -H "Content-Type: application/json" \
  --data '{"timeSpent":"8h","started":"2026-06-08T09:00:00.000+0000"}' \
  "https://jira.eisgroup.com/rest/api/2/issue/GENESIS-427822/worklog"
curl -s -X PUT  -H "Authorization: Bearer $JIRA_TOKEN" -H "Content-Type: application/json" \
  --data '{"timeSpent":"3h"}' \
  "https://jira.eisgroup.com/rest/api/2/issue/GENESIS-427822/worklog/6094657"

# attach a file + comment linking it
curl -s -X POST -H "Authorization: Bearer $JIRA_TOKEN" -H "X-Atlassian-Token: no-check" \
  -F "file=@/path/plan.md;filename=plan.md;type=text/markdown" \
  "https://jira.eisgroup.com/rest/api/2/issue/GENESIS-427822/attachments"
```

## Related EIS access (same session learnings)
- **GitLab** `sfo-cvdevopsgit01.eqxdev.exigengroup.com`: clone over **SSH port 2224**, e.g. `git clone ssh://git@sfo-cvdevopsgit01.eqxdev.exigengroup.com:2224/<group>/<repo>.git`. HTTPS prompts for creds; default-port-22 SSH is refused. Stored creds in `~/.git-credentials`.
- **Lucid MCP**: HTTP server `https://mcp.lucid.app/mcp` (OAuth, DCR). Add: `claude mcp add --transport http lucid https://mcp.lucid.app/mcp`. **Tools load only at session start** — after adding mid-session, transport shows Connected but no `mcp__lucid__*` tools appear; restart the session, then `/mcp` to authenticate.
