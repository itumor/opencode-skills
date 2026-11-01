---
name: headless-claude-run-hardening
description: Use when building or changing anything that starts an unattended `claude -p` run (launchd agent, cron, scheduled task, local web app, autopilot, "run Claude on each ticket"), when a headless run fails with an API 400 that interactive sessions never hit, or when a security review flags an `--allowedTools` list. Covers the permission allowlist + deny list, the ~/.claude write helper, the JEV router base-URL override, env -i reproduction and live permission probes, claude.ai connector reads, draft-only connector writes, guarding a local token-gated endpoint, and validating agent-writable fields a UI renders as links.
---

# Hardening an unattended `claude -p` run

Worked example: `~/.claude/scripts/cockpit/server.py` (`INVESTIGATE_ALLOW`, `DENY`, `PERMS`, `RUN_SETTINGS`, `start_run`). Background: memories `claude_headless_dontask_permission_gotchas.md`, `jev_router_breaks_headless_claude.md`.

## 1. Command shape
```
claude -p "<prompt>" --output-format stream-json --verbose --max-budget-usd <cap> \
  --model <pinned> --append-system-prompt "<untrusted-data warning>" \
  --settings '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}' --name "<KEY> <mode>" \
  --permission-mode dontAsk --allowedTools <list...> --disallowedTools <list...>
```
- Prompt right after `-p`: the variadic tool lists swallow a trailing positional.
- `--settings` base URL: `~/.claude/settings.json` routes through the JEV router at `127.0.0.1:38471`. Outside the desktop app's env that breaks turns (Haiku with 128k max_tokens; a model rejecting role 'system').
- Start it with `start_new_session=True` (its own process group), so a launchd restart of the parent does not kill it; re-attach by pid.
- `cwd ~/gitwork/iac` sets repo context and relative paths only. With `--setting-sources ""` (section 2) project settings are skipped, so NO harness hook runs (guard-bash, guard-mcp, ...): `--allowedTools`/`--disallowedTools` plus the validating wrapper are the whole policy, and any guard you need lives in the wrapper.

## 2. Permissions (unattended = untrusted input)
- **`--setting-sources ""` first.** Otherwise your own allow rules from user/project/local settings silently join `--allowedTools`; a live probe showed aws/glab/ls running that the run's list never allowed. Then tell the run to Read `CLAUDE.md` and the skill file, since nothing is preloaded.
- Prefer ONE validating wrapper over an allowlist of real tools (see `~/.claude/scripts/cockpit/ro.py`): allow only `Bash(python3 -I <wrapper> *)`. Wildcard patterns over real tools leak (mid-pattern `*`, readers that write, shell globs dodging literal denies).
- `dontAsk` + an explicit allowlist. Never bare `Bash`, `Write` or `Edit`; never `bypassPermissions`.
- Allow read verbs only. Leave out readers that execute or write: `find`, `sed`, `cat`/`echo` (redirects), `git fetch`, `git branch`.
- Deny: `Bash(*>*)`, exec/write flags (`git * --output|--ext-diff|--upload-pack|-c`, `aws * get-object|get-*token*|--outfile`), secret reads (`get-secret-value`, `ssm get-parameter`, `kubectl get secret`, `--raw`), GitLab writes (`glab api * -X|-f|-F|--input`), and credential redirection (`--hostname`, `-R`, `--server`, `-s`, `--token`, `--kubeconfig`, `--endpoint-url`, `KUBECONFIG=` / `AWS_CONFIG_FILE=` / `GITLAB_HOST=` / `HTTPS_PROXY=` prefixes).
- Write each flag deny twice: `tool --flag*` and `tool * --flag*`. The second form alone misses a flag placed first.
- Files under `~/.claude`: scoped `Write(...)`/`Edit(...)` are never honored. Use a validating writer script (`cockpit/routine-write.py`: fixed names, key regex, size cap) and allow only `Bash(python3 <that script> *)`.
- Tell the run in its prompt which commands work. Otherwise it wastes turns on denials.
- **CLAUDE.md recipes become the run's commands.** Runs copy `cd X; export K=V; unset Y; cmd` and `for r in ..; do` loops from CLAUDE.md; dontAsk denies export, loops and shell variables, so evidence is lost silently (GENESIS-425582 prep run: 4 denials). Grep the project CLAUDE.md for `export`/`unset` and preset those in the launcher env (`env = dict(os.environ, GITLAB_HOST=...)`, `env.pop("GITLAB_TOKEN")`, server.py `GL_ENV`). Prompt: "GITLAB_HOST is already set: never export. One plain command per Bash call: no loops, no shell variables, no redirects, literal paths only."
- **The Read tool is a separate exfiltration path**; Bash denies don't cover it. Deny `Read(~/.zshrc|~/.zprofile|~/.zshenv|~/.bashrc|~/.aws/**|~/.ssh/**|~/.config/glab-cli/**|~/.kube/**|~/.netrc|~/.docker/config.json)` plus the app's own token/url files, next to the matching `Bash(*zshrc*)`-style denies (server.py `DENY`).
- Each segment of a compound command (`|`, `;`, `&&`) is matched separately: `<allowed> | head` passes if `head` is allowed.
- Built-in safe commands (`echo`) pass dontAsk with no rule: keep `Bash(*>*)` denied.
- Every resume / reply / continue / fork of an unattended run reuses the SAME perms object (`PERMS["reply"] = PERMS["investigate"]`, selftest asserts `is`): a follow-up reads the same untrusted text. `--permission-mode auto` + a deny list is never a sandbox (10-28 review: `cat ~/.zs*`, env reads and Jira writer scripts still reachable). Real implementation work goes to an interactive Desktop session.

