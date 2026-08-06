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
| **Total effort on an epic/story** | `GET /issue/{KEY}?fields=timespent,aggregatetimespent` — `timespent` = that issue only; **`aggregatetimespent` = issue + all sub-tasks** (the number you want when quoting a whole workstream) |
| **Who burned the hours** | `GET /search?jql=parent={KEY} AND timespent>0 ORDER BY timespent DESC&fields=summary,timespent,status` — splits OUR hours from other teams' sub-task hours |

### Recipe — "what did this project actually cost?" (verified 2026-08, axajp)
Turn a finished workstream into defensible effort numbers instead of guesses:
1. `aggregatetimespent` on the master → all-parties total; `timespent` → your own hours. The delta is other teams.
2. `GET /issue/{KEY}/worklog` → `worklogs[].started` gives the **real calendar span** (first→last log) and the **count of days actually touched** — usually far fewer than the span, which is the honest "elapsed vs hands-on" story.
3. Per-day rollup: group `timeSpentSeconds` by `started[:10]`.
4. **Always compare against any written estimate.** On axajp the estimate said 14.5–24 WD, the worklogs said 9.6 WD — a **~2× gap**, because waits/context-switching/debug churn go unlogged. Report both bases and say which is which; never quote one as if it were the other. Full numbers: memory `onesuite_onboarding_cost_evidence`.

