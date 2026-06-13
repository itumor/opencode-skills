# OpenCode Zen — Models & Pricing Reference

**Source:** https://opencode.ai/docs/zen (scraped May 2026)
**Endpoint:** `https://opencode.ai/zen/v1/chat/completions` (OpenAI-compatible)

## Free Models (no API key required in Herme's config)

| Model ID | Notes |
|---|---|
| `minimax-m2.5-free` | **Default.** Used by this user's cron jobs and main session. Available "for a limited time." |
| `deepseek-v4-flash-free` | Available for limited time (team collecting feedback) |
| `nemotron-3-super-free` | Available for limited time |
| `big-pickle` | Stealth/free model, limited time |

## Paid Models (pay-as-you-go, $ per 1M tokens)

### Budget (under $1/M input)
| Model | Input | Output |
|---|---|---|
| Qwen3.5 Plus | $0.20 | $1.20 |
| Kimi K2.5 | $0.60 | $3.00 |
| Gemini 3 Flash | $0.50 | $3.00 |
| GPT-5.4 Nano | $0.20 | $1.25 |
| GPT-5.1 Codex Mini | $0.25 | $2.00 |

### Mid-tier ($0.75–$3/M input)
| Model | Input | Output |
|---|---|---|
| GPT-5.4 Mini | $0.75 | $4.50 |
| GPT-5.2 / GPT-5.3 Codex | $1.75 | $14.00 |
| GPT-5.1 / GPT-5 | $1.07 | $8.50 |
| Claude Haiku 4.5 | $1.00 | $5.00 |
| MiniMax M2.7 / M2.5 | $0.30 | $1.20 |

### Premium ($3+/M input)
| Model | Input | Output |
|---|---|---|
| Claude Sonnet 4.5 / 4.6 | $3.00 | $15.00 |
| GPT-5.4 | $2.50 | $15.00 |
| GPT-5.5 | $5.00 | $30.00 |
| Claude Opus 4.x | $5.00 | $25.00 |
| GPT-5.5 Pro / GPT-5.4 Pro | $30.00 | $180.00 |

Cached reads are cheap ($0.02–$0.50/M). Cached writes vary ($0.005–$30/M).

## How Billing Works

- **Pay-as-you-go** — add $20, auto-reload when balance < $5 (configurable)
- **Monthly spend limits** — set per workspace or per team member
- **No subscription** — only pay for what you use
- **Credit card fees:** 4.4% + $0.30 per transaction (passed through at cost)

## This User's Setup

```yaml
model:
  provider: opencode-zen
  default: minimax-m2.5-free
  base_url: https://opencode.ai/zen/v1
  api_key: no-key-required
  max_tokens: 16000
  api_mode: chat_completions

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

All 8 cron jobs migrated from GPT-5.4-mini to `minimax-m2.5-free` on May 16, 2026.