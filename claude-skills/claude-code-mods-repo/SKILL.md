---
name: claude-code-mods-repo
description: Use when editing, adding, building, testing, loading or releasing Claude Code mods in ~/gitwork/claude-code-mods (next-steps, cache-keeper, recording-mode, goal-meter, collision-guard), when bundling function-hook plugins from shared TypeScript, or when fanning out a multi-mod / multi-agent build with git worktrees and an independent security audit.
---

# claude-code-mods repo: ops + multi-agent build recipe

Repo `~/gitwork/claude-code-mods` (GitLab `eramadan/claude-code-mods`, private). Facts and open follow-ups: memory `claude-code-mods-repo-five-mods`; API traps: memory `claude-code-mod-api-gotchas`. API authority = `vendor/claude-code.d.ts` (grep it), `vendor/reference.md`; the live copy is written by the `plugin-authoring` skill.

## Everyday loop
```bash
cd ~/gitwork/claude-code-mods
npm run check          # lint(tsc+rules) + vitest + build + `claude plugin validate/test` per plugin
npm run build          # dist/plugins/<mod> (wipes + recreates: not while a session is starting)
npm run demo           # real renderers, sample data
```
Live test (validate/test miss runtime bugs; always do this once per command/render path):
`cd /tmp/x && CLAUDE_CODE_PLUGIN_DIRS= claude -p --plugin-dir ~/gitwork/claude-code-mods/dist/plugins/<mod> "/cmd" </dev/null` (blank env isolates one mod; `--debug-file f` for hook errors; plugin commands cost no model turn; interactive-only paths: tmux/pty or say "not exercised").

## Hard rules of the bundle (each broke the validator or the engine once)
1. Pure/shared code takes an `Io` (`src/core/events.ts`), never `$`; `hostIo($)` is the only adapter and must stay a `function` declaration. `$` may be passed only to top-level `function` declarations; `$.fs` etc. cannot be passed as values.
2. `plugin.ts(x)` exports ONLY `export const register`; build.mjs rewrites `var register` to an export. A plugin imports only files inside its own folder (core is bundled in).
3. Disabled = inert: every hook starts with the config gate and `return next(e)`; no command registered.
4. Band hooks compose: `const below = await next(e)`, nest it only if `isTree(below)` (`src/core/ui.ts`).
5. Persist/log only via `core/storage` and `core/logger` (scrub + refuse symlinked files). New secret shapes go in `core/scrub.ts` with a runtime-assembled fixture test.
6. Sub-agent or not, never invent an engine API; show `UNAVAILABLE` and document in `docs/<mod>.md`.

## Release / load
Loaded in all sessions via `CLAUDE_CODE_PLUGIN_DIRS` in `~/.claude/settings.json` (5 `dist/plugins/*` paths appended). Rebuild, then start a NEW session. Push: harness R6 denies pushing main; user runs `git push -u origin main` in their terminal. gitleaks: `.gitleaks.toml` allowlists `tests/` (fake fixtures).

## Multi-agent build recipe (worked 2026-10-03: 5 mods, 1723 tests, 23 audit findings caught)
1. **Inspect the real API first**, then **spike the whole pipeline** (one tiny mod: bundle -> `claude plugin validate` -> `claude plugin test` -> headless live run) BEFORE fan-out. The spike found the `$`-passing and `register`-export rules that would have broken all five agents.
2. Orchestrator writes the shared contract: `docs/architecture.md`, `src/core/*` (Io port, config gate, logger, storage, scrub, ui, fakes), `scripts/build.mjs|validate.mjs|lint.mjs`, `vitest.config.ts`. Commit it.
3. `git worktree add worktrees/<m> -b mod/<m>` per agent + `ln -s ../../node_modules`. `.gitignore` must say `node_modules` (no slash) so the symlink is ignored. One agent per mod, owning only `src/mods/<m>/`, `tests/<m>/`, `docs/<m>.md`; shared changes go in its report. Use opus for the safety-critical mods (redaction, git/locks). Fixed 8-section report + exact commit message.
4. Agents cannot `git commit` (harness R9): they stage explicit paths; main loop commits and `merge --no-ff`s. Tell them not to use `HARNESS_SUBAGENT_GIT=1`.
5. After merge run all gates, then an integration script (each mod alone, all together, each disabled, bad config, state across invocations, load time).
6. **Independent read-only security auditor agent with reproductions** after the agents' own tests are green. It found 3 high issues the authors' 1500 tests missed (secrets in markdown-bold form, structured-key blindness, clip-before-redact). Send findings back to the same agents (SendMessage resumes them; fast-forward their worktrees to main first), re-run their repro scripts, record fixed/accepted in `docs/security-review.md`.
7. Fix shared-core findings yourself on main so agents do not collide; keep a regression test per finding using the exact repro input.
