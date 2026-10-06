---
name: iac-repo-field-guide
description: Use when asked to refresh, update, rebuild or re-publish the EIS iac "field guide" doc page, or to write a doc/overview page about the ~/gitwork/iac tree (repos, modules, templates, ArgoCD, Ansible, workflow, harness). Re-surveys the tree with 4 read-only sub-agents and republishes the HTML artifact.
---

# iac field guide: refresh procedure

Published 2026-10-03 as a private Artifact: https://claude.ai/artifact/TqYn3ExYK94YXmsA4LG5pT (source: `guide.html` next to this file). Sections: overview, how it fits (SVG), repo map, modules, templates, client table, network hub, ArgoCD, Ansible, solutions, change workflow, harness guardrails, known drift, glossary.

## Refresh steps
1. `Read` `guide.html` here. It is the page source; the original scratchpad copy is gone after the session.
2. Spawn 4 `general-purpose` agents in ONE message, `run_in_background`, read-only, each writing notes to the scratchpad (cite file paths, mark UNVERIFIED, list discrepancies vs `docs/repo-map.md`):
   - A `terraform/modules/aws/*` (purpose, local tag vs top tag, wraps, conventions)
   - B `terraform/template/*` + `projects/aws/*` (Copier mechanics, rendered layout, Atlantis, client table, network-hub)
   - C `argocd/*` + `ansible/*` (hub topology, appsets, components, roles, template branch state)
   - D `solutions/*` + `.claude` harness + `CLAUDE.md` + `docs/*` (hooks, rules, workflow, stale-doc list, glossary)
   Prompt rules to include: never modify the tree; never read `.env`, `secrets.txt`, `account.env`, `settings.local.json`; no git mutations (`describe`/`log`/`branch --show-current` only, no fetch).
3. Spot-check headline counts on disk before trusting them:
   `ls -d terraform/modules/aws/eis-* | wc -l`; `ls argocd/argocd/clusters | wc -l`; `ls -d argocd/argocd/components/*/ | wc -l`; `ls .claude/hooks`.
4. Edit `guide.html` (keep the token block, dark-mode blocks, drift table). Republish with `Artifact` `action: publish`, `url` = the URL above, `file_path` = the edited file (a different session must read the artifact first).
5. Do not publish tokens, SAML URLs or Vault values. Account IDs are in the client table; the artifact is private, so tell the user before it is shared.

## Gotchas
- Tags/branches come from LOCAL clones; many clones sit on feature branches or behind origin. Say so on the page.
- `eis-opensearch` default branch is `master`; `eis-waf` origin/HEAD is not main.
- Artifact quickstart for `document` points at the Docs connector type; this page was published as a plain HTML artifact instead (private by default).
