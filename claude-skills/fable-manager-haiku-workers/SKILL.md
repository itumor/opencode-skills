---
name: fable-manager-haiku-workers
description: Use whenever the session model is Fable (claude-fable-*) or the user says "you are the manager", "delegate to haiku", "fable manages, haiku works". Fable plans, briefs, reviews and decides; Haiku subagents do the heavy lifting (search, read, edit, build, test, browser checks). Also use when the Agent hook denies "workers must be Haiku".
---

# Fable = manager, Haiku = workers

User rule (2026-11-25): in a Fable session Fable is the mind, Haiku is the hands. Fable does not do heavy lifting.

## Enforcement (already installed, do not re-add)
- Hook `~/.claude/hooks/fable-manager.py` (settings.json: SessionStart, UserPromptSubmit, PreToolUse matcher `Agent`).
- Fable session: injects the manager rule each prompt; **denies any Agent call without `model: "haiku"`, or with `subagent_type: "fork"`** (fork inherits Fable). Other models: no-op. Fail open.
- Escape (ask the user first): `FABLE_MANAGER_SKIP=1`. Test: `python3 ~/.claude/hooks/fable-manager.py --selftest`.

## Fable does
Plan, split into independent pieces, write the brief, dispatch, review every result, verify the facts that matter, decide, answer the user, take gated actions (apply, merge, post, commit after review).

## Haiku does (all with `model: "haiku"`)
Repo/code search and mapping, reading logs and configs, drafting edits in a worktree (`iac-worker` with `model: haiku`), running scans/tests/builds, live read-only AWS/kubectl/GitLab checks (`iac-live-verifier`), browser checks, mechanical same-change-many-targets work.

## Loop
1. Fable: 3-6 line plan, pieces that touch different files/targets.
2. One shared brief FILE per phase (goal, exact commands, auth recipe, output dir, "never print secrets", verdict rules, "stop and report if blocked"). 4-5 input lines per agent.
3. All workers of a phase in ONE message, parallel. Read-only first, then write phase.
4. Fable reviews raw outputs and diffs itself (one summary script). Haiku does not judge intent: it calls "200" proof, maps stale checkouts, reads the wrong file. Spot-check every "not found" and every "unexpected" line.
5. Fable runs the gates (tests, pre-push, handoff). Agent blocked by a guard = surface to the user, do not run it for them.

## Stay in Fable (not worth a brief)
A 1-2 call check, a one-line edit, reading one file to decide, summarizing results, anything needing user judgment or approval.

## Traps
- Brief must be self-contained: Haiku has no conversation context.
- Never hand Haiku real secrets or ask it to read token caches (auto-mode classifier refuses).
- Fetch before mapping a repo (`feedback-fetch-before-mapping-repo`).
- Prior art: `feedback-haiku-fanout-orchestrate-review`, skill `eis-ui-same-origin-behind-cognito-alb` (brief templates), `pick-model` (use only for non-Fable sessions).
- Hook gotchas (11-25): payload has no `model`; first turn is unknown, so the rule is injected conditionally and PreToolUse retries the transcript ~1s. Debug log `/tmp/fable-manager-debug.log` appears only on unknown model. Real-session retest: first message = no-tool question quoting the rule, first tool call = Agent without `model` (expect deny). A Sonnet session cannot start a Fable session; the user does.
