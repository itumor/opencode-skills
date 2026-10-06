---
name: iac-field-guide-refresh
description: Use when asked to document, map, or "create a doc page/website" about the iac workspace, or to refresh the EIS IaC Field Guide artifact (https://claude.ai/artifact/TjMQzeGfwakSedQv9NxyHr) after repos, modules, skills or hooks changed. Fan-out read-only survey, then publish an HTML Artifact in place.
---

# iac field guide: survey and republish

Output = one private Artifact page, "EIS IaC Field Guide". Sections: shape of tree, how pieces fit (mermaid), modules, templates, client envs, ArgoCD hub, ansible+solutions, change flow, guardrails+skills, gotchas, first day, doc drift.

## Steps
1. `Artifact action:read url:<above>` to get the current HTML (the original file lived in a session scratchpad and is gone). Edit that copy, never rebuild from scratch.
2. Read `docs/repo-map.md`, `CLAUDE.md` for the baseline. Treat both as possibly stale.
3. Spawn 3 `general-purpose` agents in ONE message, `run_in_background: true`, each READ-ONLY, each writing `notes-*.md` into the scratchpad and replying in <=15 lines:
   - A: `terraform/modules/aws/*` + `terraform/template/*`
   - B: `argocd/argocd`, `argocd/template/clusters`, `ansible/*`, `projects/aws/*`, `solutions/*`
   - C: `~/.claude/harness/iac` (hooks, rules, agents), `~/.claude/skills` counts, `docs/`
   Prompt must say: never open `/Users/eramadan/gitwork/iac/secrets.txt`, `.env`, `account.env`, secret tfvars; omit account IDs/credentials; count from `git ls-tree origin/main` not the working tree (many clones sit on feature branches); no network/mutating commands.
4. Wait for the task notifications. Foreground `sleep` is blocked by the harness; do not poll.
5. Diff agent numbers against the page, update counts/tables, add new drift items. Refresh the "Where the older docs are wrong" section from `memory/iac_survey_verified_facts_20261003.md`.
6. Publish with the same `url` (keeps link). Page is private; tell user to share via the Share menu. Keep out of the page: account IDs, tokens, secret paths with values.

## Traps
- Local counts lie (39 vs 37 components); recount from origin/main.
- Do not copy `docs/ONBOARDING.md` snippets (`glab mr merge`, `(COEXT-N)` format break hard rules).
- Page title must stay stable across republishes.
- mermaid renders natively in Artifacts via `<pre class="mermaid">`; no library.