## Gotchas
- **PRE-FLIGHT: `302 → sso.connect.pingidentity.com` on EVERY REST call means the corp VPN is DOWN, not an expired PAT (verified 2026-08-03).** `jira.eisgroup.com` is public (CNAME `prod-proxy.eisgroup.com`, `63.251.228.69`) but sits behind an **Apache `mod_auth_openidc`** reverse proxy. Off-VPN the proxy bounces the request to Ping SSO *before Jira ever sees the `Authorization: Bearer` header* — so a perfectly valid PAT still 302s. Tells: response headers `Server: Apache` + `Set-Cookie: mod_auth_openidc_state_…` + `Location: https://sso.connect.pingidentity.com/…`. Confirm with a corp-DNS probe: `nslookup sfo-cvdevopsgit01.eqxdev.exigengroup.com` → **NXDOMAIN = VPN down**. Fix = connect OpenVPN Connect (interactive, needs the user); nothing scriptable. Distinguish from the other two auth failures: **401 + XML body** = `JIRA_TOKEN` unset/empty; **401 + JSON** = PAT actually expired/revoked.
- **No literal "In Progress"** in GENESIS workflow. Working state = **"In Development"** (transition name "Clarify to In Development"). Always `GET .../transitions` first — ids/names are workflow-specific, not global.
- **GENESIS close path (verified GENESIS-428897, 2026-06-10):** from "In Clarification" only `Clarify to *` transitions exist — no direct close. Chain: `951` (→ In Development) then `421` ("Close" → Closed). Transition 421 **requires** `resolution` (e.g. `{"name":"Done"}`) AND `customfield_28240` "Primary Client" (option, e.g. `{"value":"Market-driven"}` — copy from the issue's existing field). Discover required fields with `GET .../transitions?expand=transitions.fields` and jq-filter `.fields[]|select(.required)`. NOTE: a different GENESIS resolve path needed `customfield_47242` "Resources Changed" — required fields vary per transition, never assume.
- **GENESIS Closed-as-Fixed needs Story Points (FDE) (verified GENESIS-429532, 2026-06-19):** transition `421` from "In Development" also enforces `customfield_10391` "Story Points (FDE)" (number) — but ONLY a server-side **workflow validator**, not a screen-required field. So `transitions?expand=transitions.fields` reports `customfield_10391 required=false` and you'll get a **400 `"If Resolution is not Cancelled, Won't fix, Duplicate. Story Points (FDE) field is required."`** Set it in the transition `fields` (e.g. `"customfield_10391": 1`) alongside `resolution:{"name":"Fixed"}` + `customfield_28240`. Lesson: the `required` flag misses conditional workflow validators — read the 400 body, it names the field. Full working close payload: `{"transition":{"id":"421"},"fields":{"resolution":{"name":"Fixed"},"customfield_28240":{"value":"Market-driven"},"customfield_10391":1}}` → HTTP 204. (Don't dodge it with `Cancelled`/`Won't Fix` — that misreports a delivered task.)
- **COEXT resolve path (verified COEXT-105505, 2026-07-31)** — different workflow from GENESIS, and much simpler. From **"In Clarification"** the ONLY transitions are `911` Change Priority (self-loop) and **`791` "Clarify" → Reopened**. There is NO direct resolve. Chain: `791` (→ Reopened) → then from Reopened you get `5` **Resolve** (→ Resolved), `4` Start Progress, `861` Get Approval, `711` On Hold, `731` Clarification. Resolve payload needs only the resolution — **no Primary Client / Story Points custom fields** unlike GENESIS: `{"transition":{"id":"5"},"fields":{"resolution":{"name":"Fixed"}}}` → 204. Reassign separately: `PUT /issue/{KEY}/assignee` body `{"name":"<username>"}` → 204. Moral: transition ids and required fields are **per-project workflow** — always `GET .../transitions` after every state change, because the available set changes underneath you.
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

## Learnings — axajp (2026-06)
- **ROUTING — Vault work goes to COEXT, not GENESIS.** Client-env Vault requests (access grants, approle creation, secret/path seeding, policy changes on `secret2/data/<proj>/*`) must be filed as **COEXT** Tasks. The Vault owner (Olha Isachenko = `oisachenko`) explicitly asked on GENESIS-431673 *"please create COEXT in future"* — GENESIS (Observability & Containers) is the wrong queue. Use the COEXT field shape below + `Related`→parent env ticket + FAO the Vault owner. (Likewise: AD/IdC groups → EISHELP; module/template reviews → Markuss.)
- **Create-issue required-field discovery: `createmeta` 400s on this instance.** Don't trust it — instead mirror a recently-created ticket in the same project: `GET /issue/{KEY}?expand=names` and copy the RAW `customfield_*` ids verbatim into the create `fields` block. Required custom fields per project (POST `/issue`, issuetype Task):
  - **COEXT (Task):** `customfield_18240` Customer (`{"id":"96023"}` New Logo) + `customfield_37942` PSA (`{"id":"94711"}`) + `customfield_47242` Resources Changed (`{"value":"No resources limits changed"}`); `components`: Cloud (`{"id":"42111"}`) + Genesis CICD (`{"id":"57710"}`).
  - **COEXT (Task sub-task, issuetype id `66`; e.g. COEXT-106278):** `parent` REQUIRED (the env story, e.g. `COEXT-105830` for axajp); `components:[{"name":"Cloud"}]`; option cf `customfield_38651` Internal (`{"id":"98441"}`) + `customfield_10842` Primary Client array (`[{"id":"96022"}]`) + `customfield_18240` (`{"id":"96023"}`) + `customfield_42440` cicd (`{"id":"75839"}`) + `customfield_47342` (`{"id":"83443"}`). **CV-managed shared-infra provisioning (Nexus account on `sfoeisgennexus01`, GitLab repos on `<prefix>git01`) → assignee `jira.cvsupport` (Jira CV Support queue), NOT EISHELP** (precedents: COEXT-106254 gitlab repos, COEXT-106278 nexus proxy account).
  - **GENESIS (Task):** `customfield_37942` PSA (`{"id":"69126"}` EIS_R&D_v20_CICD) + `customfield_10391` Story Points + `customfield_28240` Primary Client (`{"value":"Demo Team"}` id `51045`) + `customfield_10314` TEAM (`{"value":"DevOps"}` id `65045`) + `customfield_41140` Backlog Area (`{"value":"DevOps"}` id `74120`) + `customfield_38651` Type of Work = Internal (`{"value":"Internal"}` id `69472`) — else 400 **"Epic Link required"**. `component`: DevOps.
  - **EISHELP (Access Request or General):** `customfield_13454` Location (`{"value":"LVA, Latvia"}` id `17911`) + `customfield_12540` Titled Project (`{"id":"79222"}`) + `customfield_37942` PSA (`{"value":"Core Velocity"}` id `71958`) + `customfield_18240` Customer (`{"value":"SaaS R&D"}` id `82412`). The **General** issuetype ALSO needs Location + Titled Project.
- **Issue-link type name = `"Related"`** (NOT `"Relate"`/`"Relates"` → 404). `POST /issueLink` body `{"type":{"name":"Related"},"inwardIssue":{"key":"A"},"outwardIssue":{"key":"B"}}`.
- **User lookup:** `GET /rest/api/2/user/search?username=<substr>` works. The assignable/`search?query=` param is **ignored** (returns all users). Reassign via `PUT /issue/{KEY}/assignee` body `{"name":"<username>"}`. (Jira CV Support queue account = `jira.cvsupport`.)
- **`reporter` is NOT on the COEXT create screen** → 400 `"Field 'reporter' cannot be set. It is not on the appropriate screen"`. Omit it (defaults to the token owner). When mirroring an existing issue's cf, SKIP read-only auto fields or create 400s: rank `customfield_2264x` (lexorank `"0|...:"`) / `customfield_1124x` (`"9223372036854775807"`), devstatus `customfield_31040`.

## Related EIS access (same session learnings)
- **GitLab** `sfo-cvdevopsgit01.eqxdev.exigengroup.com`: clone over **SSH port 2224**, e.g. `git clone ssh://git@sfo-cvdevopsgit01.eqxdev.exigengroup.com:2224/<group>/<repo>.git`. HTTPS prompts for creds; default-port-22 SSH is refused. Stored creds in `~/.git-credentials`.
- **Lucid MCP**: HTTP server `https://mcp.lucid.app/mcp` (OAuth, DCR). Add: `claude mcp add --transport http lucid https://mcp.lucid.app/mcp`. **Tools load only at session start** — after adding mid-session, transport shows Connected but no `mcp__lucid__*` tools appear; restart the session, then `/mcp` to authenticate.
