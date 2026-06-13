#!/bin/bash
# Sync all OpenCode/Claude/Codex skills to ~/.opencode-skills-backup/
# Cron: runs daily, auto-commits + pushes to github.com/itumor/opencode-skills

set -euo pipefail

REPO_DIR="$HOME/.opencode-skills-backup"
LOG_FILE="$REPO_DIR/sync.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "=== Sync started ==="

sync_dir() {
  local name="$1" src="$2"
  local dst="$REPO_DIR/$name"

  if [ ! -d "$src" ]; then
    log "SKIP $name: source missing ($src)"
    return
  fi

  mkdir -p "$dst"
  rsync -a --delete --copy-links \
    --exclude='.git' --exclude='node_modules' --exclude='__pycache__' \
    --exclude='nextgenopen-ldap' \
    --exclude='SKILL.original*' \
    --exclude='*.backup' --exclude='*.bak' \
    --exclude='.bundled_manifest' --exclude='.curator_state' --exclude='.curator_backups' \
    --exclude='.usage.json' --exclude='.usage.json.lock' --exclude='.sync-manifest.json' \
    --exclude='auth.json' --exclude='config.yaml' --exclude='config.toml' \
    --exclude='token.json' --exclude='credentials.json' \
    --exclude='*.key' --exclude='*.pem' --exclude='*.p12' --exclude='*.pfx' \
    --exclude='.env' \
    "$src/" "$dst/"
  log "SYNC $name: $src → $dst"
}

# ── Skills ──────────────────────────────────────────────────────
sync_dir claude-skills                "$HOME/.claude/skills"
sync_dir agents-skills                "$HOME/.agents/skills"
sync_dir opencode-skills              "$HOME/.config/opencode/skills"
sync_dir superpowers-skills           "$HOME/.codex/superpowers/skills"
sync_dir codex-skills                 "$HOME/.codex/skills"
sync_dir codex-rules                  "$HOME/.codex/rules"
sync_dir cursor-skills                "$HOME/.cursor/skills"
sync_dir cursor-agent-skills          "$HOME/.cursor/skills-cursor"
sync_dir hermes-agent-skills          "$HOME/.hermes/hermes-agent/skills"
sync_dir hermes-agent-optional        "$HOME/.hermes/hermes-agent/optional-skills"
sync_dir agent-devops-skills          "$HOME/.agent/skills"

# ── Memory ───────────────────────────────────────────────────────
sync_dir hermes-memories              "$HOME/.hermes/memories"

# ── Git commit + push ───────────────────────────────────────────
cd "$REPO_DIR"

# Check if there are changes
if git diff --quiet && git diff --cached --quiet; then
  log "No changes. Skipping commit."
else
  git add -A
  git commit -m "chore: daily skills sync $(date +%Y-%m-%d)" || log "Commit skipped (nothing to commit)"
fi

# Push
if git push origin main 2>&1 | tee -a "$LOG_FILE"; then
  log "Push OK"
else
  log "Push FAILED — check network/auth"
fi

log "=== Sync complete ==="
