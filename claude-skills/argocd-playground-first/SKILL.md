---
name: argocd-playground-first
description: Use for ANY change to iac/argocd/argocd components/<component>/ (values, Chart.yaml, templates, vendored subchart bumps) — and when the pre-push hook denies with "playground-first". The change lands in components-playground/<component>/ first, syncs to aws0prefdeveks01 (pref-dev), gets an end-to-end proof there (incl. no data loss for stateful parts like Thanos/Loki/Tempo/Velero), and only then is promoted to components/ (9+ clusters) in a second MR. Triggers - "change observascope/istio/velero/... values for all clusters", "fix in components/", "promote playground to components", "test on playground first".
---

# ArgoCD components: playground first, then components

## Why
`components/<c>` feeds the `all-components` ApplicationSet: every enabled cluster except aws0prefdeveks01 (9 clusters on 2026-10-08) re-syncs on merge (auto-sync, prune, selfHeal). `components-playground/<c>` feeds `playground-components`, aws0prefdeveks01 only (kubectl context `pref-dev`, account 468381823127, profile `PTO-Reference`). A bad values change in `components/` rolls fleet-wide in ~3 min. GENESIS-428894: !447 put `extraFlags: [--no-debug.halt-on-error]` in both trees at once; Helm replaced the list and silently dropped the subchart's `--delete-delay=20m --wait-interval=30m` on every cluster.

## Enforced
`~/.claude/harness/iac/hooks/playground-first-guard.sh` (called by `pre-push-check.sh`) denies a push whose `components/<c>/<p>` added lines are not already in `origin/main:components-playground/<c>/<p>` (removed lines must be gone there too; Chart.yaml template path normalized). Exempt only with a commit trailer `Playground-First: skip - <JIRA> <why>` (prod hotfix, or a component with no playground dir: aws-inventory, filebeat, istio-authorization-policies, logstash). Say in the MR why.

## Steps
1. **MR1, playground only.** Worktree off fresh origin/main. Edit `components-playground/<c>/...` only. Render before/after for aws0prefdeveks01 (layering = `render-all-helm.sh`: chart values -> `clusters/aws0prefdeveks01/values.yaml` -> `clusters/aws0prefdeveks01/<c>/values.yaml`, plus its CI `--set` overrides) and diff only the objects you meant to change; full-render diff must show nothing else (random secrets/labels differ between any two renders, prove it by rendering twice). `grep -rn <key> clusters/*/<c>/` for per-cluster overrides. gitlab-ci-local from a scratch clone (worktree `.git` breaks it). MR description: render diff, `Disruption:` line, E2E plan with pass criteria.
2. **Baseline before merge (T0).** Live state of every object the change touches on pref-dev (`kubectl --context pref-dev`; never rely on current-context). Stateful components: data inventory (below). Save under `~/.claude/change-runs/<TICKET>-pref-T0.*`.
3. **Gate: user merges MR1.** Arm `~/.claude/scripts/gate-watch.sh mr-merged <repo> <iid>` (skill `iac-change-loop`).
4. **Wait for sync.** GitLab main -> CodeConnections mirror -> ArgoCD (~3 min + mirror lag). Proof = live object shows the new spec (args/env/image), not the MR state. Nudge only via the hub `app-of-apps` refresh annotation (rules/argocd.md).
5. **E2E on pref-dev (T1).** Rollout complete, 0 restarts, no new errors in logs, the behavior itself works (metric/endpoint/log line that proves it), data inventory compare = PASS. Give time-based behavior a full cycle (e.g. Thanos: wait-interval + delete-delay, ≥60 min).
6. **MR2, components/.** New worktree; apply the identical lines to `components/<c>/` (same render diff for one fleet cluster, e.g. aws0iacdeveks01). `git fetch` first so the guard sees MR1 on origin/main. MR2 description links MR1 + pref-dev E2E evidence. Disruption line names all clusters.
7. **After MR2 merge:** spot-check 2 clusters live (one dev, one customer-facing) and record in the state file.

FAIL at step 5 -> revert MR1, no MR2.

## Data-loss proof per stateful component
| Component | Inventory (T0 vs T1) | Tool |
|---|---|---|
| observascope-oss Thanos (compactor/store) | blocks + `deletion-mark.json` + coverage per resolution + store-gateway-only query probes | `~/.claude/scripts/thanos-block-audit.py snapshot\|risk\|compare` (`--context pref-dev --profile PTO-Reference --bucket aws0prefdevobservascope`) |
| observascope-logging Loki | `logcli`/query `count_over_time` per day over retention; chunk prefix counts in the bucket | ad hoc, record queries in the state file |
| tempo | trace search count per day | ad hoc |
| velero / velero-ops | `velero backup get` count + last Completed; restore test of one namespace if schedule/storage touched | skill `eis-velero-backups` |

Thanos facts (from binary help, v0.39.2): `--delete-delay` only removes blocks already carrying `deletion-mark.json` (compaction sources with a replacement, or past retention); store-gateway `--ignore-deletion-marks-delay=24h` hides marked blocks from queries after 24h. `risk` before merge must report 0 marked in-retention blocks without replacement. Query probes need `storeMatch[]={__address__="<store addr>"}` or the sidecar's ~15d local TSDB masks bucket loss.

## Gotchas
- Helm replaces lists: overriding any list (`extraFlags`, `args`, `tolerations`) in `components/<c>/values.yaml` must repeat the subchart defaults. Diff the rendered list, not the values file.
- The two trees already differ in ~80 files; do not "sync" unrelated drift in either MR (scope rule). `scripts/ci/promote-playground-components.sh` copies the whole tree and would ship that drift: do not use it for a single change.
- `render-all-helm.sh` locally: registry.scaleops.com 401 without `SCALEOPS_HELM_*`; park `clusters/*/scaleops` in the scratch clone only.
- `CLUSTER_EXCLUDE=aws0prefdeveks01` in `render_manifests`; the playground renders in `render_manifests_playground` (allow_failure: true), so a broken playground chart does not turn the MR red: read that job.
