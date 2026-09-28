---
name: kimchi-router
description: >
  Model-selection "switch" for the kimchi LLM provider (llm.kimchi.dev). Routes every
  subagent/delegation to the best verified model for the task class, using a local
  63-call benchmark (correctness, speed, reasoning-token burn, price) run on
  2026-09-17, and knows which configured model IDs are dead (deprecated 410,
  unregistered 400, quota-blocked 429). Use this skill whenever you are about to spawn
  a subagent via provider "kimchi", whenever the user asks "which model should I use",
  "pick a model", "route this", mentions the model switch/router, or whenever choosing
  between kimi, glm, minimax, deepseek, nemotron, or lyria models available through
  kimchi — even if the user does not explicitly mention routing. Also consult it when a
  subagent returns empty content or a model error, to pick the fallback.
  Trigger: "which model", "route sub-agent", "model switch", "use the router",
  "spawn a subagent", "delegate this", "pick the best model".
---

# kimchi-router

An empirical routing table for `subagent(provider="kimchi", model=...)` calls.
Ground truth: local benchmark, 7 deterministic tasks × 9 reachable models, temperature 0,
plus connectivity probes of all 16 configured model IDs. Report with raw data:
`/Users/eramadan/Documents/castai/kimchi-benchmark-report.md` (2026-09-17).

Routing beats habit: on this provider, name recognition and public leaderboards were both
misleading — the cheapest model (`glm-5.3-flash`) scored a perfect 7/7 while the most
expensive (`kimi-k3`) failed a task by silently exhausting its token budget on hidden
reasoning. Follow the table, not vibes.

## Verified model cards

| Model | Score | Speed | $/1M out | Personality |
|---|---|---|---|---|
| `glm-5.3-flash` | 7/7 | 79 t/s | $0.50 | DEFAULT. Perfect score at lowest cost. |
| `nemotron-3-ultra-fp4` | 7/7 | 334 t/s | $2.20 | SPEED KING. Zero reasoning burn; never truncates. |
| `glm-5.3` | 7/7 | 57 t/s | $4.00 | Slow quality anchor; strongest on precise math. |
| `kimi-k3` | 6/7 | 168 t/s | $14.25 | Deepest reasoning; 40× flash cost; truncates under tight budgets. |
| `kimi-k2.7` | 6/7 | 96 t/s | $3.40 | Fine, but dominated by glm-5.3 family on every axis. |
| `minimax-m3` | 6/7 | 95 t/s | $0.96 | Cheap balanced; truncates under tight budgets. |
| `deepseek-v4-flash-0731` | 4/7 | ~216 t/s | $0.18 | Fast non-reasoner; FAILS exact arithmetic and word-count limits. |
| `deepseek-v4-flash` | 4/7 | ~230 t/s | $0.18 | Strictly dominated by -0731. Never route. |
| `glm-5.2-fp8` | 7/7 | 57 t/s | $4.40 | Strictly dominated by glm-5.3 (same correctness, slower, pricier). Never route. |

## Dead model IDs — never route, tell the user to remove from config

| Model | Status | API truth |
|---|---|---|
| `minimax-m2.7` | 410 | "no longer available. Use minimax-m3 instead." |
| `kimi-k2.6` | 410 | "no longer available. Use kimi-k2.7 instead." |
| `nemotron-3-super-fp4` | 410 | "no longer available. Use nemotron-3-ultra-fp4 instead." |
| `kimi-k2.5` | 400 | "no registered providers found" |
| `minimax-m2.5` | 400 | "no registered providers found" |
| `lyria-3-pro-preview` | 429 | quota exceeded on this kimchi plan |
| `lyria-3-clip-preview` | 429 | quota exceeded on this kimchi plan |

## Decision procedure

Classify the delegated task, then pick by these rules (first matching rule wins):

1. **Exact numbers, arithmetic, currency, counts, precision-critical extraction**
   → `glm-5.3` (or `glm-5.3-flash` if volume/cost matters). NEVER `deepseek-v4-flash*`
   — both variants answered 1287 instead of 1251 and 120 instead of 144 at temperature 0.
2. **Low-latency / interactive / long streamed output**
   → `nemotron-3-ultra-fp4` (334 t/s, perfect score, no hidden thinking).
3. **Tight max_tokens budget or strict one-shot output format (regex, single-line JSON,
   exact string)**
   → `nemotron-3-ultra-fp4` or `deepseek-v4-flash-0731`. Do NOT use `kimi-k3`,
   `kimi-k2.7`, or `minimax-m3` here — each returned EMPTY CONTENT when its reasoning
   ate the whole budget. If you must use them, give max_tokens ≥ 3500.
4. **Deep multi-step reasoning: architecture design, gnarly debugging, research synthesis**
   → `kimi-k3` when quality justifies cost (warn the user it's ~40× flash pricing),
   else `glm-5.3`.
5. **Bulk, non-critical work (log triage, rough drafts, throwaway summaries)**
   → `deepseek-v4-flash-0731` ($0.18/1M out, blazing) — accept sloppy numbers/word counts.
6. **Anything else (default)**
   → `glm-5.3-flash`.

## Fallback rules (apply after any subagent run)

- **Empty content returned** → the model truncated on reasoning. Retry once with the same
  model at ≥2× max_tokens; if still empty, rerun with `glm-5.3-flash`.
- **HTTP 400/410** → model ID is dead; reroute per the dead-table mapping above and note
  the config entry for removal.
- **HTTP 429** → quota for that family is exhausted; reroute to the default and tell the
  user to check their kimchi plan.
- **Wrong-but-confident output on a numeric task** → rerun with `glm-5.3` and compare
  before trusting.

## Cost cheat (measured, 7-task suite, public rates)

Whole-suite cost per model: glm-5.3-flash $0.0015 · deepseek-0731 $0.0001 · minimax-m3
$0.0047 · nemotron-ultra $0.0098 · kimi-k2.7 $0.0147 · glm-5.3 $0.0153 · kimi-k3 $0.0590.
Reasoning models burn 60–100% of tokens invisibly — budget for completion_tokens, not
visible output.
