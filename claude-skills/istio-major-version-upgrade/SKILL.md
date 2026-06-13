---
name: istio-major-version-upgrade
description: Step-by-step playbook for advancing Istio across multiple minor versions through the EIS umbrella charts (istio-base, istiod, istio-ingress-cluster, istio-ingress-namespace, istio-gateway-cluster). Covers subchart flag flips, the name-override-must-move trap, falsy-nodeSelector-default trap, post-merge rolling restart, and rollback. Use when bumping istio more than 1 minor version on any EIS-managed cluster.
---

# Istio major-version upgrade — EIS umbrella charts

Istio supports sidecar / control-plane drift of at most **N-2**. Jumping 1.20 → 1.29 is 9 minors, valid only on non-prod (perfdev, deveks01 family). Even then, requires a mesh-wide rolling restart after the istiod swap or L7 features misbehave on the old sidecars.

## Phase 0 — Check if mesh-wide restart is even needed

```bash
kubectl get ns -l istio-injection=enabled -o name
kubectl get pods -A -o json | jq -r '.items[].spec.containers[]? | select(.name=="istio-proxy") | .image' | sort | uniq -c
```

If `istio-injection=enabled` returns NO namespaces AND only the ingressgateway image appears in the sidecar inventory, the cluster has no app-namespace mesh — N-2 drift doesn't exist, just upgrade istiod + ingressgateway and skip Phase 4. Hit on aws0fvdemoeks01 (GENESIS-420629) — entire Phase 4 was a no-op.

See [[istio-sidecar-injection-check]] memory.

## Phase 1 — Cluster value flips

EIS components `istio-base`, `istiod`, `istio-ingress-cluster`, `istio-ingress-namespace`, `istio-gateway-cluster` each bundle multiple subcharts gated by `_<verA>_enabled` / `_<verB>_enabled` flags (e.g. `istiod_1_15_5`, `istiod_1_19_1`, `istiod_1_20_3`, `istiod_1_29_0`). Flip in BOTH the cluster-wide values and any per-component override.

```yaml
# clusters/<cluster>/values.yaml
istio_base_1_29_0:    { enabled: true }
istiod_1_29_0:
  enabled: true
  meshConfig: {}
  nodeSelector:                       # see Trap 2 below
    kubernetes.io/os: linux
istio_ingress_cluster_1_29_0_enabled:   true
istio_ingress_namespace_1_29_0_enabled: true

# old version kept disabled (NOT deleted) for fast revert
istio_base_1_20_3:    { enabled: false }
istiod_1_20_3:        { enabled: false }
istio_ingress_cluster_1_20_3_enabled:   false
istio_ingress_namespace_1_20_3_enabled: false
```

Per-component override file (if present at `clusters/<cluster>/istiod/values.yaml` or `clusters/<cluster>/istio-ingress-cluster/values.yaml`) is applied AFTER the global values and WINS. Always grep both.

## Phase 2 — Three critical traps

### Trap 1 — `name:` override must move with the version

Pre-upgrade `istio_ingress_cluster_1_20_3.name: istio-ingressgateway` exists so the rendered Deployment matches the ALB TargetGroupBinding. Moving to 1.29.0 → place the same block under `istio_ingress_cluster_1_29_0.name: istio-ingressgateway`. Otherwise the rendered Deployment is named `istio-ingress-cluster`, ALB drops backends, ingress traffic dies.

```yaml
# clusters/<cluster>/istio-ingress-cluster/values.yaml
istio_ingress_cluster_1_29_0:
  name: istio-ingressgateway
  labels:
    app: istio-ingressgateway
    istio: ingressgateway
  nodeSelector:
    kubernetes.io/os: linux
  autoscaling: { minReplicas: 1 }
  resources:
    requests: { cpu: 200m, memory: 800Mi }
    limits:   { cpu: 400m, memory: 1200Mi }
  service:
    type: NodePort
    ports: [...]
```

### Trap 2 — `nodeSelector` falsy-default leaves stale value alive

Istio 1.29 chart's deployment template only emits `nodeSelector:` if `.Values.nodeSelector` is truthy. If a prior 1.20 release applied `nodeSelector: {kubesystem: true}` (a label no node on this cluster carries), ArgoCD ServerSideApply does **not** strip it because nothing in the new manifest claims ownership of that field. Pass an explicit benign selector — `kubernetes.io/os: linux` is on every Linux worker — so the chart renders the field and SSA can overwrite.

Symptom: new ReplicaSet stays Pending with `FailedScheduling: nodes didn't match Pod's node affinity/selector`, while old ReplicaSet pods keep running. Diagnostic:

```bash
kubectl --context "$KCTX" get rs -n istio-system -l app=istiod \
  -o jsonpath='{range .items[*]}{.metadata.name} nodeSelector={.spec.template.spec.nodeSelector}{"\n"}{end}'
```

