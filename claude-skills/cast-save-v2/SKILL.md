---
name: cast-save-v2
description: Cluster optimization report for cluster(s) the caller names, with console-verified data. Like cast-save (v1) but every reportable number is cross-checked against the CAST AI console (via ego-browser), and accuracy vs the console is scored and saved locally. Use when a TAM asks for an optimization/review/cost report AND data correctness against the console matters, or when asked to score v1 vs v2 accuracy.
---

# cast-save v2 — console-verified optimization report

Difference vs v1 (`cast-save`): v1 trusts CAST AI REST (via MCP or curl) alone. v2 adds a
**console truth pass** (UI scrape of the cluster Dashboard + Rebalancer log) and treats the
console as ground truth for live numbers (node count, spot count, unscheduled pods, OOM kills,
last completed rebalance). It also emits an **accuracy.json** per cluster and a scored
**accuracy table** comparing the report's claims to the console.

## Data sources, in priority order

1. **Live numbers (console = truth)** — `console_scrape.mjs <taskspace> <pageId> <clusterId> <orgId>`
   via ego-browser (user must be signed into console.eu.cast.ai once). Returns JSON with
   `nodes, spot, pods, unsched, oom, lastWhen, lastSave, lastPlan, never`.
2. **Analysis inputs (REST)** — prefer the **castai / castai-eu MCP** servers when their tools
   answer (read-only OpenAPI proxies). Auth for MCP tokens is per-region and can break
   (429/401); fall back to curl against `https://api.eu.cast.ai` with headers:
   `X-API-Key`, `X-CastAi-Organization-Id: <orgId>`, `User-Agent: curl/8.7.1`
   (the last one is mandatory — Cloudflare 1010-bans python-urllib UAs).
3. **Endpoints** (same as v1): audit-events, cost-metrics/clusters/<id>, nodes (often empty for
   Cloud-Connect), evictor installation-cost-, workloads, workloads/inventory,
   problematic-workloads + problematic-nodes (optional, 500s are tolerated),
   spotsignal unscheduled-pods, write-back node-templates + node-configurations,
   rebalancing-schedules + plans/generated + plans/executed + last plan,
   workload-autoscaling-policies + workloads, workload-event-metrics.

## Workflow

1. Get `clusterId` + `orgId` from cluster-lists (org headers required for enterprise tokens).
2. Fetch REST payloads into a run dir (same file names as v1).
3. Console truth pass: sign in once (ask the user if agent identity can't log in — TAM Google
   workspace handles SAML), then run `console_scrape.mjs` per cluster → console row.
4. Analyze: `python3 analyze_v2.py --dir <rundir> --cluster <name> --cluster-id <id> --org <org>
   --reviewer <tam> --console <console-scrape.json> --rank <n>` → produces
   `cast_optimise_data.json` (Step-9a schema, console-overlaid) + `accuracy.json` (report claims).
5. Render PDF with `generate_cast_optimise_report.py` (copied from v1, unchanged schema).
6. Score: `python3 score_accuracy.py --manifest <runs.json> --truth <truth-file> --out <dir>`
   → `accuracy-table.md` + `all.json`. Compare with a v1-only run to get the v1-vs-v2 table.

## Overlay rules (console wins)

- `nt_resource_profile.total_nodes/templates[].node_count` ← console `nodes` (live count).
- Exec summary "100% on-demand" claim is only emitted when console `spot == 0` AND nodes > 0;
  when spot > 0, state the real spot count.
- STALLED high-priority item when last completed rebalance > 30 days old.
- OOM note when console `oom >= 50` (24h window).
- `console_verified` block is written into the data JSON as provenance.

## Scored metrics (per cluster, vs console)

`nodes` (±10%) · `spot` (±10%/±1) · `unsched` (±1) · `rebal_healthy` (ACTIVE iff last completed
≤ 3 days) · `last_reb_savings` (≤30% full, ≤60% half) · `oom_flag` (bool). Average = accuracy.

## Known limits

- v2 reuses the v1 analysis core (`analyze.py`) via runpy; schedule-name matching inside the
  data JSON is restored post-hoc from raw payloads.
- Console scrape needs a signed-in ego-browser session (EU console); without it, v2 degrades
  to v1 output plus an `accuracy.json` with `truth: null`.
- MCP servers expose read-only GET proxies — no Loki/snapshot/WOOP-special tools; those remain
  degraded (flagged in the report's coverage section).
