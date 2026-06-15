# Skill Sync — Backup all agent skills to git

Backup all OpenCode/Claude/Cursor/Codex/Hermes skills to public GitHub repo.
Daily cron + manual trigger after any non-trivial task.

## Quick Reference

```bash
# Manual sync
bash ~/.opencode-skills-backup/sync-skills.sh

# Check repo
open https://github.com/itumor/opencode-skills
```

## Source Locations

| Source dir | Backup name | Skills |
|-----------|-------------|--------|
| `~/.claude/skills/` | `claude-skills/` | 18 — EIS infra, ArgoCD, CyberArk, etc |
| `~/.agents/skills/` | `agents-skills/` | 23 — caveman, frontend-design, find-skills, superpowers symlink |
| `~/.config/opencode/skills/` | `opencode-skills/` | 3 — aws-ec2-ops, gmail-email, windows-ec2-rdp |
| `~/.codex/superpowers/skills/` | `superpowers-skills/` | 14 — brainstorming, TDD, debugging, plans |
| `~/.codex/skills/` | `codex-skills/` | 5 — system skill-creator, plugin-creator, skill-installer |
| `~/.codex/rules/` | `codex-rules/` | 1 — default.rules |
| `~/.cursor/skills/` | `cursor-skills/` | 1 — eis-waf (duplicate, Cursor copy) |
| `~/.cursor/skills-cursor/` | `cursor-agent-skills/` | 19 — Cursor CLI: automate, canvas, review, etc |
| `~/.hermes/hermes-agent/skills/` | `hermes-agent-skills/` | 87 — apple, creative, devops, github, mlops, etc |
| `~/.hermes/hermes-agent/optional-skills/` | `hermes-agent-optional/` | 76 — blockchain, security, web-dev, etc |
| `~/.agent/skills/` | `agent-devops-skills/` | 1 — devops-agent |

### Memory locations (non-skill, but tracked)

| Location | Content |
|----------|---------|
| `~/.hermes/memories/MEMORY.md` | Hermes persistent memory |
| `~/.hermes/memories/USER.md` | Hermes user preferences |
| `~/.hermes/SOUL.md` | Hermes system prompt |
| `~/.codex/memories/` | Codex memory (empty currently) |

## Excluded (secrets/credentials)

**Entire skill:** `nextgenopen-ldap/` — contains bank IPs, admin passwords, AWS lab creds

**File patterns excluded from rsync AND .gitignore:**
- `auth.json`, `config.yaml`, `config.toml` — API keys / tokens
- `token.json`, `credentials.json` — auth tokens
- `*.key`, `*.pem`, `*.p12`, `*.pfx` — private keys
- `.env` — environment secrets
- `SKILL.original*` — original backups with credentials
- `.bundled_manifest`, `.curator_state`, `.curator_backups` — tool metadata
- `.usage.json`, `.usage.json.lock`, `.sync-manifest.json` — state files
- `__pycache__/`, `node_modules/`, `.remember/`, `logs/`, `sessions/`, `cache/`
- `*.db`, `*.sqlite`, `*.lock`

## Cron

```
15 4 * * * bash /Users/eramadan/.opencode-skills-backup/sync-skills.sh >> /Users/eramadan/.opencode-skills-backup/sync-cron.log 2>&1
```

Runs daily at 4:15 AM via crontab.

## Repo

- **URL:** https://github.com/itumor/opencode-skills
- **Visibility:** Public
- **Branch:** main
- **Sync script:** `~/.opencode-skills-backup/sync-skills.sh`
- **Gitignore:** `~/.opencode-skills-backup/.gitignore`

## Post-Task Rule

**After every non-trivial task (including this one), run:**
```bash
bash ~/.opencode-skills-backup/sync-skills.sh
```

This ensures any new skills installed or modified during the session are backed up.
