---
name: jira-cockpit-dev-loop
description: Use when adding or changing a feature of the local Jira+Claude cockpit (~/.claude/scripts/cockpit, 127.0.0.1:8765, launchd com.eramadan.jira-cockpit), adding a cockpit endpoint, or when the cockpit page looks broken, empty or "not synced yet" after an edit. Loop - baseline, patch, selftests (-B), JS syntax check, guard/CLAUDE.md for new write endpoints, restart, 403 health, forced refresh, Browser-pane check, review workflow, memory.
---

# Cockpit change loop

**Files**
- `~/.claude/scripts/cockpit/`: `server.py`, `index.html`, `connectors.py`, `routine-write.py`, `recommend.py`, `ro.py`, `desktop.py`
- `~/.claude/scripts/jira-dashboard-refresh.py`
- State: `~/.claude/change-runs/cockpit/`
- Memories:
  - `cockpit_local_controller.md`
  - `cockpit_recommender_rules_and_decisions.md`
  - `claude_ai_connectors_in_headless_runs.md`
  - `harness_r18_cockpit_endpoint_text_match.md`

**Hard rule.** Never press the cockpit's write buttons. Never call `/api/act|run|reply|stop|autopilot|snooze|desktop|sync|draft` (guard R18). Tell the user which button to press.

## Steps

1. **Baseline.** Copy the files you will touch to the scratchpad; that copy is the diff base for this turn. Also `cp index.html ~/.claude/change-runs/cockpit/index.html.bak-<YYYYmmddHHMM>`.
2. **Patch.** Use the Edit tool, or a scratchpad python file of `(old, new)` pairs that asserts `s.count(old) == 1`, run with `python3 -I -B`. No Bash heredocs that name token/secret or cockpit endpoints: R15 and R18 match on text.
3. **Selftests.** From `~/.claude/scripts/cockpit`, run `COCKPIT_NO_NOTIFY=1 python3 -I -B <f> --selftest` for each of:
   - `server.py`
   - `connectors.py`
   - `routine-write.py`
   - `recommend.py`
   - `ro.py`
   - `desktop.py`
   - `../jira-dashboard-refresh.py`

   `-B` writes no `__pycache__`, so no cleanup is needed. Never chain a cache delete onto the tests: Blast Radius holds the whole chain. `COCKPIT_NO_NOTIFY` keeps the selftest from sending notifications. Fixtures need local-naive timestamps: a `Z` or `+00:00` stamp shifts the day grouping in +02:00.
4. **JS syntax.** index.html has no build step. Write `re.search(r'<script>(.*)</script>', s, re.S).group(1)` to a scratchpad `page.js`, then run `node --check page.js`. Past breaks it catches: a `const` placed between `try` and `catch`, and a top-level name that shadows a global.
5. **New write endpoint, in the same change:**
   - Add it to the R18 regex endpoint list, the deny message and the header comment in `~/.claude/harness/iac/hooks/guard-bash.sh`.
   - Add a selftest row: `t "R18 cockpit <x> via curl" 'deny R18' ...`.
   - Extend the rule-1 exception in the iac `CLAUDE.md`.
   - Run `bash guard-bash.sh --selftest` in the background (>180 s; baseline is the 4 known ask-tier failures).
   - Live-fire from `~/gitwork/iac` with the `echo '...' > /dev/null` trick.
   - Keep R18 in GUARDS_CRITICAL.
6. **Restart.** Run `launchctl kickstart -k gui/$(id -u)/com.eramadan.jira-cockpit`. Wait with an until-loop for `cockpit up on 127.0.0.1:8765` in `~/.claude/change-runs/cockpit/server.log`, not a fixed sleep.
7. **Health.** curl the root with no token: `403` means up. Never read the url or token file: R15 and the settings Read denies block it, and a workaround leaks the token.
8. **Fresh data.** `board.json` keeps the previous build, so new fields stay empty after a restart until a forced rebuild. Use the page's Refresh or `await loadBoard(true)`, and allow ~20 s.
9. **Browser pane.** Use it only on a tab the user opened; the agent cannot build the tokened URL.
   - Call `tabs_context` first: subagents leave stray `file://` tabs (memory `browser_pane_shared_with_workflow_subagents.md`).
   - Check `read_console_messages` with onlyErrors.
   - Use `javascript_tool` on the globals: `B`, `B.sync`, `rowsBy()`, `briefDays()`, `mrStatus()`, `B.building`/`B.error`, `#lanes .lane h2`.
   - Check both narrow width and 1440x900, then reset with preset desktop.
   - If a connector is down, inject sample data (e.g. `B.sync.calendar = {...}`) to test the rendering.
10. **Review a bigger diff.**
    - Write the per-turn diffs and run the background review Workflow: JS logic, Python/API, security and UX/a11y lenses, with one skeptic per finding.
    - Make no edits while it runs, so its line numbers stay valid.
    - Then read every check table and the `logs` "dropped (unverified)" items (memory `feedback_workflow_results_read_full_report.md`).
    - Tell reviewers not to open files in the Browser pane.
11. **Memory.** Update `cockpit_local_controller.md` with the Edit tool; a Bash append trips R18. The user runs the GitLab mirror publish (`~/.claude/scripts/cockpit-publish.sh`): its push to `main` happens inside the script, so the harness deny never sees it.

## Traps

- **Redraw.** The page redraws only when `boardSignature()` in index.html changes. Add any new top-level board data (e.g. `B.sync`) to that array. Otherwise the data arrives, the cards keep their old state ("not synced yet") and no error shows.
- **`window.open` is shadowed.** The top-level `async function open(key, startTab)` (the ticket drawer) replaces it. Open links by creating an `<a>` and calling `.click()` on it.
- **Modal backdrop.** Close it only when both mousedown and click land on the backdrop; a text-selection drag otherwise closes it. Esc in a modal field blurs the field first, and the next Esc closes the modal.
- **Run list.** A prep-run e2e started from your own shell does not appear in the cockpit's run list.