### Trap 3 — Per-component override silently shadows the fix

The most insidious version of Trap 2. You fix `nodeSelector` in `clusters/<cluster>/values.yaml`, ArgoCD reconciles, deployment still has the old selector. Every 4 seconds. Because:

```
ApplicationSet value-file order:
  1. components/istiod/values.yaml                       (chart default)
  2. clusters/<cluster>/values.yaml                       (your fix here)
  3. clusters/<cluster>/istiod/values.yaml                ← STILL has old kubesystem
```

Per-component file wins. Grep both before pushing:

```bash
grep -rn "nodeSelector\|kubesystem" clusters/<cluster>/
```

## Phase 3 — Pre-merge render verification

```bash
(cd components/istiod && helm dependency build >/dev/null 2>&1)
helm template istiod components/istiod \
  -f components/istiod/values.yaml \
  -f clusters/$CLUSTER/values.yaml \
  -f clusters/$CLUSTER/istiod/values.yaml \
  --namespace istio-system 2>/dev/null > /tmp/istiod.yaml

# Confirm only the new subchart renders
grep "^# Source:" /tmp/istiod.yaml | sort -u | head

# Confirm Deployment image is the new version
awk 'BEGIN{block=""} /^---$/{if(block ~ /kind: Deployment/ && block ~ /name: istiod/){print block; exit}; block=""; next} {block=block"\n"$0}' /tmp/istiod.yaml \
  | grep -E "image:|nodeSelector" | head -5
```

Repeat for `istio-base`, `istio-ingress-cluster`, `istio-gateway-cluster`. Expect ONLY `charts/*_1_29_0/` source lines.

## Phase 4 — Post-merge runbook (MANDATORY)

After the merge, the new istiod 1.29 will roll. Old workload sidecars (1.20) still exist on every namespace using the mesh. They can keep talking to 1.29 briefly but L7 features misbehave. Mandatory:

```bash
KCTX=arn:aws:eks:us-west-2:<acct>:cluster/<cluster>

# 1. Verify new istiod pods are Running (not stuck Pending)
kubectl --context "$KCTX" get pods -n istio-system -l app=istiod
# If Pending — revisit Traps 2/3 above.

# 2. Push fresh xDS state to the gateway
kubectl --context "$KCTX" rollout restart deploy/istiod -n istio-system
kubectl --context "$KCTX" rollout status  deploy/istiod -n istio-system --timeout=120s
kubectl --context "$KCTX" rollout restart deploy/istio-ingressgateway -n istio-system
kubectl --context "$KCTX" rollout status  deploy/istio-ingressgateway -n istio-system --timeout=120s

# 3. Verify route count (tens-to-hundreds, not 1-2)
kubectl --context "$KCTX" exec -n istio-system deploy/istio-ingressgateway -- \
  pilot-agent request GET 'config_dump?resource=dynamic_route_configs' \
  | jq '.configs[].route_config.virtual_hosts[]?.domains[]?' | sort -u | wc -l

# 4. Rolling-restart every mesh namespace so sidecars upgrade
for NS in monitoring loki oidc perf-mssql jl-test; do
  kubectl --context "$KCTX" rollout restart deploy,sts -n "$NS"
done

# 5. Verify sidecar version convergence
kubectl --context "$KCTX" get pods -A -o json \
  | jq -r '.items[].spec.containers[]? | select(.name=="istio-proxy") | .image' \
  | sort | uniq -c
# Expect a single image:  ... docker.io/istio/proxyv2:1.29.0
```

## Phase 5 — URL smoke-test

```bash
for HOST in grafana-$CLUSTER prometheus-$CLUSTER alertmanager-$CLUSTER \
            headlamp-monitoring dashboard-monitoring \
            loki-$CLUSTER-loki kiali; do
  URL="https://${HOST}.aws.eislab.cloud/"
  CODE=$(curl -kL -s -o /dev/null -w '%{http_code}' --max-time 8 "$URL")
  printf "%-55s %s\n" "$URL" "$CODE"
done
```

Expect 200 on the UI endpoints. Dex (`/`) returns 404 by design — real path is `/dex/.well-known/openid-configuration`. OTel-http (`/`) returns 405 — POST-only endpoint. Thanos via gRPC may return 000 — not a browser endpoint.

## Rollback

`git revert` the upgrade MR. Old `_1_20_3` blocks remain in the values file (kept `enabled: false` deliberately) so revert just flips them back to `true`. ApplicationSet reconciles in ≤2 min. Sidecars stay on 1.29 until next pod restart — they will recreate on the old version automatically.

Cross-references in memory: `argocd_value_file_precedence.md`, `istio_upgrade_route_reload.md`, `istio_major_version_upgrade.md`, `helm_chart_adoption_gotchas.md`. Companion skill: `argocd-cluster-onboarding`.
