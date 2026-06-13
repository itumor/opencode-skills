---
name: gitops-scorecard
description: Use when asked to assess, score, or audit a GitOps/ArgoCD setup against the OpenGitOps principles, GitOps best practices, benefits, or maturity model — "are we GitOps compliant", "how do we score", "what are we missing", or when building a GitOps gap-closure roadmap for the EIS iac/argocd/argocd repo or any ArgoCD monorepo.
---

# GitOps Scorecard

## Overview

Evidence-based scoring of an ArgoCD repo against OpenGitOps v1.0.0 (4 principles) + 18 best practices. Rule: **never score from memory of the repo — grep for the mechanism, score from the hit.** Each row needs file:line evidence or it scores 0.

## Step 1 — Gather evidence (one pass)

From repo root (e.g. `/Users/eramadan/gitwork/iac/argocd/argocd`):

```bash
# Pull + reconcile loop
grep -rn "requeueAfterSeconds\|selfHeal\|prune" apps/appsets/
# RBAC / project gating
grep -rln "kind: AppProject" .
# Secrets (must be external, never committed)
ls components/external-secrets-operator 2>/dev/null
# CI gate hardness — allow_failure:true = advisory, NOT blocking
grep -nE "allow_failure|stages:" .gitlab-ci.yml
# Notifications / alerting on sync failure
grep -rli "argocd-notifications" components apps bootstrap
# Progressive delivery
grep -rli "argo-rollouts\|kind: Rollout" components
# Self-management (ArgoCD managing its own install)
ls components/ | grep -i "^argo"
# Floating image tags
grep -rn ":latest" components/*/values.yaml clusters/*/*/values.yaml
```

## Step 2 — Score the 4 principles

| Principle | Evidence that earns the point |
|-----------|------------------------------|
| 1 Declarative | Helm charts / manifests only, no imperative deploy scripts |
| 2 Versioned+Immutable | Git source of truth, MR-gated, chart deps pinned (`Chart.lock`) |
| 3 Pulled Automatically | ArgoCD pull model, git generator `requeueAfterSeconds`, no CI `kubectl apply` |
| 4 Continuously Reconciled | `automated{prune,selfHeal}`; deduct only for **runtime** state needing manual restarts |

**Key nuance:** `ignoreDifferences` on HPA-managed fields/replicas is NOT a violation — official ArgoCD docs call it "leaving room for imperativeness". Only deduct for undocumented or stale ignore entries.

## Step 3 — Score 18 best practices

Core 12: sole source of truth, declarative-everything, config≠code repo, no secrets in Git, pull not push, layered/DRY values, **blocking** CI gates, Git-based promotion, least-privilege AppProjects, observability+backup, ApplicationSet/app-of-apps at scale, idempotent+ordered apply (sync waves, SSA, PruneLast).

Extended 6 (research 2026-06): pin manifests truly immutable (tags/SHA not floating), image tags = commit SHA (ban `:latest`), drift/sync metrics dashboards, progressive delivery (Rollouts/Flagger = top maturity level), repo-server DoS cap (`reposerver.max.combined.directory.manifests.size`), minimized spoke ClusterRole + repo allow-list.

## Common scoring traps

| Trap | Reality |
|------|---------|
| CI has security jobs → score full | Check `allow_failure: true` — advisory jobs don't gate merges |
| Velero present → backup covered | Velero covers workloads; ArgoCD hub control-plane needs own DR runbook |
| AppProjects exist → RBAC done | Look for `allow-everything-AppProject` escape hatch |
| selfHeal on → reconcile 100% | Manifests reconcile; runtime state (istio route reload, secret-driven restarts) may not — check for Reloader |
| ApplicationSet manages fleet → self-managed | ArgoCD's own install often Terraform-bootstrapped, outside GitOps |

## Standard gap-closure backlog (ordered, S→L)

1. argocd-notifications → Slack on sync-failed/degraded (S)
2. Drop `allow_failure: true` on render/validate CI jobs (S)
3. Document every `ignoreDifferences` entry with a "why" (S)
4. Reloader fleet component — auto-restart on Secret/ConfigMap change (S-M)
5. RBAC hardening: scope/remove allow-everything project, project-scoped JWT tokens (M)
6. Hub DR runbook + Velero include `argocd` namespace (M)
7. ArgoCD self-management component (M-L)
8. Argo Rollouts eval on playground component (L)

## References

ArgoCD best practices: https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/
ArgoCD security: https://argo-cd.readthedocs.io/en/stable/operator-manual/security/
OpenGitOps: https://opengitops.dev/ — maturity model: https://octopus.com/devops/gitops/gitops-maturity-model/

EIS baseline 2026-06-12: principles 3.9/4, practices 10.8/12 — details in memory `gitops-scorecard-argocd-2026-06`.
