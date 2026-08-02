---
name: eis-absence-catchup-report
description: Build a full "what happened while I was away" report for the EIS DevOps/IaC role by sweeping every reachable source — GitLab group 1711 MRs, on-prem Jira (my issues, mentions, watched, worklogs), Gmail, Slack, Google Drive — then turn it into a prioritised action plan. Use when the user says "I'm back from vacation", "catch me up", "what happened this month/week", "I was out of office, give me a report", "what did I miss", or on the first day back from any absence. Also use for a Monday-morning or post-conference catch-up over a shorter window. Encodes the source-reachability matrix (what each connector can and cannot see), the exact glab/JQL/Gmail queries, and the four traps that silently produce an empty or wrong report.
---

# EIS — catch-up report after an absence

Produce two things: **what happened** (evidence-backed, tabulated) and **what to do now** (prioritised, with owner). Reference run: 2026-07-31, covering a 3–30 Jul absence — surfaced 239 touched MRs, a new client onboarding, two people blocked on the user, and a red main branch nobody had noticed.

## Phase 0 — establish the window and the source matrix

Get the absence window precisely (the user's stated dates are often wrong — see Phase 5). Then check what is actually reachable *before* promising coverage:

| Source | How | Notes |
|---|---|---|
| GitLab | `glab api` + `GITLAB_HOST=sfo-cvdevopsgit01.eqxdev.exigengroup.com` | Always works. Group **1711** = `iac` |
| Jira | `curl` + `JIRA_TOKEN` bearer, `jira.eisgroup.com/rest/api/2` | On-prem; cloud Atlassian MCP cannot reach it. See `eis-jira-rest-ops` |
| Gmail | MCP `search_threads` / `get_thread` | Read + draft only, **no send, no settings** |
| Slack | MCP `slack_search_channels` → `slack_read_channel` | See trap #2 |
| Drive | MCP `search_files` with `modifiedTime >` | Returns org-wide docs; most will be other teams' |

State the gaps in the report. Never imply coverage you don't have.

## Phase 1 — GitLab sweep

Paginate; a single call caps at 100 and silently truncates.

```bash
export GITLAB_HOST=sfo-cvdevopsgit01.eqxdev.exigengroup.com
for p in 1 2 3 4 5 6; do
  glab api "groups/1711/merge_requests?updated_after=<START>T00:00:00Z&per_page=100&page=$p&scope=all&state=all&order_by=updated_at"
done
```

Concatenated JSON arrays — decode with a `json.JSONDecoder().raw_decode` loop, dedupe on `references.full`. Then:

- **Filter out `pnt_terraform_build`** (Renovate) from the narrative, but *count* it — a large open Renovate backlog is itself a finding (57 open in `argocd/argocd` on the reference run).
- Group merged-in-window MRs by **ticket prefix** to discover the month's themes; don't list MRs chronologically.
- `state=opened&reviewer_username=<user>` and `&assignee_username=<user>` → what awaits the user.
- `state=opened&author_username=<user>` → their own stale MRs (33 on the reference run).
- Check **`pipelines?ref=main&per_page=1`** for each key repo. A red main nobody mentioned is the highest-value technical find.
- Compare `groups/1711/projects?include_subgroups=true` against local clones to spot **new repos** — new repos mean new workstreams.

## Phase 2 — Jira sweep

Write the formatter to a **file**; inline `python3 -c` with an f-string containing escaped quotes fails with `SyntaxError: f-string expression part cannot include a backslash`. Use `%`-formatting or a script file.

Run all five, they answer different questions:

```
assignee = currentUser() AND resolution IS EMPTY ORDER BY updated DESC
assignee = currentUser() AND updated >= "<START>" ORDER BY updated DESC
comment ~ "<username>" AND updated >= "<START>" ORDER BY updated DESC        # ← who is waiting on you
(reporter = currentUser() OR watcher = currentUser()) AND updated >= "<START>"
worklogAuthor = currentUser() AND worklogDate >= "<START>" AND worklogDate <= "<END>"
```

The **`comment ~`** query is the one that finds humans blocked on the user. Then per key issue pull `?fields=...,comment&expand=changelog` and **strip `eis-account-jira` bot comments** — they are 90% of the volume and pure GitLab-mention noise. What remains is the real conversation.

Read the changelog for **`Sprint`** and **`Rank`** changes — that is how you detect the user's tickets being quietly parked by a manager.

Also resolve every ticket key seen in Phase 1 MR titles: `key in (...)` gives status/assignee for the whole month's themes in one call.

## Phase 3 — Gmail sweep

Exclude your own noise or the signal drowns:

```
after:YYYY/MM/DD before:YYYY/MM/DD -in:draft -in:sent -from:<self>
  -from:notification@slack.com -from:<newsletter senders>
```

Prioritise: `jira@eisgroup.com` "mentioned you on" · `sfdcdonotreply` / PSA missing-time · BambooHR · HR "Action Required" · calendar invites for meetings missed. `get_thread` with `FULL_CONTENT` only for the few that matter — bodies are huge (one HR mail was 20 KB of signature HTML).

## Phase 4 — Slack sweep

See trap #2. Get the channel id first, then read it directly. Expect *low* volume; a quiet team channel is a legitimate finding worth stating plainly rather than padding.

## Phase 5 — reconcile the absence itself

Cross-check the **OOO autoreply end date**, the **BambooHR leave booking**, and any **dates the user told finance**. On the reference run all three disagreed and ~16 working days were never booked as leave. PSA "missing time" nags during the absence are the tell. See `[[jira-psa-timesheet-sync]]`.

## Phase 6 — write it

- Lead with the **source-coverage table**, gaps included.
- Then **themes**, not a changelog. Each theme: what changed, who drove it, the tickets, the live artefact.
- Call out explicitly where **the user's own prior work was superseded** — that is the most useful and most-missed category.
- A short **"broken right now"** table.
- An action plan split by **who can do it**: only-the-user (human comms, merges, HR, approvals) vs. can-be-delegated. Respect `[[feedback_no_ai_jira_slack_comms]]` and `[[feedback_no_merge_or_apply_without_review]]` — draft, never send; propose, never merge.
- Flag anything time-boxed (cert expiries, sprint ends, colleagues going on leave).

## The four traps

1. **Slack "old workspace" false alarm.** Permalinks render as `eisgroup-old.enterprise.slack.com`; that is a migrated-grid alias, *not* a dead workspace. Reads are live. Never conclude "wrong workspace" from the permalink host.
2. **Private channels break `in:#name` search.** `#team-devops-oc` was made private by the migration bot, so `in:#team-devops-oc` returns "No results found" — identical to an empty workspace. Fix: `slack_search_channels` → take `channel_id` → `slack_read_channel`. Verify against the Slack "you have N unread messages" digest email, which lists real recent messages.
3. **Keyword-less Slack search sorted by timestamp returns today's alert-bot spam**, not the window you asked for. Always constrain by channel or query.
4. **Oversized tool results get spilled to a file.** A `slack_search` result was 62 KB. Read it back in ~80 KB character slices via `python3 -c 'print(open(p).read()[A:B])'` — `Read`'s offset/limit is line-based and these files are one enormous line.

## Related

`eis-jira-rest-ops` (Jira REST auth + worklogs) · `iac-workspace-refresh` (the natural next step once the report is written) · memories `[[gmail-mcp-limits-and-ooo-end-now-trap]]`, `[[slack-mcp-old-workspace]]`, `[[jira-psa-timesheet-sync]]`.
