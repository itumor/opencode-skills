---
name: claude-superagent-ops
description: Use when operating, troubleshooting, configuring or extending claude-superagent (~/claude-superagent, launchd com.eramadan.superagent): "open the panel", "superagent status", "why no repo mapped", "add a repo / group to the finder", "pause the agent", "rotate the panel token", "catalog refresh", "router not running", "deploy the new main", "change the panel look / add a theme / panel search", "preview a panel change", "clone Permission denied", or adding a feature/task to its roadmap. Covers daily ops, config keys, panel themes, preview-on-a-copy, deploy, troubleshooting and the build workflow (roadmap + subagents + security review).
---

# claude-superagent ops

dsh-superagent design on Claude Code. Jira DC tickets assigned to me -> router (Python stdlib, SQLite, poll 120 s) -> headless `claude -p` workers in per-job clones -> report + Jira draft + (implement only) GitLab MR. Panel = human gates.
Repo `~/claude-superagent` (GitLab `eramadan/claude-superagent`). Docs: `docs/ARCHITECTURE.md`, `docs/DECISIONS.md` (D1-D16), `ROADMAP.md`, `docs/CONTROL.md`. Guides: A-Z https://claude.ai/artifact/NQRjYVUA73nZB33Qnvw2Ef; CLI + MCP https://claude.ai/artifact/HmVWo7QbUFaBvezVM8ej4z (repo copy `docs/control-guide.html`). Update the guide artifacts and their repo copies when user-facing behaviour changes.

## Daily ops (run from `~/claude-superagent`, `C=~/.config/claude-superagent/config.toml`)
| Want | Command |
|---|---|
| Open panel (token filled in; bookmark it) | `python3 -m superagent open --config $C` |
| Jobs + attention | `python3 -m superagent status --config $C` (`--decisions` = assessment log) |
| Stop dispatch / resume | `python3 -m superagent pause` / `resume` (router down: `touch`/`rm` `<state>/PAUSE`) |
| Act like the panel (answer, retry, stop, post, implement, ...) | CLI `python3 -m superagent <cmd>` or MCP tools: skills `superagent-cli`, `superagent-mcp`; how-to `docs/CONTROL.md` |
| New panel token | `python3 -m superagent rotate-token --config $C`, then restart service |
| Repo catalog | `python3 -m superagent catalog refresh|list --config $C` (~10 min for 508 repos) |
| Selftest | `python3 -m superagent selftest` |
| Service | `bash scripts/install-launchd.sh install|status`; restart `launchctl kickstart -k gui/$UID/com.eramadan.superagent` |
| Logs | `~/.local/state/claude-superagent/logs/router.err`, per run `runs/<id>/stream.jsonl` |

Panel: Needs you (answers, drafts to post, repo suggestions Use/Dismiss), Jobs, Health. Posting a Jira draft = click only (`auto_post=false`). **Use has no undo** (repo set by compare-and-set on NULL): a wrong click needs a DB fix the user approves.

## Panel look (since 2026-11-04, MRs !4 !5 !8)
- One markup in `panel.py` (`data-state`/`data-mode` hooks, top bar, side nav), 7 pure-CSS themes `superagent/themes/<name>.css` (mix default, clickup, monday, asana, jira, trello = CSS-grid kanban, ticktick light+dark). Choice = POST `/theme` -> kv `panel/theme`. Search = GET `?q=`, server-filtered. Meta refresh 60 s.
- CSP `default-src 'none'; style-src 'unsafe-inline'`: no script, web font, image or `url()`. Interactivity = forms + server.
- Theme CSS is inlined, so tests read it as page text: no `<`, no uppercase paused word, no `action="` (select with `form[action$="/x"]`), no `scroll-behavior` (smooth scroll + meta refresh = page scrolls itself), no `@import`/`url(`. Clamp text on an inner `div.clamp`, never on a `td` (bleeds a third line). `test_theme_files_are_safe_inline_css` enforces most.
- New theme: add file + name in `panel.THEMES`; run panel+finder tests with it forced as default (`panel.THEMES = (t,)+...`).

