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
  rsync -a --delete --copy-links --exclude='.git' --exclude='node_modules' "$src/" "$dst/"
  log "SYNC $name: $src → $dst"
}

sync_dir claude-skills        "$HOME/.claude/skills"
sync_dir agents-skills         "$HOME/.agents/skills"
sync_dir opencode-skills       "$HOME/.config/opencode/skills"
sync_dir superpowers-skills    "$HOME/.codex/superpowers/skills"
sync_dir cursor-skills         "$HOME/.cursor/skills-cursor"
sync_dir hermes-skills         "$HOME/.hermes/skills"
sync_dir hermes-memories       "$HOME/.hermes/memories"

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