## 3. Verify before trusting
1. **Probe:** a cheap Haiku run (`--max-budget-usd 0.3`) with the real perms. Ask it to run each test command verbatim, then read `permission_denials[].tool_input.command` from the `--output-format json` result. Include must-deny cases (flag-first forms, redirects, secret reads, foreign hosts, `echo hi`, a CLAUDE.md-style `cd X; export K=V; cmd`, `export GITLAB_HOST=evil.example.com`, `cat ~/.zshrc > /tmp/x` then check no file appeared, Read tool on ~/.zshrc and ~/.aws/config) and must-allow cases (`git log`, `aws ... --profile X`, `<allowed> | head`). A past cockpit run's denials: `permission_denials[]` in the result event of `~/.claude/change-runs/cockpit/runs/<rid>.jsonl`.
2. **Bare env:** reproduce launchd with `env -i HOME="$HOME" USER="$USER" PATH=<plist PATH> claude -p ...` before blaming anything else.
3. **One real run** under the actual launcher. Check the result event: `subtype`, `is_error`, `total_cost_usd`, and that the expected files were written.
4. If an agent-facing HTTP endpoint triggers writes, add a guard-bash rule and put its id in `GUARDS_CRITICAL` (`harness/iac/hooks/_lib.sh`). Otherwise guards-off silently skips it. Live-fire with `cd ~/gitwork/iac && echo '<call>' > /dev/null` (denied before it runs, nothing to clean up). A host:port-only text match is easy to dodge (`B=$(head -c 21 <url-file>); curl "${B}api/x"`, or the port in `$P`): trigger on host:port OR the auth header name OR the address-file path, AND an endpoint list followed by `([^a-z]|$)` so read endpoints like `/api/runs` stay allowed (guard-bash.sh R18). Make the token and address files R15 secret paths plus harness settings `Read()` denies (reading them IS the bypass). Selftest rows for the variable-port and address-file forms; live-fire both the Bash form and the Read tool. The rule matches text, so edit the guard and any note naming the endpoints with Edit/Write, never a Bash heredoc.

