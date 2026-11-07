---
name: claude-autoapprove-ops
description: Use when working on, testing, or troubleshooting AutoApprove (~/Auto-approval; GitHub itumor/claude-autoapprove, GitLab eramadan/claude-autoapprove) - the macOS menu bar app + Claude Code PermissionRequest hook that auto-approves Claude Code desktop prompts. Triggers - "auto-approve on/off", "why wasn't this prompt clicked", "clicker pressed Accept by itself", "rebuild AutoApprove", "Accessibility grant lost", "e2e test the hook", "decisions.jsonl", "risky command hold / Resume clicker", "Dump Claude button labels".
---

# AutoApprove ops

## Map
| Path | Role |
|---|---|
| `hook/autoapprove.py` | PermissionRequest hook. Allow when `enabled`+`hook`, app heartbeat <10 s, timer not expired, no risky match. Never answers `AskUserQuestion`/`ExitPlanMode`. `--selftest`, `--version`, `--help`, `--log-path` |
| `app/AutoApprove.swift` | SwiftUI MenuBarExtra + AX clicker. 1 s tick, presses exact-label buttons only inside top-level Claude web areas (`https://claude.ai/…` or `Claude.app/Contents/Resources`). Writes `status.json` heartbeat. Quit = OFF. `--dump`, `--selftest` |
| `build.sh` | `swiftc` -> sign (first codesign identity, "LocalFlow Dev" here; ad-hoc fallback) -> `~/Applications/AutoApprove.app` |
| `install.sh` | jq-edit `~/.claude/settings.json` (backup first). `--login`, `--uninstall` |
| `tools/`, `docs/` | promo video/audio scripts (ElevenLabs), images |
| `~/.config/claude-autoapprove/` | `state.json` (enabled, hook, clicker, buttons, until, askRisky, askPatterns), `decisions.jsonl` (0600, rotates at 1 MB), `status.json`, `hold.json`, `buttons-seen.txt` |

## Checks
```bash
python3 ~/Auto-approval/hook/autoapprove.py --selftest
~/Applications/AutoApprove.app/Contents/MacOS/AutoApprove --selftest
jq . ~/.config/claude-autoapprove/state.json
tail -n 20 ~/.config/claude-autoapprove/decisions.jsonl
grep -n autoapprove ~/.claude/settings.json
```
E2E: side session runs `touch /tmp/autoapprove-e2e-hook && echo HOOK_OK` and `git -c color.ui=false --version`; log must show `src:hook decision:allow` for both.

## Traps
- **Clicker matches label, not prompt.** "Accept"/"Continue" approve plan prompts too (2026-11-05: plan accepted with no user click). Hook skipping ExitPlanMode does NOT stop the clicker. Remove label from `buttons` to keep it human.
- `ask` rules still prompt after hook allow, then clicker presses them if label listed.
- Rebuild without stable signing identity = Accessibility re-grant. Stale TCC entry: `tccutil reset Accessibility com.eramadan.claude-autoapprove` (bundle id may be neutral on public build; check `Info.plist`), re-add app, toggle on.
- Pop-out windows show `about:blank` -> never clicked (by design). Minimized / other Space -> AX can't see it.
- Risky hold: only **Resume clicker** clears it; OFF/ON does not. Patterns are regex seatbelt, not sandbox.
- Before leaving the user unattended: confirm `enabled` state with them; it approves everything while ON.

## Release
Two remotes: GitLab `origin` (internal) and public GitHub `itumor/claude-autoapprove`. PR-Agent not configured on this repo; `mr-feedback.py watch` exits 1 after timeout, not a failure of the MR.
