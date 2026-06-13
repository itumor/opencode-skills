# Ollama codex-app Integration Reference

## Ollama Version Check

```bash
# Check version
ollama --version

# codex-app requires Ollama 0.24+
# Run upgrade if needed
brew upgrade ollama        # macOS
curl -fsSL https://ollama.com/install.sh | sh  # Linux
```

## PATH Shadowing Issue (macOS Homebrew)

**Problem:** Homebrew installs Ollama to `/opt/homebrew/opt/ollama/bin/ollama`, but an older binary at `/usr/local/bin/ollama` shadows it.

**Symptoms:**
```
Warning: client version is 0.24.0
ollama version is 0.23.2   # wrong version running
Error: unknown integration: codex-app
```

**Fix — Option A (PATH, no sudo):**
```bash
export PATH="/opt/homebrew/opt/ollama/bin:$PATH"
ollama --version  # should show 0.24.0
```

**Fix — Option B (symlink, requires elevated permissions):**
```bash
# DON'T delete /usr/local/bin/ollama — just update it
sudo ln -sf /opt/homebrew/opt/ollama/bin/ollama /usr/local/bin/ollama
```

**Fix — Option C (permanent PATH in shell config):**
```bash
# Add to ~/.zshrc or ~/.bashrc
export PATH="/opt/homebrew/opt/ollama/bin:$PATH"
```

## Available Integrations (Ollama 0.24+)

Run `ollama launch --help` to see all. Key ones:

| Integration | Description |
|---|---|
| `codex-app` | Codex App GUI with local model |
| `codex` | Standalone Codex CLI with local model |
| `hermes` | Hermes Agent |
| `opencode` | OpenCode CLI |
| `claude` | Claude Code |
| `cline` | Cline |
| `vscode` | VS Code extension |

## Launching codex-app

```bash
# Basic launch (interactive confirmation)
ollama launch codex-app --model qwen2.5-coder:32b

# Non-interactive (Hermes/automated)
ollama launch codex-app --model qwen2.5-coder:32b --yes

# With explicit PATH
export PATH="/opt/homebrew/opt/ollama/bin:$PATH"
ollama launch codex-app --model qwen2.5-coder:32b --yes
```

## Best Models for codex-app

Models with strong tool-calling + large context (64k+):

- `qwen2.5-coder:32b` ⭐ (user's preference — Apache 2.0, 16.9GB, 128K ctx)
- `deepseek-coder-v2` (if available)
- `gpt-oss:20b` or `gpt-oss:120b`

## Ollama Service Management

```bash
# Start Ollama service
brew services start ollama   # macOS (if using Homebrew service)

# Or run manually
ollama serve

# Check running models
ollama ps

# Pull a model
ollama pull qwen2.5-coder:32b

# Verify API is responding
curl http://localhost:11434/api/tags
```

## Codex App Profile Switching

```bash
# Switch Codex App to use Ollama backend
ollama launch codex-app --model qwen2.5-coder:32b --yes

# Restore to default Codex profile
ollama launch codex-app --restore
```
