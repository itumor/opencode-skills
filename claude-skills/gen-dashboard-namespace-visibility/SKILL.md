---
name: gen-dashboard-namespace-visibility
description: Use when a namespace or its services are hidden/missing/not visible on an EIS OneSuite K8S dashboard (gen-dashboard, URL pattern dashboard-monitoring.<domain>), when a team reports they can't see or navigate deployed services, when a newly created namespace doesn't appear in the dashboard's namespace selector, or when working with gen-dashboard config (dashboard-config/dashboard-templates ConfigMaps, dashboard-auth secret, service templates, health-checks, LDAP rwGroups, external services).
---

# gen-dashboard Namespace Visibility

The OneSuite K8S dashboard (`gen-dashboard` component in `iac/argocd/argocd`) displays ONLY namespaces listed in `oneSuiteDashboardConfig.namespaces`. Chart default: `[loki, monitoring]` (`components/gen-dashboard/values.yaml`). Any namespace not in the list is invisible — this is config, not RBAC and not a bug.

Displayed = allowlist ∩ namespaces that actually EXIST on the cluster: a configured-but-not-created namespace is silently absent too (not drift).

**Full config architecture** (all 3 config resources, service templates, auth-to-services, RBAC, API map, fleet host matrix): see reference.md in this skill directory.

## Diagnose (2 commands)

```bash
# 1. Namespace exists with workloads?
kubectl --context <cluster> get deploy -n <ns>

# 2. What does the dashboard currently show? (unauthenticated)
curl -sk https://dashboard-monitoring.<domain>/api/namespaces
```

`<domain>` = the dashboard host minus the `dashboard-monitoring.` prefix (e.g. `demo.aws0.fv.eisdemo.cloud`). `<cluster>` = kubeconfig context, named after the EKS cluster (e.g. `aws0fvdemoeks01`).

If the namespace is missing from the API response → values fix below. Cross-check live config: `kubectl --context <cluster> get cm dashboard-config -n monitoring -o jsonpath='{.data.config\.yaml}' | head -5`

## Fix

Edit `clusters/<cluster>/gen-dashboard/values.yaml` in `iac/argocd/argocd`:

```yaml
oneSuiteDashboardConfig:
  namespaces:
    - loki        # MUST repeat defaults —
    - monitoring  # Helm lists REPLACE, never merge
    - <new-ns>
```

Optional local render check:
```bash
helm template t components/gen-dashboard -f components/gen-dashboard/values.yaml \
  -f clusters/<cluster>/gen-dashboard/values.yaml | grep -A6 "namespaces:"
```

MR → merge once render/validate/test stages green (don't wait on checkov). ArgoCD hub app `gen-dashboard-<cluster>` auto-syncs the `dashboard-config` ConfigMap.

## After merge: do NOT restart the pod

The app has **no ConfigMap volume mount** — it reads `dashboard-config` via the K8s API (SA `dashboard-controller`) and hot-reloads within ~1 min. A `rollout restart` is unnecessary.

## Verify

```bash
curl -sk https://dashboard-monitoring.<domain>/api/namespaces
# expect <new-ns> present in the JSON array — check membership, not order (API may reorder)
curl -sk "https://dashboard-monitoring.<domain>/api/namespace/<new-ns>/virtual-services-grouped"
# expect: 200 + virtualServicesGrouped listing the namespace's services
```

App is FastAPI — full API surface at `/openapi.json`. Read endpoints are unauthenticated even though `dashboardAuth.type: ldap` (auth gates the UI login, not these APIs).

## Common Mistakes

| Mistake | Reality |
|---------|---------|
| Override lists only the new namespace | List replaces default — dashboard loses loki/monitoring. Always repeat them. |
| `rollout restart` after ConfigMap change | Wasted downtime — app hot-reloads via K8s API. |
| Guessing API paths (`/api/services`, `/api/ingresses`) | 404. Check `/openapi.json`; services live at `/api/namespace/{ns}/virtual-services-grouped`. |
| Hunting RBAC/oauth for "hidden" namespace | Not RBAC. It's the `namespaces:` allowlist. |
| Editing `components/gen-dashboard/values.yaml` default | Fleet-wide blast radius. Use the per-cluster override. |

Example: afa-fv01 on aws0fvdemoeks01 — MR !278, merged 2026-06-04.
