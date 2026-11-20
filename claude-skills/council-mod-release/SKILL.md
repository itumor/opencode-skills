---
name: council-mod-release
description: Use when changing, testing, reviewing, releasing or installing the Council Mode mod in ~/Council/council-mod ("fix the council mod", "release council", "push council to GitHub/GitLab", "council on everywhere", "autoOn", "why is the council stuck reviewing / scoring 0 / nudging"). Covers checks, single-identity commits, both remotes, the live dev copy, install/config and known failure modes.
---

# Council mod: change -> check -> release

Repo `~/Council/council-mod` (main). Facts: memory `council-mod-repo`. Engine traps: memory `claude-code-mod-api-gotchas`.

## Before touching it
- `git -C ~/Council/council-mod log --oneline -3` and `gh api repos/itumor/claude-council-mode/commits -q '.[0].sha'`: a parallel session has edited and pushed this folder before. Never force-push the public repo; put new work on top of `origin/main` (`git commit-tree <tree> -p origin/main`).
- The installed plugin reads THIS folder: an edit is live in every new session at once.

## Checks (all, every release)
1. `claude plugin test ~/Council/council-mod` (gate.test.ts, autoon.test.ts, ui.test.tsx). UI tests must mount on both `terminal` and `desktop`. validate and tsc do not catch a pane that throws while drawing; only these mounts do. Isolate a suspect element in a one-file probe mod before blaming it.
2. `tsc` strict over `hooks` + `contract` with the engine types (`.claude-plugin/types/`, written when the mod loads).
3. `claude plugin validate ~/Council/council-mod`.
4. `mcp__plugin-authoring__scan_secrets` on the folder; `git log -p --all | grep -iE 'eisgroup|eramadan|exigen|eqxdev'` must be empty.
5. Author/committer only `itumor <5806781+itumor@users.noreply.github.com>` (repo-local config). Run `git -C ... log --all --format='%ae %ce' | sort -u`.

## Release
- Bump `.claude-plugin/plugin.json` version + README title + INSTALL.md "at time of writing".
- `git push origin main` (GitHub, public) and `git push eis main` (EIS GitLab, private, needs VPN).
- Live dev copy for the current session: `rsync -a --exclude .git --exclude .claude-plugin/types --exclude .claude --exclude .memsearch --exclude .remember ~/Council/council-mod/ ~/.claude/dev-mods/<session>/council/` (reloads when a council tool is next called). An atom `shape` bump drops the running council: restart it with `mcp__council__mode` "on" + the user's task.
- Refresh the installed copy after a push: `claude plugin update council@claude-council-mode` (marketplace is the local folder), then `/reload-plugins` or restart. Defaults are now 8/2/2, reviewers `claude-haiku-5-5` medium effort; `autoOn` is false (memory `council-cost-tuning-2026-11-19`).
- Install elsewhere: `claude plugin install council --marketplace itumor/claude-council-mode --config autoOn=true`. Existing install: `printf '{"autoOn":"true"}' | claude plugin configure council@claude-council-mode --values-stdin`.
- Org library: blocked on 2.1.325 (PublishPlugin drops the `.d.ts` contract). Do not work around it.

## Council run under council (dogfooding)
- Reviewers are read-only: put git facts (log line, rev-list count) verbatim in `checks`; for code/MR reviews use skill `council-review-evidence-pack`.
- Criteria/artifacts must not name scores, targets, pass marks ("pass-mark" is refused too), rounds or fence markers (`author_`, `<<`, `>>`): the tool refuses.
- Reviewer scored 0 "no JSON object": auto mode refused its hand-back; v0.6+ recovers from its earlier bare-JSON message. Check transcripts: `~/.claude/projects/<proj>/<session>/subagents/agent-*.jsonl`.
- The correctness reviewer has no shell: before the v0.6 rubric it capped at 8 for 3 rounds on a fully tested change (2026-11-17). Since v0.6, recorded checks count as reported evidence, but no run has confirmed that yet. Write the real test output into an evidence file before aiming at 9, or give that agent test-only `Bash`. Details: memory `feedback-council-reviewers-need-evidence-pack-files`.
- Any prompt typed while the mode is on becomes a new run ("save learnings" did). Use `/council off` before meta prompts.
- Out of rounds -> report NEEDS HUMAN DECISION with the table of scores; offer fix-first / accept risk. Only the user starts a new council or presses Off.
- No baseline for reviewers: the working copy can differ from the installed cache for unrelated reasons, so a diff vs cache is not your change. Write an `evidence.md` listing exactly the edits instead; reviewers still cap ~8.5 without a shell.
