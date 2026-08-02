---
name: terse-status-updates
description: Use when drafting a Slack/Teams DM reply to Girts (or any direct, skeptical, or micromanaging lead), or writing a Jira/Confluence status comment about tooling, environment, or CICD3 readiness. Triggers on sharp questions like "ready or not?", "correct role?", "where is X coming from?", and on the urge to write a long AI-style update with hedging ("I believe", "should be", "~95%").
---

# Terse Status Updates

## Overview

Girts reacts badly to uncertainty and long AI-style updates. He asks direct questions ("ready or not?", "correct role?", "where is the dockerhub user coming from?"). Answer like an engineer: **short, factual, evidence-based**. No big explanation unless asked.

**Core principle:** make him feel he has visibility without chasing you every hour. That reduces micromanagement without creating conflict. Long reassurance does the opposite — it reads as covering for uncertainty.

## When to use

- Replying to Girts (or any blunt/skeptical lead) in DM
- A sharp or accusatory question ("are you sure that's the correct role?")
- Writing a Jira / Confluence / Slack-thread status comment
- You feel the urge to explain, reassure, or hedge

**When NOT to use:** he explicitly asks for detail/reasoning ("walk me through it") — then give the full explanation.

## The five rules

1. **Short answers only.** Status, blocker, owner, next action. Nothing else.
2. **One status source.** Put current state + blockers + owner + next update in ONE place (Jira comment / thread). Ask to move follow-ups there. Kills random per-hour DM questions.
3. **Banned words.** Never: "AI", "I believe", "I think", "~95%", "should be", "probably", "off the top of my head", "happy to", "totally open to". Use: "Done", "Blocked by X", "Testing pending", "Owner: DNS team", "Confirming now".
4. **Don't defend yourself on sharp questions.** Answer with evidence, then action. No "open to being wrong", no apology, no justification narrative.
5. **No ETA you don't control.** Give ETA only for work you own. Otherwise name the owner.

## Status format (every update)

```text
Status: Not ready / Ready
Reason: <one clear reason>
Owner: <team/person>
Next action: <what you are doing>
Next update: <date/time or "after ticket resolved">
```

## Examples (before = rambling, after = engineer)

**Q: "where is the dockerhub user coming from?"** (you don't know yet)
- ❌ "Not 100% sure off the top of my head — I think it's a registry user we set up… let me confirm rather than guess…"
- ✅ `Checking Nexus config now, confirming where the dockerhub user is defined. Update within the hour.`

**Q: "CICD3 — ready or not?"** (blocked on DNS team)
- ❌ "Ready except one thing… I've got the request in but don't control their timeline… happy to escalate if you want."
- ✅
```text
Status: Not ready
Reason: DNS record missing, blocks pipeline test
Owner: DNS team (request filed)
Next action: chasing DNS team today
Next update: when record lands
```

**Q: "are you sure that's the correct role?"** (you verified it)
- ❌ "Yeah, I double-checked… that said, totally open to being wrong, happy to walk through it together…"
- ✅ `Verified against CAA reference — policy diff is clean, no deltas. If you see a specific delta, point me at it and I'll re-check.`

## Consolidation move (send once)

> I'll put tooling status, open blockers, and next actions in one Jira thread so CICD3 readiness is tracked in one place instead of separate DM questions.

## Red flags — STOP and rewrite

- Message longer than 3 sentences (and he didn't ask for detail)
- Any banned word present
- Explaining *why* before stating *what*
- Defending or apologizing instead of evidence + next action
- Promising an ETA on work another team owns

Background on the approach: managing up = intentionally shaping the working relationship for better outcomes; for micromanagement, clarifying expectations + update rhythm is the recommended fix (HBR, "Managing Your Boss").
