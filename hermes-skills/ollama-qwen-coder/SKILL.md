---
name: ollama-qwen-coder
description: "Delegate coding tasks to Ollama's qwen2.5-coder:32b model via local OpenAI-compatible API."
version: 1.1.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [Ollama, qwen, local-ai, coding-agent, delegation]
    related_skills: [codex, claude-code, hermes-agent]
---

# Ollama qwen2.5-coder Skill

## Overview

This skill delegates coding tasks to Ollama's `qwen2.5-coder:32b` model via a local OpenAI-compatible API endpoint.

## Provider Configuration

Add to `config.yaml`:

```yaml
providers:
  ollama-local:
    provider: custom:ollama
    default: qwen2.5-coder
    base_url: http://localhost:11434/v1
    api_key: no-key-required
    max_tokens: 16000
    api_mode: chat_completions

fallback_providers:
  - ollama-local
```

**Restart gateway after config changes:** `/restart` in gateway, or `pkill -f hermes.*gateway && hermes gateway &`

## Setup Instructions

### 1. Upgrade Ollama (if needed)

`codex-app` integration requires **Ollama 0.24+**.

```bash
# Check current version
ollama --version

# Upgrade on macOS
brew upgrade ollama

# Upgrade on Linux
curl -fsSL https://ollama.com/install.sh | sh

# Verify upgrade
ollama --version  # should show 0.24+
```

⚠️ **macOS PATH shadowing:** Homebrew installs to `/opt/homebrew/opt/ollama/bin/ollama` but an older binary at `/usr/local/bin/ollama` (v0.23.2) may shadow it. **Always** use the explicit path:

```bash
/opt/homebrew/opt/ollama/bin/ollama --version   # verify 0.24+
```

For all Ollama commands in terminal calls, prefix with:
```bash
export PATH="/opt/homebrew/opt/ollama/bin:$PATH"
```

Add to `~/.zshrc` for permanent fix:
```bash
echo 'export PATH="/opt/homebrew/opt/ollama/bin:$PATH"' >> ~/.zshrc
```

### Codex App Integration (Ollama 0.24+)

To use Codex App (macOS GUI) with qwen2.5-coder:32b:
```bash
export PATH="/opt/homebrew/opt/ollama/bin:$PATH"
ollama launch codex-app --model qwen2.5-coder:32b --yes
```

This sets Codex App's profile to use Ollama. Open Codex App normally — it will use qwen2.5-coder:32b locally.

### Cloudflare Tunnel (Public URL Sharing)

To share a local server publicly via cloudflared tunnel:

```bash
# Start local server (e.g. Python HTTP server)
cd /path/to/project && python3 -m http.server 9876

# Start tunnel (background)
cloudflared tunnel --url http://localhost:9876 --logfile /tmp/cf.log &

# Wait for URL
sleep 12 && grep trycloudflare /tmp/cf.log

# Kill tunnel when done
pkill -f cloudflared
```

Tunnel URL format: `https://*.trycloudflare.com` (random each time, valid while tunnel runs).

For local network only (no public URL): use `http://192.168.0.153:9876` (replace with actual LAN IP from `ifconfig en0 | grep "inet "`).

### Quick Verify Ollama is Working

```bash
# Check version
ollama --version  # must be 0.24+ for codex-app

# Check models loaded
curl -s http://localhost:11434/v1/models

# Test a simple chat
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-coder","messages":[{"role":"user","content":"Hi"}],"max_tokens":20}'
```

### Pre-warm model (avoid cold start timeouts)

```bash
curl -s http://localhost:11434/api/generate \
  -d '{"model":"qwen2.5-coder:32b","prompt":"boot"}' > /dev/null
```

### Common Issues

```bash
# Check if Ollama is running
curl http://localhost:11434/api/tags

# Start Ollama if not running (macOS)
brew services start ollama

# Or start in background
ollama serve
```

### 2. Pull and Verify the Model

```bash
# Pull the model
ollama pull qwen2.5-coder:32b

# Verify model is available
ollama list
```

### 3. Test the Connection

```bash
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-coder",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 50
  }'
```

## Codex CLI Integration

You can use OpenAI Codex CLI with Ollama's qwen2.5-coder:32b as the backend — Codex becomes a local coding agent.

### Using Codex CLI with Ollama

```bash
export PATH="/opt/homebrew/opt/ollama/bin:$PATH"   # Use brew-installed Ollama (0.24+)

# One-shot task in any git repo
cd ~/my-project && codex --oss --local-provider ollama --model qwen2.5-coder:32b exec "Your task here"

# With sandbox write access
cd ~/my-project && codex --oss --local-provider ollama --model qwen2.5-coder:32b exec "Create hello.py with def say(): return 'Hello'" --sandbox workspace-write
```

