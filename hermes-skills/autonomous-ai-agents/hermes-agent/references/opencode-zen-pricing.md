# OpenCode Zen — Model Pricing (May 2026)

**Endpoint:** `https://opencode.ai/zen/v1`
**Auth:** No API key required for free models. Paid models use pay-as-you-go credit system.
**Auto-reload:** When balance < $5, auto-adds $20. Can disable or change amount.
**Monthly limits:** Can set per-workspace and per-member spend caps.

## Free Models (no cost)

| Model ID | Notes |
|---|---|
| `minimax-m2.5-free` | Currently in use. Limited time — OpenCode collecting feedback. |
| `deepseek-v4-flash-free` | Limited time — OpenCode collecting feedback. |
| `nemotron-3-super-free` | Limited time — OpenCode collecting feedback. |
| `big-pickle` | Stealth model. Limited time — OpenCode collecting feedback. |

## Paid Models ($ per 1M tokens — input / output)

| Model | Input | Output | Cached Read |
|---|---|---|---|
| MiniMax M2.7 | $0.30 | $1.20 | $0.06 |
| MiniMax M2.5 | $0.30 | $1.20 | $0.06 |
| Qwen3.5 Plus | $0.20 | $1.20 | $0.02 |
| Qwen3.6 Plus | $0.50 | $3.00 | $0.05 |
| Kimi K2.5 | $0.60 | $3.00 | $0.10 |
| Kimi K2.6 | $0.95 | $4.00 | $0.16 |
| Claude Haiku 4.5 | $1.00 | $5.00 | $0.10 |
| Gemini 3 Flash | $0.50 | $3.00 | $0.05 |
| Claude Sonnet 4.5 | $3.00 | $15.00 | $0.30 |
| Claude Opus 4.7 | $5.00 | $25.00 | $0.50 |
| GPT-5.4 Mini | $0.75 | $4.50 | $0.075 |
| GPT-5.4 Nano | $0.20 | $1.25 | $0.02 |
| GPT-5.2 | $1.75 | $14.00 | $0.175 |

**Credit card fees:** 4.4% + $0.30 per transaction (passed through at cost).

## Full model list

```bash
curl -s https://opencode.ai/zen/v1/models | python3 -m json.tool | grep '"id"'
```

## Setup

1. Sign up at https://opencode.ai/zen
2. Add $20 balance
3. Get API key
4. Connect via `/connect` in OpenCode TUI

For Hermes: set in `config.yaml` under `model.provider: opencode-zen`.

Full docs: https://opencode.ai/docs/zen