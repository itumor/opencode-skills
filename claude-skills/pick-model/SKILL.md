---
name: "pick-model"
description: "Use before dispatching a subagent (Agent tool) to pick haiku/sonnet/opus by task shape instead of defaulting to one model — recommends the right model up front rather than retrying after a bad result."
---

# Pick Model

Recommends `haiku` / `sonnet` / `opus` for a subagent `Agent()` call based on the task
text and agent type, before dispatch. No mid-task quality retry exists — hooks can't
inspect an agent's output, so this picks correctly up front instead.

## Usage

```bash
MODEL=$(~/.claude/scripts/pick-model.sh "task description" [agent_type])
```

Pass `$MODEL` as the `model` param on the Agent tool call.

## Routing (first match wins)

1. `agent_type` override — `security-auditor` / `tf-plan-auditor` / `code-quality-reviewer` / `iac-live-verifier` → `opus`; `Explore` / `cavecrew-investigator` → `haiku`.
2. Task text has security/destroy/prod/architecture stakes (security, credential, secret, encrypt, destroy, "blast radius", production, architecture, breaking, "iam policy") → `opus`.
3. Task text is pure lookup (starts with locate/find/grep, or has "where is"/"which file"/"search for"/"look up") → `haiku`.
4. Else → `sonnet`.

Test: `~/.claude/scripts/pick-model.sh --selftest` (12 checks).

Gotcha: bare "review" with no security/destroy keyword falls to `sonnet`, not `haiku` — synthesis needs judgment, not lookup. Don't add "review" to the haiku list.

See memory `pick_model_subagent_routing.md` for the fuller story (why upfront routing, not fallback-on-failure).