**Key flags for Ollama:**
- `--oss` — use open-source provider
- `--local-provider ollama` — connect to local Ollama
- `--model qwen2.5-coder:32b` — use the 32B coder model
- `--sandbox workspace-write` — allow file creation (replaces deprecated `--full-auto`)
- `--approval never` — skip per-command approval

**From scratch (Codex needs a git repo):**
```bash
cd $(mktemp -d) && git init && codex --oss --local-provider ollama --model qwen2.5-coder:32b exec "Build a snake game in Python"
```

⚠️ **First-run cold start:** qwen2.5-coder:32b is ~24 tok/s. First call may timeout. Retry — model stays warm in Ollama.

### Codex App (GUI) with Ollama

Ollama 0.24+ can integrate with the Codex App (macOS GUI):

```bash
export PATH="/opt/homebrew/opt/ollama/bin:$PATH"
ollama launch codex-app --model qwen2.5-coder:32b --yes
```

This sets Codex App's profile to use Ollama. Open Codex App normally — it will use qwen2.5-coder:32b locally.

## Usage Patterns

### One-Shot Coding Tasks

Delegate a single coding task:

```bash
hermes delegate --provider ollama-qwen-coder --task "Write a Python function to parse JSON config files"
```

### Delegating Complex Tasks via Subagent (Recommended)

For multi-file coding projects, use `delegate_task` with `role=leaf` so the subagent can't re-delegate:

```python
delegate_task(
    goal="Write a TokenBucket rate limiter class with async support and pytest tests. Save to /path/to/project/",
    context="Use Ollama at http://localhost:11434/v1 with model qwen2.5-coder. Create: token_bucket.py, test_token_bucket.py, README.md. Run all tests and report results.",
    role="leaf",
    toolsets=["terminal", "file"]
)
```

**Effective delegate_task patterns:**
- **Always set `role=leaf`** — prevents re-delegation, keeps context clean
- **Put the full file creation plan in `goal`** — paths, filenames, what to create
- **Put Ollama connection details in `context`** — base_url, model name, what to output
- **Ask for a summary report in `goal`** — what files were created, test results, any issues
- **Use `toolsets=["terminal", "file"]`** — terminal for commands/tests, file for reading
- **Be specific in `goal`** — list exact filenames, include "run pytest and report results"
- The parent agent runs at normal speed; subagent runs at Ollama speed (~24 tok/s for qwen2.5-coder:32b)

## Best Practices

### Prompt Engineering

- **Be specific**: Include file paths, function signatures, and expected behavior
- **Set context**: Mention existing code structure or dependencies
- **Define constraints**: Specify Python version, async requirements, error handling

### Model Configuration

| Parameter | Recommended for Code |
|-----------|----------------------|
| `temperature` | 0.2–0.4 |
| `max_tokens` | 4000–8000 |
| `top_p` | 0.95 |
| `repeat_penalty` | 1.1 |

### Task Chunking

Break large tasks into smaller pieces:
- ✅ Good: "Write a UserService class with login/logout methods"
- ❌ Bad: "Write an entire authentication system with 20 endpoints"

## Common Pitfalls

| Issue | Fix |
|-------|-----|
| First request times out | Pre-warm: `curl -d '{"model":"qwen2.5-coder","prompt":"boot"}' http://localhost:11434/api/generate` |
| OOM crashes | Use quantized: `ollama pull qwen2.5-coder:32b-q4_K_M` |
| Slow cold start | Keep model loaded, use streaming for long responses |
| Truncated responses | Increase `max_tokens` in provider config |
| JSON parsing errors | Add retry logic (httpx + tenacity) |

## Error Handling

```python
import httpx
from tenacity import retry, stop_after_attempt, wait_exponential

@retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=2, max=10))
async def call_ollama(messages: list[dict], max_tokens: int = 4000) -> dict:
    async with httpx.AsyncClient(timeout=120.0) as client:
        response = await client.post(
            "http://localhost:11434/v1/chat/completions",
            json={
                "model": "qwen2.5-coder",
                "messages": messages,
                "max_tokens": max_tokens,
                "temperature": 0.3
            }
        )
        response.raise_for_status()
        return response.json()
```

## Testing Generated Code

```bash
# Syntax check
python -m py_compile generated_code.py

# Run tests
pytest tests/ -v

# Type checking
mypy generated_code.py --strict
```

## Security

- Ollama runs locally — no data leaves your machine
- No API key required for local instances
- Model weights stay local — no external model API calls