## 3b. Reading claude.ai connectors (Slack, Google Calendar, ...) headless
Worked example: `~/.claude/scripts/cockpit/connectors.py` + `run_sync` in server.py. Memory `claude_ai_connectors_in_headless_runs.md`.
- The run sees the account's connectors even with `--setting-sources ""`: `mcp__claude_ai_<Name>__<tool>`.
- Allow exactly ONE read tool; put every write tool of every connector (send/draft/schedule/create/update/delete/respond/reaction/canvas) plus Bash/Write/Edit/Read in `--disallowedTools`. Add `--no-session-persistence`, Haiku, `--max-budget-usd 0.10`.
- Take the data from the RAW `tool_result` in the stream-json log (match the tool_use id), never from the model's reply. For an unknown result format, use `--json-schema` → `structured_output` and validate every field and link (scheme + host regex).
- Treat as failure (and keep the last good data): no tool call, fewer results than calls asked, any `is_error` result, a result event that isn't `subtype: success`, missing structured output, or an unparseable body. Record the cost even when the result can't be parsed.
- Expired connector OAuth = tool_result "needs you to sign in again": only the user can reconnect it (claude.ai Settings → Connectors, or /mcp). Show that, don't retry in a loop.
- Paid background syncs: run them only while the page is really in use (a page-only header, not any GET), cap concurrency, count in-flight budget toward the daily cap, and put the trigger endpoint under guard R18.
- The model first calls `ToolSearch {query:"select:mcp__claude_ai_..."}`; that tool_result is empty or a `tool_reference`. Budget the turn (`--max-turns 3-4`, connectors.py: 4) and pair tool_use -> tool_result by id for the connector tool name only (`tool_results(events, tool)`), never "the first tool_result".
- A run can end `subtype: success`, `is_error: false` while the connector's own tool_result has is_error ("needs you to sign in again"): judge each connector result.
- Auth probe (~1 cent): `claude -p 'Call the tool mcp__claude_ai_Google_Calendar__list_events exactly once with {"pageSize": 1}. Then reply with the single word done.' --output-format stream-json --verbose --max-turns 3 --model claude-haiku-5-5 --max-budget-usd 0.05 --no-session-persistence --settings '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}' --setting-sources "" --permission-mode dontAsk --allowedTools mcp__claude_ai_Google_Calendar__list_events > log`, then jq the tool_result blocks (1st = ToolSearch reference, 2nd = the real call).

## 3c. Connector write = draft only
The only sanctioned connector write is `mcp__claude_ai_Slack__slack_send_message_draft`: it saves a draft the USER sends (a second one in the same conversation fails `attached_draft_exists`). Allow only that tool and drop it from that run's `--disallowedTools` (deny beats allow); keep every other write tool denied. Give the exact args JSON in the prompt and say the text is data. After the run require exactly 1 call whose raw tool_use input equals the previewed channel_id + message (connectors.py `tool_calls`), else fail with "nothing was saved". Timeout: charge the full budget. Put it behind the section-4 macOS dialog with its own title ("Cockpit: Slack draft") and a button labelled "Save draft", never "Send"; name the endpoint in CLAUDE.md rule 1 and in the R18 list (cockpit `/api/draft`). Validate channel ids with `^[CDG][A-Z0-9]{6,20}\Z`.

## 4. User-owned writes
Anything posting to Jira/Slack/GitLab on the user's behalf goes behind a native macOS dialog: osascript `activate` + `display dialog`, default button Cancel, `giving up after 120`. The text goes in as argv. Log the reason (confirmed / cancelled / timed out / error) to an audit file. Without `activate`, a dialog from launchd opens behind other windows and times out unseen.
- Switches that spend money or start runs (autopilot) fail closed: a state file that exists but cannot be read means enabled=False, keep it as `<name>.corrupt`, never wipe it (server.py `auto_state`/`read_json`).

## 5. Run output rendered by a UI
An unattended run's output is as untrusted as its input. Any field it can write that a local page renders as a link or HTML is a stored-XSS path into a page holding the token and the write endpoints (cockpit: the state-file `session:` line becomes the "Open in Desktop" href). List those fields and validate each one 3 times:
1. Writer: refuse anything but the exact shape (routine-write.py refuses `set session` unless `claude://claude.ai/epitaxy/local_<uuid>`).
2. Server: exact regex anchored with `\Z`, rebuild the link from the captured id, else '' (server.py `SESSION_LINK_RE` + `_safe_open`).
3. Page: allow-list the scheme (`safeClaude` = `claude://` only, `safeHttps` = `https://` only); anything else = disabled button. Grep the page for unguarded `href:`.
Selftest rows at every layer: `javascript:alert(1)`, `https://evil`, malformed `local_x`, and a valid link + `\njavascript:1`. Anchor with `\Z` or `re.fullmatch`, never `$`: Python `$` matches before a trailing `\n` (routine-write.py `SESSION_RE` still ends in `$`; the server's `\Z` catches it).
