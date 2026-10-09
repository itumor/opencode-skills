---
name: config-dir-git-backup
description: Use when version-controlling a living config directory (~/.claude, dotfiles, .remember) into a private git repo, when a gitleaks pre-commit hook blocks a commit with "leaks found", when deciding what to exclude vs redact in secret-adjacent files, or when restoring the Claude Code brain on a new machine.
---

# In-place git backup of living config dirs

## Overview

Version a config dir **in place** (git init inside it, allowlist `.gitignore`) — no symlinks, no copy scripts, files stay where the consumer reads them. Secrets are guaranteed out by a **gitleaks pre-commit gate**, not by grep. Deployed instance on this machine: repos `eramadan/claude-config` (`~/.claude`) + `eramadan/iac-remember` (`gitwork/iac/.remember`) on internal GitLab — instance facts in memory `claude-config-backup`.

## Core decisions (where naive approaches fail)

| Naive approach | Failure | Correct |
|---|---|---|
| Exclude `**/*token*`, `**/MEMORY.md` wholesale | Throws away the brain — pointer files ("token lives in ~/.zshrc") are safe AND valuable | Scan content; exclude only files containing real secret VALUES, by exact path |
| grep for `glpat-\|AKIA\|hvs\.` = secret scan | Misses entropy-detected secrets — proven: gitleaks found a 2nd PAT file grep missed | grep is pre-scan only; gitleaks (default rules + entropy) is the gate |
| Hand-written `.git/hooks/pre-commit` | Unportable, silently absent after re-clone | pre-commit framework + tracked `.pre-commit-config.yaml` (gitleaks hook, `language: golang` → needs `go` installed) |
| Redact/edit secret-bearing files | Mutates a working reference file | Leave file untouched; gitignore it by exact path (last rule wins over re-includes) |
| `git config core.excludesfile ""` etc. | Global side effects | Never needed; local `.gitignore` suffices |

## Allowlist .gitignore — re-include nesting

Git cannot re-include a file whose parent dir is excluded. Pattern for "only `memory/` inside each project dir":

```gitignore
/*
!/.gitignore
!/skills
!/projects
/projects/*
!/projects/*/
/projects/*/*
!/projects/*/memory
# secret-bearing files — never commit (after re-includes; last rule wins)
/projects/<dir>/memory/reference_gitlab_auth.md
```

Verify with `git check-ignore -v <path>` per path class + `git status --porcelain` count before first commit.

## Gitleaks false positives

40-char hex (`gitCommitSha` in `plugins/installed_plugins.json`) trips `sourcegraph-access-token`. Fix in tracked `.gitleaks.toml`:

```toml
[extend]
useDefault = true
[allowlist]
regexTarget = "line"
regexes = ['''"gitCommitSha": "[a-f0-9]{40}"''']
```

Picked up automatically from repo root by the pre-commit hook. List findings without dumping values: `pre-commit run gitleaks --all-files 2>&1 | grep -E '^(File|RuleID|Line):' | paste - - -`.

## Auto-commit (macOS launchd)

`~/bin/claude-backup.sh`, launchd `StartInterval 3600` + `RunAtLoad`, per repo: commit `backup: $(date +%F)` once/day on first run ≥18:00 → if GitLab resolves: fetch, merge remote if behind → push if ahead. Fully-synced run touches `backups/last-ok`; a SessionStart hook warns when it is >72h old. Selftest `~/.claude/scripts/claude-backup-selftest.sh` (14 checks, sandbox bare repo, rewrites hour/host/notify via sed). Traps, each hit for real:
- launchd ships minimal PATH: `export PATH="$HOME/.local/bin:/opt/homebrew/bin:..."` (pre-commit, git, qmd, node).
- Single 18:00 run = ~half of days lost when VPN is down at 18:00 and no retry. Hourly + DNS pre-check (`host -W 2`) logs `WAIT offline` with no notify.
- Failures that only send a macOS notification go unseen for weeks (20-day gitleaks stall, 2026-09). The heartbeat file + session-start warning is the real alarm.
- Pushing via a feature branch + MR leaves local `main` diverged after the merge on GitLab (same change, different SHA) → every push is non-fast-forward. The script now merges `@{u}` when behind; on conflict it runs `merge --abort`, logs `ERROR diverged` and sends a notification.
- A blocked commit leaves `git add -A` output **staged**, which also blocks the merge ("local changes would be overwritten"). Fix the cause, then `git reset` + `git add -A` again (never committed, so nothing is lost).
- A stale heartbeat with hours of `WAIT offline` lines can hide the real blocker. Check `git rev-list --left-right --count HEAD...@{u}` and `grep ERROR` before blaming VPN.
- Refresh a search index (`qmd update && qmd embed`) at the end, output discarded, failure logged.

## Internal GitLab specifics

- `GITLAB_HOST=<host> glab repo create <name> --private` — targets non-default host without re-auth.
- Remote URL: `ssh://git@<host>:2224/<ns>/<name>.git` (EIS port 2224).
- remember-plugin ships `.remember/.gitignore` = `*` — replace with allowlist (`logs/`, `tmp/` excluded: churn causes daily noise commits) when making it a standalone repo.

## Restore on new machine

```bash
git clone ssh://git@sfo-cvdevopsgit01.eqxdev.exigengroup.com:2224/eramadan/claude-config.git ~/.claude
cd ~/.claude && pre-commit install   # hook is NOT cloned — reinstall
```
Re-create excluded-by-design files (PAT references) by hand; re-load launchd plist.

## When gitleaks blocks a commit

1. List findings (command above) — never echo raw values.
2. Real secret → gitignore the file by exact path (+ `git rm --cached` if staged); do NOT edit the file. Read the flagged line before calling it a false positive: raw ansible/SSM run logs echo env secrets (`NEXUS_DATASTORE_NEXUS_PASSWORD`, 2026-10-08). For a whole directory of run output, ignore by extension (`/change-runs/**/*.log`, `*.out`, `*.json`) and keep the state/plan `.md`/`.sh` files.
   Tools that write logs into `<cwd>/.claude/logs` (Claude Code mods) → `**/.claude/logs/`; files tracked before the rule need `git rm -r --cached`.
3. False positive → extend `.gitleaks.toml` allowlist (prefer `regexTarget = "line"` with structural context over fingerprints — fingerprints embed line numbers that drift).
4. Re-run `pre-commit run gitleaks --all-files` until Passed, then commit.

## Verification checklist

- `git ls-files | xargs grep -lE '<secret patterns>'` → empty
- `git check-ignore` confirms each never-commit file
- Fresh clone to /tmp → expected files present, secret files absent
- Dummy tracked change → run backup script → commit on remote → clean up
