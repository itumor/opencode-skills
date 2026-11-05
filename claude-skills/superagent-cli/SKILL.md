---
name: superagent-cli
description: Use when driving claude-superagent from a terminal or script — "superagent jobs/show/answer/post/implement", scripting against its REST API (127.0.0.1:8790/api), installing or registering its MCP server in Claude Code, "claude mcp add superagent", exit code 3 / router not reachable, "Invalid environment variable format: superagent", or when the superagent MCP tools are unavailable.
---

# superagent CLI, REST API and install

## Overview
`python3 -m superagent <cmd>` talks to the running router's REST API (`/api/*` on 127.0.0.1:8790); it never writes
the DB itself. Run from `~/claude-superagent` (`-m` runs the cwd's code; an old worktree gives `invalid choice`).
How-to: `~/claude-superagent/docs/CONTROL.md`; full tables: `docs/USAGE.md` §5. User guide page with copy buttons:
https://claude.ai/artifact/HmVWo7QbUFaBvezVM8ej4z (repo copy `docs/control-guide.html`).

## Commands
| Need | Command |
|---|---|
| Overview / one job | `jobs [--q TEXT]` / `show KEY` |
| Drafts / decisions | `drafts` / `decisions [--limit N]` |
| Input to a worker | `answer KEY TEXT` (`-` = stdin, `--redo 1` restarts a working run) |
| Retry, stop, unstop, ack | `retry KEY`, `stop KEY`, `unstop KEY`, `ack KEY` |
| Pause / resume | `pause` / `resume` |
| Repo suggestion | `use-repo KEY REPO` / `dismiss-repo KEY` |
| Start over / move repo (also confirms an auto-picked repo) | `rerun KEY [--text NOTE]` / `change-repo KEY REPO` |
| **Post Jira draft** | `post ID` (shows body, asks; `--yes` required without a TTY) |
| Plan | `plan KEY` (print) / `plan KEY --edit` (`$EDITOR`, stored if changed) / `set-plan KEY TEXT` (`-` = stdin) |
| **Approve plan + implement** | `approve-plan KEY` (shows repo + the whole plan and its sha, asks; `--plan-sha SHA` pins it; `--yes` required without a TTY) |
| **Verify now** (I merged / applied in Atlantis / ArgoCD synced / MR made outside superagent) | `verify KEY [--note TEXT] [--mr URL]` (no `--yes`: reads only; runs the repo's verify hook next pass; 409 without a verify hook, on another host/project MR, or an ineligible job) |
| **Implement** (branch + MR) | `implement KEY` (shows repo, asks; `--yes` required without a TTY) |
| Local only (no router) | `status`, `catalog list\|refresh`, `rotate-token`, `selftest`, `open` |

Add `--json` for machine output (stdout = JSON only). Exit: `0` ok, `1` refused/409/429/`n`, `2` usage or missing
`--yes`, `3` router not reachable. From Claude's Bash tool there is no TTY: `post`/`implement`/`approve-plan` need `--yes`, so run
them only when the user asked for that exact post/implement in chat. Anything sent through the API/CLI (answers, plan
approval) reaches the worker framed as relayed ("the approver may be an assistant"); only the panel form is framed as
the user's own.

## Scripts (REST API)
Use `superagent.client.Client.from_config(config.load(client.DEFAULT_CONFIG), via="api")` → `.get("state")`,
`.get("job/KEY")`, `.action("answer", key=..., text=...)`. Raw HTTP: token from `<state>/panel.token` in `X-Token`
only, no `Origin` header, JSON body of strings ≤64 KB, prove `/whoami` HMAC before sending the token.
Harness guards may block `curl -X POST` to local write APIs: prefer the CLI.

## Install / register (human steps)
1. Deploy: `git -C ~/claude-superagent pull`, then `launchctl kickstart -k gui/$UID/com.eramadan.superagent`.
2. Register MCP — name BEFORE `-e` (`-e` is variadic), `-P` mandatory, main checkout only:
   `claude mcp add -s user superagent -e PYTHONPATH=$HOME/claude-superagent -- python3 -P -m superagent.mcp`
3. Recommended `~/.claude/settings.json`: `{"permissions":{"deny":["mcp__superagent__superagent_post_draft","mcp__superagent__superagent_implement","mcp__superagent__superagent_approve_plan"]}}`
   (prompts vanish in bypass/skip-permissions sessions; deny still holds).
4. New Claude session → `/mcp` shows superagent connected. Restart sessions after every deploy.

## Common mistakes
| Mistake | Fix |
|---|---|
| `claude mcp add -s user -e K=V superagent -- …` → "Invalid environment variable format" | put `superagent` before `-e` |
| Registered without `-P` | a repo's `json.py`/`superagent/` in the session cwd would load: re-register with `-P` |
| Registered before deploy | server fails to connect until `~/claude-superagent` has `superagent/mcp.py` |
| `PYTHONPATH` → a worktree | stale code; always `~/claude-superagent` |
| Exit 3 | router down, port 8790 taken, or token rotated without restart → kickstart |
| Testing changes on live | use a DB copy + preview panel with `outbox.post` stubbed (CONTROL.md §8) |
