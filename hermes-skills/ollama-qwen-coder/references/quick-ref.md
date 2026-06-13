# Ollama qwen2.5-coder Quick Reference

## Essential Commands

### Check Ollama Status
```bash
curl http://localhost:11434/api/tags
```

### List Available Models
```bash
ollama list
```

### Pull/Update Model
```bash
ollama pull qwen2.5-coder:32b
```

### Pre-warm Model (avoid cold start)
```bash
curl -d '{"model":"qwen2.5-coder","prompt":"boot"}' http://localhost:11434/api/generate
```

### PATH Fix (macOS — Homebrew shadows /usr/local/bin)
```bash
export PATH="/opt/homebrew/opt/ollama/bin:$PATH"
```
Add to `~/.zshrc` for permanent fix.

---

## API Calls

### Chat Completion (Recommended)
```bash
curl -X POST http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-coder",
    "messages": [
      {"role": "system", "content": "You are a Python expert."},
      {"role": "user", "content": "Your request here"}
    ],
    "temperature": 0.3,
    "max_tokens": 4000
  }'
```

---

## Codex CLI (Local Coding Agent)

```bash
export PATH="/opt/homebrew/opt/ollama/bin:$PATH"

# One-shot in any git repo
cd ~/project && codex --oss --local-provider ollama --model qwen2.5-coder:32b exec "Your task"

# With file write access
codex --oss --local-provider ollama --model qwen2.5-coder:32b exec "Create hello.py" --sandbox workspace-write

# From scratch
cd $(mktemp -d) && git init && codex --oss --local-provider ollama --model qwen2.5-coder:32b exec "Build a snake game"
```

---

## Codex App (macOS GUI) with Ollama

```bash
export PATH="/opt/homebrew/opt/ollama/bin:$PATH"
ollama launch codex-app --model qwen2.5-coder:32b --yes
# Then open Codex App normally — it uses Ollama locally
```

---

## Model Parameters

| Parameter | Default | Recommended for Code |
|-----------|---------|----------------------|
| `temperature` | 0.8 | 0.2 - 0.4 |
| `max_tokens` | 4096 | 4000 - 16000 |
| `top_p` | 0.9 | 0.95 |
| `repeat_penalty` | 1.1 | 1.1 - 1.2 |

---

## Common Issues & Fixes

| Issue | Fix |
|-------|-----|
| "model not found" | `ollama pull qwen2.5-coder:32b` |
| Slow cold start | Pre-warm: `curl -d '{"model":"qwen2.5-coder","prompt":"boot"}' http://localhost:11434/api/generate` |
| OOM errors | Use quantized: `ollama pull qwen2.5-coder:32b-q4_K_M` |
| PATH shows 0.23.x | `export PATH="/opt/homebrew/opt/ollama/bin:$PATH"` |
| Codex times out | Normal for 32B (~24 tok/s). Retry — model stays warm. |

---

## Share Local Site (Public URL)

```bash
# Serve locally
python3 -m http.server 9876 &

# Expose with cloudflared
cloudflared tunnel --url http://localhost:9876 --logfile /tmp/cf.log &
sleep 12 && cat /tmp/cf.log | grep -o 'https://[^ ]*trycloudflare[^ ]*'
```
Full details: `references/public-url-sharing.md`