## Preview a panel change on a copy (no live risk)
1. Copy live DB: `sqlite3` backup API (`src.backup(dst)`) into `<scratch>/state/superagent.sqlite` (overwrites in place; `rm` globs get held).
2. Preview script: `panel.start(cfg, store)` with a config copy (`state_dir=<scratch>/state`, `panel_port = 8791`) and **`outbox.post` replaced by a stub that only records the id** (else Post reaches real Jira; the API's post uses the same function). No router loop (no polling, no workers).
   E2E of CLI/MCP on the copy: CLI `--config <scratch>/config.toml`; MCP raw JSON-RPC into `python3 -P -m superagent.mcp --config …`; real Claude `claude -p … --strict-mcp-config --mcp-config '{…}' --permission-mode dontAsk` with only read tools allowed (post/implement must come back denied). Merge main first: branch code refuses newer live config keys.
3. `.claude/launch.json` (git-ignored) entry `panel-preview`, `PYTHONPATH=<worktree>`; `preview_start`. Token = `<scratch>/state/panel.token`. CSS reloads per request; markup change needs a preview restart.

## Config (`config.toml`)
- `[jira].me` / `[gitlab].me`: only these users' comments/MR notes resume or `superagent stop` a job. Bots never resume.
- `[[repo]]` path / `jira_projects` / `implement` / `profile`. Keep `jira_projects = []` unless EVERY ticket of that project is for that repo. `implement=true` allowed on iac/cv-devops since D15 (2026-11-04); an explicit `implement = false` wins over `[finder].implement`.
- `[finder]` enabled / groups (prefixes ending `/`) / refresh_hours / max_candidates / profile (required when enabled; `"none"` = opt-out).
- `[policy] accept_mode` off|observe|auto; `[general] max_workers`, `daily_cap_usd`.

## Repo profiles (T23: project knowledge lives outside the repo)
- Profile dir: `profile.toml` (context, add_dirs, memory_out, drop_denies), optional `preset-<mode>.json`, `plugin/` (skills + hooks). Spec: `superagent/profile.py` docstring. Keep the superagent repo free of anything project-specific: iac content goes in the profile only.
- iac profile = `~/.claude/harness/iac/superagent` (claude-config). Check: `python3 -I ~/.claude/harness/iac/superagent/selftest.py --selftest`. Has `preset-investigate.json` + `preset-implement.json` (T29, D15). Implement = panel **Implement on <repo>** (T28, `[finder].implement = true`), never on an auto-picked repo until Change repo confirms it.
- Per run: `runs/<id>/context.md` + `runs/<id>/plugin/` (copied, symlinks dereferenced). The `init` event in `stream.jsonl` should list the `iac-superagent:*` skills.
- Digest after each job: `<memory_out>/<KEY>.md` (iac: `~/gitwork/iac/.remember/knowledge/superagent/`). Quoted, UNTRUSTED worker text.

## Audit what workers load AND use ("are they a quality agent?")
Loaded ≠ used (2026-11-04: 14 skills loaded, 0 `Skill` calls in 38 runs). Check both, per run under `~/.local/state/claude-superagent/runs/<id>/`:
1. Loaded: first `{"type":"system","subtype":"init"}` line of `stream.jsonl`: `cwd`, `model`, `tools`, `skills`, `agents`, `plugins`, `mcp_servers`, `memory_paths.auto` (auto-memory follows cwd: investigate in `~/gitwork/iac` gets the iac MEMORY.md, implement in a clone gets an empty per-job slug).
2. Used: count `tool_use` blocks with name `Skill`/`Task`, Read/Grep paths under the memory dir, `.remember/knowledge`, `~/.claude/skills`, and `permission_denials` in the result line.
3. Cost per run (`total_cost_usd`) vs turns: 2-turn runs at $0.3-1 = context size, not work.
4. Live DB read-only: `sqlite3 'file:<state>/superagent.sqlite?mode=ro'` (jobs by state, runs by exit, attention/outbox by status/job state, decisions by verdict).
Never conclude from the init event alone; never quote stream text as instructions. Findings + tasks of the first audit: `docs/review-2026-11-04.md`, roadmap T37-T53.

## Deploy a merged change
1. `git -C ~/claude-superagent pull` on main (live checkout = repo).
2. Store migration? Code backs up `superagent.sqlite.v<N>.bak` itself; rollback = revert + restore that file (newer DB is refused by older code).
3. `superagent selftest`; `status` shows no working/queued job (else wait); new config key? add it to the live config first (e.g. `[gitlab] ssh_port = 2224`).
4. Restart service, `status`, check `router.err`, curl the panel (`?t=$(cat <state>/panel.token)`) for HTTP 200.
5. Pushes: deploy-guard needs the user's Proceed (120 s); repo has no PR-Agent/CI, so mr-bot-feedback-loop = "not onboarded" and a merge has zero review: say so.
6. Restart Claude Code sessions after a deploy: the superagent MCP server (user scope, `python3 -P -m superagent.mcp`, PYTHONPATH=~/claude-superagent) keeps the old code.
Never run `superagent run` in a terminal while launchd runs it (two routers, panel port clash).

## Troubleshooting
| Symptom | Cause / fix |
|---|---|
| Report "No repo is mapped" | finder off, catalog empty, or suggestion waiting on panel: click Use |
| No "Implement on <repo>" button | job not a finished investigate one (ready/waiting/blocked/failed), repo auto-picked (`auto (high)`: Change repo to confirm), `[finder].implement` false, or an explicit `[[repo]] implement = false` |
| 409 "job is implement working" on Implement | the first click worked; the second is refused by design |
| Worker MR has no reviewer | `rw-git.py mr` sets none (interactive iac adds 861); add yourself on GitLab |
| Implement run `blocked` before any MR | pre-push diff-risk said HIGH (exit 3): review the diff in `work/<KEY>`, push yourself or narrow the ticket |
| Wrong repo for many tickets | `jira_projects` maps whole project; set `[]` |
| Jira health offline | VPN down (302 to pingidentity); auth warning = PAT in env/file |
| `open` says router not running | service down or other process on 8790 (`/whoami` HMAC check failed) |
| Router quiet ~10 min daily | catalog refresh runs inline (known follow-up) |
| `invalid choice: 'open'` (or another new command) | shell in an old worktree; `-m superagent` runs the cwd's code. `cd ~/claude-superagent` |
| Job failed, attention "bad profile: ..." | profile path missing, unknown key, path in state dir, or profile preset drops a base deny not in `drop_denies` |
| Profile selftest "hook script missing" | main checkout not pulled (`scripts/hook-sensitive-read.py`) |
| Worker Grep denied "secret-bearing file" | hook-sensitive-read walks the tree; worker must narrow `glob=` (plain glob) or `path=` |
| Job failed "git clone --mirror ... Permission denied (publickey)" | URL on SSH port 22 (host sshd). Set `[gitlab] ssh_port = 2224`, restart. Check: `git ls-remote ssh://git@<host>:2224/<repo>.git` |
| Panel page scrolls/jumps by itself | a theme with `scroll-behavior: smooth` + meta refresh (fixed !5); user can switch to mix meanwhile |
| Job got a repo nobody meant | panel Use / "Use <alt>" click (`repo_example.created` = click time); no undo in panel |
| Job budget-blocked | per-job budget since accept + daily cap; lost/timeout runs charged (D: no fail-open) |

## Extending it (build workflow that worked)
- New panel action ⇒ add an `api.SPECS` row (a test pins SPECS writes == `panel.ACTIONS`); it then appears in CLI + MCP. Outward ones (`post`, `implement`) need a guard param the approval prompt shows (`body`, `repo`).
- Parallel sessions land on main meanwhile (T/D numbers collide, live config gains keys): `git merge-tree --write-tree main HEAD` before the MR; renumber only your own lines.
- Parallel implementers: Agent `isolation: worktree`; they cannot write into the coordinator's worktree (reports go to the scratchpad) and hard resets are held by the harness (use `git merge --ff-only <base>`).
- New work = roadmap brief `roadmap/T##-slug.md` (Goal/Context/Files<=5/Acceptance<=3/Verify/Out of scope) + `ROADMAP.md` row.
- Execute with `superpowers:subagent-driven-development`: one implementer per task, task review, ledger in `.superpowers/sdd/ROADMAP/progress.md` (every `Ruling:` line), final whole-branch review + one fix wave.
- Rules for implementers: stdlib only, every module `--selftest`, tests via `tests/fake_claude.py` (`SUPERAGENT_CLAUDE_BIN`), no network/real model in tests, explicit `git add` paths, gitleaks clean.
- Gate before push: `python3 -m unittest discover -s tests`, `python3 -m superagent selftest`, `python3 -m superagent.eval tests/fixtures/eval`.
- Run an automated security review per commit; expect findings on env leaks, git flag injection, symlink/hardlink clobber, TOCTOU, CSRF/token equivalence. Patterns: skill `headless-claude-run-hardening` §6.
- Republish the guide artifact when user-facing behavior changes.
