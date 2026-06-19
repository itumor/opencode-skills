---
name: argocd-cluster-onboarding
description: End-to-end playbook for onboarding an EKS cluster into the EIS multi-cluster ArgoCD hub (iac/argocd/argocd). Covers Copier secret-path verification, pre-merge safety audit, helm template vs live diff, blocker fixes (incl. chart-extension when live resources have no template), Velero+local backups, post-merge istio reset, verification, and rollback. Use when adding a new cluster, enabling more components on an existing cluster, or upgrading an ArgoCD-managed chart bundle.
---

# ArgoCD Cluster Onboarding — EIS hub-and-spoke

Hub: `aws0iacdeveks01` (account 182399717428). ApplicationSet `all-components` matrix-generates per-cluster apps from `clusters/<name>/cluster-component-config.yaml` × `clusters/<name>/*` directory. Auto-sync **enabled with `prune + selfHeal + ServerSideApply`** — any drift between rendered chart and live cluster will be reconciled aggressively on first sync.

## Phase 0 — Verify secret-path-base BEFORE running Copier

The Copier template at `argocd/template/clusters` defaults `secret_path_base` to `secret2/data/rnd/cicd/3.0/<cluster>` (Vault-style, from `aws0iacdeveks01`). Other clusters use different conventions. CAA (MR #234) used cluster-scoped naming (`<cluster>/<ns>/<comp>/<secret>`) — Copier defaults pointed at non-existent paths, all 5 secret references returned `ResourceNotFoundException`.

```bash
# List actual AWS SM secret names for the target cluster
aws secretsmanager list-secrets --profile $PROFILE --region $REGION \
  --query "SecretList[?contains(Name,'$CLUSTER')].Name" --output text | tr '\t' '\n' | head -30
```

Identify the common prefix used by `oidc/`, `monitoring/observascope-oss/`, `monitoring/headlamp/`, `monitoring/gen-dashboard/`. That prefix is your `secret_path_base`. Pass it explicitly:

```bash
copier copy ../template/clusters $CLUSTER --overwrite --defaults \
  --data secret_path_base="<discovered-prefix>" \
  --data aws_account_id=$ACCT \
  ...
```

After generation, verify EVERY per-component `secretPath:` (and `registrySecretPath:` in gen-dashboard) by `aws secretsmanager describe-secret --secret-id <path>`. Any 404 = blocker.

## Phase 1 — Discover real values via AWS CLI

```bash
PROFILE=PNT-Performance              # adjust per cluster
CLUSTER=aws0v20perfdeveks01
REGION=us-west-2
ACCT=850995559528

aws sso login --profile $PROFILE
aws eks update-kubeconfig --name $CLUSTER --region $REGION --profile $PROFILE
KCTX=arn:aws:eks:$REGION:$ACCT:cluster/$CLUSTER
HUB=arn:aws:eks:us-west-2:182399717428:cluster/aws0iacdeveks01

aws elbv2 describe-load-balancers   --region $REGION --profile $PROFILE | jq '.LoadBalancers[] | select(.Scheme=="internal")'
aws elbv2 describe-target-groups    --region $REGION --profile $PROFILE | jq ".TargetGroups[] | select(.TargetGroupName|test(\"$CLUSTER\"))"
aws iam list-roles                  --profile $PROFILE | jq ".Roles[] | select(.RoleName|test(\"EKSRoleFor|$CLUSTER\")) | {RoleName,Arn}"
aws s3 ls --profile $PROFILE | grep -i "velero\|loki"
```

Verify the secret backend is what cluster-side ESO uses — **never assume**. Check live: `kubectl get clustersecretstore -o yaml | grep -A6 provider`. EIS clusters use HashiCorp Vault, mount = `<cluster>`, role = `genesis-default`. SecretsManager is rare.

## Phase 2 — Pre-merge safety audit (zero data-loss guarantee)

Before pushing the MR, render each component locally and diff against the live helm release. **PRUNE > 0 with workload kinds (Deployment/StatefulSet/PVC/Secret) is a blocker.**

```bash
cat > /tmp/extract_kinds.py <<'PY'
import sys, re
content = open(sys.argv[1]).read()
for d in re.split(r'^---\s*$', content, flags=re.MULTILINE):
    if not d.strip(): continue
    kind = name = ns = None
    in_meta = False
    for line in d.split('\n'):
        m = re.match(r'^kind:\s*(\S+)', line); 
        if m: kind = m.group(1); continue
        if re.match(r'^metadata:\s*$', line): in_meta = True; continue
        if in_meta and re.match(r'^[^ \t#]', line): in_meta = False
        if in_meta:
            m = re.match(r'^  name:\s*[\'"]?([^\'"]+?)[\'"]?\s*$', line)
            if m and not name: name = m.group(1)
            m = re.match(r'^  namespace:\s*[\'"]?([^\'"]+?)[\'"]?\s*$', line)
            if m and not ns: ns = m.group(1)
    if kind and name: print(f"{kind}|{name}|{ns or ''}")
PY

run_diff() {
  local COMP=$1 NS=$2
  (cd "components/$COMP" && helm dependency build >/dev/null 2>&1)
  local OVR="clusters/$CLUSTER/$COMP/values.yaml"
  local args=(-f "components/$COMP/values.yaml" -f "clusters/$CLUSTER/values.yaml")
  [ -f "$OVR" ] && args+=(-f "$OVR")
  helm template "$COMP" "components/$COMP" "${args[@]}" --namespace "$NS" 2>/dev/null > /tmp/r.yaml
  helm get manifest "$COMP" -n "$NS" --kube-context "$KCTX" 2>/dev/null > /tmp/l.yaml
  python3 /tmp/extract_kinds.py /tmp/r.yaml | sort -u > /tmp/r.k
  python3 /tmp/extract_kinds.py /tmp/l.yaml | sort -u > /tmp/l.k
  local PRUNE=$(comm -13 /tmp/r.k /tmp/l.k | wc -l | tr -d ' ')
  local CREATE=$(comm -23 /tmp/r.k /tmp/l.k | wc -l | tr -d ' ')
  printf "%-40s PRUNE=%-3s CREATE=%s\n" "$COMP/$NS" "$PRUNE" "$CREATE"
  if [ "$PRUNE" -gt 0 ]; then comm -13 /tmp/r.k /tmp/l.k | sed 's/^/  PRUNE /'; fi
}
```

**Acceptable CREATE entries:** `Job/*-smoke-test`, ExternalSecret resources that already exist as `SecretSynced=True`, RBAC adopting under helm meta annotations.

**Unacceptable PRUNE entries:** any StatefulSet, Deployment, Service that isn't being recreated under a *new name*. Any PVC. Any Secret containing user data.

**ExternalSecret / chart-template change — proving zero downtime (MR !268 method):**
- A failing ExternalSecret with `target.deletionPolicy: Retain` does **not** delete/blank its target secret — workloads keep running on the last-good value. So an ES in `SecretSyncedError` is non-disruptive; don't treat app `Degraded` as an outage. Verify the consumer pod age is unchanged (`kubectl get pods` — no restart).
- Updating an `imagePullSecrets`-type secret does **not** restart running pods (consulted only at image-pull/pod-create). Rewriting it is safe in-place.
- For an **opt-in** template change (default → `{{- with }}`), prove it's a no-op for clusters that set the value explicitly: render with OLD template (`git show main:<tpl> > /tmp/old`) and NEW template, then `diff` the rendered resource. Byte-identical ⇒ ArgoCD sees no change ⇒ no sync action ⇒ zero risk for those clusters.

## Phase 3 — Known blocker patterns

| Pattern | Symptom in diff | Fix |
|---|---|---|
| `fullnameOverride: "<short>"` set in cluster values for an umbrella chart | All resources rename from `<release>-<chart>-*` to `<short>-*` (≈40 PRUNE+40 CREATE on the loki bundle) | **Delete the fullnameOverride line.** Production loki/prometheus already use the long name; renaming triggers StatefulSet/PVC deletion → data loss. |
| Chart default re-enables a new subchart version on upgrade (e.g. `istio_ingress_cluster_1_29_0_enabled: true` while we run 1.20.3) | Render produces a SECOND `Deployment/istio-ingressgateway` next to the live one | Set `<chart>_<newver>_enabled: false` in cluster values. Also pass the gateway-naming knob (`istio_ingress_cluster_1_20_3.name: istio-ingressgateway`) so old release name is preserved. |
| Helm release already exists with different name prefix (release `observascope-exporters` cross-deploys `kafka-exporter-prometheus-kafka-exporter` in another namespace) | Render shows new resources in different ns / different name → PRUNE of the live one | Either match upstream via `releaseName`/`exporterFullName` or accept the migration. Check `helm get values -a` to confirm. |
| Velero managed by both bootstrap Application AND ApplicationSet generator (same name `velero-aws0v20perfdeveks01`) | App name collision; ArgoCD errors or last-writer-wins | Remove `velero:` from `cluster-component-config.yaml` and delete `clusters/<name>/velero/`. Keep bootstrap path. |
| Helm hook ExternalSecret (`helm.sh/hook: pre-install,pre-upgrade,pre-rollback`) | ArgoCD converts to PreSync hook, applies during sync only — annotation/refresh alone does NOT recreate it | Force sync via `kubectl patch app --type=merge -p '{"operation":{"sync":{"syncOptions":["Force=true","Replace=true"]}}}'`. Or delete the live ES and let ArgoCD re-create it on next sync. |
| ExternalSecret `data[].remoteRef` without `property:` field | Secret value is JSON-stringified vault response (`{".dockerconfigjson":"..."}`) — double-wrapped when used in `template.data.dockerconfigjson: '{{ .config }}'` | Add `property: <vault-key>` to the chart's ExternalSecret template. |
| `property:` set as a chart-wide **default** when two secret conventions coexist | A `\| default ".dockerconfigjson"` fixes wrapped clusters but **breaks raw-secret clusters** (`<cluster>/nexus/dockerconfig` has no `.dockerconfigjson` key) → `could not get secret data from provider`, app Degraded. | Make `property` **opt-in**, not defaulted: `{{- with .Values.externalSecrets.registrySecretProperty }}property: {{ . }}{{- end }}`. Set the value per-cluster only for wrapped clusters. gen-dashboard MR !268, see [[gen_dashboard_registry_secret_property]]. |
| Chart has NO template for live resources (live has 37 routes, render has 0) | helm-managed VirtualServices/DestinationRules/ServiceEntries exist but no template renders them; diff = 37 prune | Extend the chart with a backward-compatible template. Gate on values default-empty: `{{- range $svc := .Values.externalServices \| default list }}`. Other clusters render zero extra resources; target cluster lists live data in per-cluster values. Example: `components/istio-gateway-cluster/templates/external-services.yaml` (CAA MR #234) renders SE+VS+DR per entry with 3 patterns (passthrough, S3 path-rewrite, simple hostname). |
| Bitnami sub-chart `enabled: false` defaults | observascope-oss live had Thanos compactor+storegateway+SMs; render skipped them all (~12 prune) | Explicitly enable EVERY live sub-feature: `thanos.compactor.enabled: true`, `thanos.storegateway.enabled: true`, `thanos.metrics.enabled: true`, `thanos.metrics.serviceMonitor.enabled: true`. Configuring `serviceAccount.name` alone does NOT enable a sub-chart. |
| `alb.targetGroupARN` (singular) and `alb.targetGroupARNs` (list) coexist after Helm merge | Chart conditional picks singular first → renders single `ingress-tg` even when list intent is `ingress-tg-0/1` | Remove singular from parent values when per-component values use list. Extend chart for `passthroughTGARNs` if live has multi-port TGBs (e.g., port 443 passthrough alongside port 80). |

## Phase 3.5 — Render-script and ApplicationSet gotchas

**macOS bash 3.2 silently breaks the render.** `scripts/ci/render-all-helm.sh` uses `declare -A`. Default `/bin/bash` on macOS is GPLv2-frozen at 3.2.57 and produces an empty `.out/rendered.yaml` with no error. Install bash 5: `brew install bash`. Invoke explicitly:
```bash
CLUSTER_FILTER=$CLUSTER REPO_ROOT=$(pwd) /opt/homebrew/bin/bash scripts/ci/render-all-helm.sh
```
Verify: `bash --version | head -1` reports 4+.

**ApplicationSet dir-generator gates which components ACTUALLY get an Application.** `cluster-component-config.yaml` can list 22 components, but `all-components-appset.yaml` uses TWO matched generators (config file × `clusters/<name>/*` directory). An Application is created ONLY when BOTH match. Components in config but with no per-cluster directory get NO Application — safe from prune.

```bash
# What ArgoCD will actually deploy:
ls -d clusters/$CLUSTER/*/ | xargs -n1 basename

# What's in cluster-component-config but won't deploy:
diff <(ls -d clusters/$CLUSTER/*/ | xargs -n1 basename | sort) \
     <(grep -E '^[a-z]' clusters/$CLUSTER/cluster-component-config.yaml | grep -v '^name:\|^server:\|^enabled:\|^syncProject:' | awk -F: '{print $1}' | sort)
```

This saved CAA from a `kubernetes-dashboard` mishap: live Helm release existed, config listed it, but no directory existed → no Application → no prune.

## Phase 4 — Mandatory pre-merge backups

Two layers. Local (workstation) for fast per-release rollback; Velero (S3 + CSI snapshots) for PV-level disaster recovery.

```bash
TS=$(date -u +%Y%m%d-%H%M%SZ)
BKP=~/iac-backups/$CLUSTER-pre-mr-$TS
mkdir -p "$BKP"/{releases,k8s-state,helm-storage,charts}

# A. per-release helm artifacts
for R in <list-of-affected-releases>; do
  REL="${R%%:*}"; NS="${R##*:}"
  D="$BKP/releases/$REL"; mkdir -p "$D"
  helm get values   "$REL" -n "$NS" --kube-context "$KCTX"    > "$D/values-user.yaml" 2>/dev/null
  helm get values   "$REL" -n "$NS" --kube-context "$KCTX" -a > "$D/values-computed.yaml" 2>/dev/null
  helm get manifest "$REL" -n "$NS" --kube-context "$KCTX"    > "$D/manifest.yaml" 2>/dev/null
  helm get hooks    "$REL" -n "$NS" --kube-context "$KCTX"    > "$D/hooks.yaml" 2>/dev/null
  helm history      "$REL" -n "$NS" --kube-context "$KCTX"    > "$D/history.txt" 2>/dev/null
done

# B. helm release-storage Secrets (the `sh.helm.release.v1.*` objects)
for NS in <affected-namespaces>; do
  NAMES=$(kubectl --context "$KCTX" get secrets -n "$NS" -o name 2>/dev/null | grep "secret/sh.helm.release.v1" | tr '\n' ' ')
  [ -n "$NAMES" ] && eval "kubectl --context \"$KCTX\" get -n \"$NS\" $NAMES -o yaml" > "$BKP/helm-storage/$NS.yaml"
done

# C. k8s state snapshots
kubectl --context "$KCTX" get clustersecretstores      -o yaml > "$BKP/k8s-state/clustersecretstores.yaml"
kubectl --context "$KCTX" get externalsecrets       -A -o yaml > "$BKP/k8s-state/externalsecrets.yaml"
kubectl --context "$KCTX" get statefulsets          -A -o yaml > "$BKP/k8s-state/statefulsets.yaml"
kubectl --context "$KCTX" get pvc                   -A -o yaml > "$BKP/k8s-state/pvcs.yaml"

# D. packaged charts
for COMP in <component-list>; do
  (cd "components/$COMP" && helm dependency build >/dev/null 2>&1)
  helm package "components/$COMP" -d "$BKP/charts/" >/dev/null 2>&1
done

# E. Velero backup (S3 + CSI snapshots, 30-day TTL)
velero backup create "pre-mr-$(date -u +%Y%m%d-%H%M%S)" \
  --include-namespaces "kube-system,istio-system,monitoring,loki,oidc,external-secrets" \
  --include-cluster-resources=true \
  --snapshot-volumes=true \
  --ttl 720h0m0s \
  --kubecontext "$KCTX"
```

S3 bucket name pattern: `<env-prefix>-velero-backups` (e.g. `pntperf-velero-backups`).

## Phase 5 — Push MR, wait for merge, then **trigger the istio reset**

**Merge gate:** the MR pipeline's required gates are `render_manifests`, `validate` (pluto / kube_linter / kubeconform), and `helm_unittest`. Once those are green you may `glab mr merge <id> --yes` **without waiting for the `checkov` security job** (and `quality_summary`) to finish — checkov is slow (5–11 min, usually the long pole) and is treated as non-blocking for these GitOps config changes. Do NOT merge before render/validate/unittest pass. (User-confirmed 2026-06-01, MR !268.)

After ANY merge that touches istio components on the cluster, restart istiod + istio-ingressgateway. Without this, all VirtualServices bound to `istio-system/cluster-gw` return HTTP 404 even though they exist in the API server. Root cause: envoy keeps a stale xDS snapshot when istiod was restarted mid-sync.

```bash
kubectl --context "$KCTX" rollout restart deploy/istiod -n istio-system
kubectl --context "$KCTX" rollout status  deploy/istiod -n istio-system --timeout=120s
kubectl --context "$KCTX" rollout restart deploy/istio-ingressgateway -n istio-system
kubectl --context "$KCTX" rollout status  deploy/istio-ingressgateway -n istio-system --timeout=120s

# Verify
kubectl --context "$KCTX" exec -n istio-system deploy/istio-ingressgateway -- \
  pilot-agent request GET 'config_dump?resource=dynamic_route_configs' \
  | jq '.configs[].route_config.virtual_hosts[]?.domains[]?' | sort -u | wc -l
# expect tens, not 1-2
```

## Phase 6 — Post-merge sanity (within 15 minutes)

```bash
# All apps Synced+Healthy
for APP in $(kubectl --context "$HUB" get applications -n argocd -o name | grep "$CLUSTER"); do
  STATUS=$(kubectl --context "$HUB" get "$APP" -n argocd \
    -o jsonpath='{.status.sync.status}|{.status.health.status}|{.status.operationState.phase}')
  printf "%-55s %s\n" "${APP##*/}" "$STATUS"
done

# No unexpected critical restarts
kubectl --context "$KCTX" get pods -n istio-system -l app=istio-ingressgateway
kubectl --context "$KCTX" get sts -n loki | grep ingester
kubectl --context "$KCTX" get pods -n monitoring -l app.kubernetes.io/instance=observascope-oss

# ALB still healthy
aws elbv2 describe-target-health --profile $PROFILE --region $REGION \
  --target-group-arn <tg-arn> | jq '.TargetHealthDescriptions[].TargetHealth.State' | sort | uniq -c

# All ExternalSecrets synced
kubectl --context "$KCTX" get externalsecrets -A | grep -v "SecretSynced\|NAMESPACE"
```

Common follow-up findings:
- `ImagePullBackOff` on a chart-version bump → cluster values needs `imagePullSecrets: [{name: registry-secret}]`. Verify the registry-secret format isn't double-wrapped (see Phase 3).
- `Pending` Pods after upgrade → check `nodeSelector` against actual node labels. Hub uses `kubesystem=true` convention; not all clusters have that label.
- `DaemonSet` partially scheduled → 1-3 nodes at 100% CPU requests. Apply a custom PriorityClass (value 1,000,000, PreemptLowerPriority) and bind it to the DS via the chart's `priorityClassName` knob.

## Phase 6.5 — Failed hooks even when app is Synced+Healthy (new — GENESIS-420629)

An app's `Sync=Synced Health=Healthy` does NOT guarantee `operationState.phase=Succeeded`. Hook resources (PreSync/PostSync Jobs, ExternalSecrets) can fail without affecting workload health. Three recurring causes:

```bash
# Find apps with Failed operations (despite Synced+Healthy)
kubectl --context "$HUB" get applications -n argocd -o json | \
  jq -r '.items[] | select(.metadata.name | contains("'$CLUSTER'")) | "\(.metadata.name) op=\(.status.operationState.phase // "Idle")"' | grep -E "Failed|Running"

# Inspect failed hook resource per app
kubectl --context "$HUB" get application <app> -n argocd -o json | \
  jq -r '.status.operationState.syncResult.resources[]? | select(.hookPhase=="Failed" or .status=="SyncFailed") | "\(.kind)/\(.name): hook=\(.hookPhase) status=\(.status) msg=\(.message)"'
```

**Pattern 1 — gen-dashboard PreSync ExternalSecret 404:** Copier defaults `registrySecretPath: secret2/data/rnd/cicd/3.0/<cluster>/nexus/dockerconfig` but actual SM convention is `secret2/data/rnd/cicd/3.0/<cluster>/monitoring/gen-dashboard/registry`. Fix in `clusters/<c>/gen-dashboard/values.yaml`; verify via `aws secretsmanager list-secrets`.

**Pattern 2 — observascope-exporters PostSync smoke-test backoff:** Chart's default `smokeTest.url` is empty → `curl -f ""` hits backoff limit. Always set in `clusters/<c>/observascope-exporters/values.yaml`:
```yaml
smokeTest:
  enabled: true
  url: "http://observascope-exporters-k8s-image-availability-exporter.monitoring.svc.cluster.local:8080/metrics"
```

**Pattern 3 — Stale failed hook Job:** Job ran during a transient outage (e.g. oauth2-proxy not yet ready). ArgoCD keeps retrying the SAME job. Once workload is healthy, delete the Job and ArgoCD recreates fresh: `kubectl delete job <app>-smoke-test -n <ns>`. Operation flips to Succeeded on next reconcile.

See [[argocd-post-onboarding-failed-hooks]] memory.

## Phase 6.6 — ALB TargetGroupBinding immutable targetType (new — GENESIS-420629)

If `istio-gateway-cluster-<cluster>` shows `OutOfSync` with admission webhook error:
```
TargetGroupBinding update may not change these immutable fields: spec.targetType
```

Cause: chart default `targetType: ip` but TF provisioned the TG with `instance`. Fix in `clusters/<c>/values.yaml`:
```yaml
alb:
  targetType: instance  # match TF
  targetGroupARNs: [...]
```

Verify live TG type: `aws elbv2 describe-target-groups --names <tg-name> --query 'TargetGroups[0].TargetType'`. See [[alb-tgb-targetType-immutable]] memory.

## Phase 6.7 — Bitnami Redis 8 secret reload (new — GENESIS-420629)

oidc oauth2-proxy may show 0/1 with /ready=500 `WRONGPASS` after ArgoCD initial sync. Cause: Bitnami Redis reads password file at startup; ArgoCD secret rotation doesn't reload `requirepass`. Fix:
```bash
kubectl rollout restart statefulset/oidc-redis-master -n oidc
kubectl rollout status   statefulset/oidc-redis-master -n oidc
kubectl rollout restart deployment/oidc-oauth2-proxy -n oidc
```

Master restart FIRST. See [[bitnami-redis8-secret-reload]] memory.

**Recurs fleet-wide after ANY merge to main (not just initial sync).** Merging an MR bumps the git-generator revision → ArgoCD reconciles ALL apps → Bitnami `oidc-redis-master` StatefulSets roll on multiple clusters at once → every `oidc-oauth2-proxy` that started before its redis roll goes 0/1. After a merge, sweep `oidc-oauth2-proxy` readiness on all oidc clusters, not just the one you changed.

**Diagnostic — is redis actually wrong, or just oauth2-proxy stale?** Test the CURRENT secret against the running master; if it answers, redis is fine and you only need to restart oauth2-proxy (skip the redis restart):
```bash
PW=$(kubectl -n oidc get secret oidc-redis -o jsonpath='{.data.redis-password}' | base64 -d)
kubectl -n oidc exec oidc-redis-master-0 -c redis -- redis-cli -a "$PW" PING   # PONG => redis OK
kubectl -n oidc rollout restart deploy oidc-oauth2-proxy                        # re-reads current secret
```
Durable fix (TODO, follow-up MR): add a Reloader trigger on the `oidc-redis` secret, or pin `auth.existingSecret` so the password never regenerates. Note the hub ApplicationSet already lists `oidc-redis /data/redis-password` in `ignoreDifferences` — the password is allowed to drift by design, so a reloader is the right durable answer. See [[oauth2-proxy-redis-stale-password]] memory.

## Phase 6.8 — istiod PreSync gate (fleet-wide, MRs !273 + !275, 2026-06-02)

The `istio-ingress-cluster` component now includes a **PreSync hook Job** that blocks the Sync phase until `kubectl rollout status deploy/istiod -n istio-system` succeeds. This prevents the bootstrap race where the gateway pod is created before `istio-sidecar-injector` MutatingWebhookConfiguration exists — leaving the pod in `ImagePullBackOff` on `docker.io/library/auto:latest` (Istio's `image: auto` placeholder is never mutated by the injector).

**Why syncWave doesn't fix this:** `all-components-appset` has no `strategy: RollingSync`. The per-app `argocd.argoproj.io/sync-wave` annotation is cosmetic for cross-app ordering — each app auto-syncs independently. Bumping `istiod: syncWave: "2"` and `istio-ingress-cluster: syncWave: "3"` would NOT gate one behind the other.

**Gate is default ON** in `components/istio-ingress-cluster/values.yaml` (and `components-playground/`). It runs on every sync, completes in ~5s when istiod is healthy, and is cleaned up by `BeforeHookCreation,HookSucceeded` policy. Zero-downtime — gateway Deployment spec unchanged, no pod restart.

**Verify gate ran after onboarding a new cluster:**
```bash
# Force sync (hook-only changes don't trigger drift detection automatically)
kubectl --context "$HUB" -n argocd patch application istio-ingress-cluster-$CLUSTER \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD","syncOptions":["CreateNamespace=true","ServerSideApply=true"]}}}'

# Watch for gate Job in sync message
kubectl --context "$HUB" -n argocd get application istio-ingress-cluster-$CLUSTER \
  -o jsonpath='{.status.operationState.phase} {.status.operationState.message}' -w
# Expect: "Running ... waiting for completion of hook batch/Job/istio-ingress-cluster-istiod-gate"
# Then:   "Succeeded ... successfully synced (no more tasks)"
```

**Playground staging path:** new component-level changes go to `components-playground/` + `templates/deployment-template-playground/` first, tested on `aws0prefdeveks01` (PTO-Reference account, managed by `playground-components-appset.yaml`), then promoted to `components/` + `templates/deployment-template/` for fleet. See [[playground_component_promotion]] memory.

**Hook-only changes + force sync:** ArgoCD hook resources (`argocd.argoproj.io/hook: PreSync/PostSync`) are NOT included in desired-vs-live state comparison — they never cause drift. After merging a hook-only change (like adding the gate), clusters stay "Synced" without re-running. Force sync via `kubectl patch application --type merge -p '{"operation":{"sync":...}}'` on all affected apps. See [[argocd_hook_only_force_sync]] memory.

## Phase 6.9 — Fresh-cluster first-sync gotchas (EISSAASDEV-302 learnings)

A **brand-new** cluster (first time the `all-components` ApplicationSet generates apps for it) hits
failure modes that an established cluster never sees. All are now **durably fixed** in the clusters
Copier template and the argocd repo — generate new clusters with `copier copy --vcs-ref V1.0.8` (the
release carrying both fixes below) and they should NOT recur. The diagnoses/hot-fixes here are for
when you DO see them (older template, or you need to confirm the fix is in effect). Sign-off for a
freshly-provisioned env runs through the **`eis-onesuite-e2e-verify`** skill.

**1. "synchronization tasks are not valid" — CRD dry-run cascade.** On a fresh cluster ArgoCD
dry-runs ServiceMonitor / PrometheusRule / SLO CRs **before** `observascope-oss` has installed the
prometheus-operator CRDs → the dry-run fails because the CRD doesn't exist yet → the error
**cascade-fails** every CRD-consumer: `oidc`, `gen-dashboard`, `observascope-eis`, and the exporters.
- **Durable fix (merged):** `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` on the
  CRD-consumer templates (**argocd repo MR !298**) + bump `observascope-oss` syncWave **3 → 2** so the
  keystone installs the CRDs earlier (clusters template). Both ship in **clusters template tag V1.0.8**.
- **Verify the fix is in effect:** the consumer templates carry the `SkipDryRunOnMissingResource=true`
  annotation; on a V1.0.8-generated cluster these apps go Synced+Healthy without the dry-run error.

**2. istiod packs onto one node → starves monitoring DaemonSets.** The `istiod` component default is
**3 replicas × 2-core CPU request with no spread**, so all 3 istiod pods land on **ONE** system node
(driving it to ~100% CPU). The `node-exporter` / `x509-cert-exporter` / `grafana-alloy` **DaemonSet**
pods pinned to that node then **can't schedule** → `observascope-{oss,exporters,logging}` sit stuck
**Progressing**. The trap: the StatefulSets never flip to Degraded, so it masquerades as a slow
warmup. It is **NOT a capacity problem** — aggregate cluster CPU is fine; it's a packing/spread issue.
- **Durable fix (merged):** istiod soft `pilot.topologySpreadConstraints` (`whenUnsatisfiable:
  ScheduleAnyway`, `topologyKey: kubernetes.io/hostname`, selector `istio: pilot`) in **clusters
  template V1.0.8**.
- **Per-cluster hot-fix if needed:** drop istiod `pilot.resources.requests.cpu` to `500m` in
  `clusters/<c>/istiod/values.yaml`.
- **Diagnose:** `kubectl describe node <n>` → check **Allocated resources** CPU (istiod node near
  100%); the Pending DaemonSet pod's events show `FailedScheduling … Insufficient cpu`. (Needs
  spoke pod-level access — see the temp-endpoint-open-then-REVERT trick in `eis-onesuite-e2e-verify`.)
  See [[priorityclass_for_monitoring_daemonsets]] for the complementary PriorityClass approach.

**3. Keystone secret-seeding (NOT template-fixable — seed BEFORE first sync).** `observascope-oss` is
the **keystone**: it installs the prometheus-operator CRDs that everything else dry-runs against. It
blocks on its own ExternalSecrets at `<c>/monitoring/observascope-oss/{ldap,objstore,slack-api-urls}`.
- **objstore** = the cluster's **OWN** observascope S3 bucket, accessed via IRSA — set
  `aws_sdk_auth: true` (no access keys in the secret). **ldap/slack** can be **disabled** in cluster
  values if unused. Either way, unblocking the keystone **cascade-unblocks** oidc / gen-dashboard /
  observascope-eis / exporters (they were only failing on the missing CRDs from #1).
- Also seed: `gen-dashboard` needs `<c>/monitoring/gen-dashboard/registry` (the shared EIS Nexus
  `dockerconfigjson`), and `headlamp` needs `<c>/monitoring/headlamp/headlamp-oidc`.
- See [[argocd_fresh_cluster_smooth_install]] and the ExternalSecret-404 patterns in Phase 6.5 /
  [[argocd_post_onboarding_failed_hooks]].

**4. Private-cluster diagnosis access.** A spoke EKS API is **private** AND the hub kubectl is
**RBAC-scoped to ArgoCD CRDs only** (you can list `applications/applicationsets/secrets -n argocd`
but NOT pods/svc — and the `argocd-server` pods aren't on the hub cluster). So app-level health =
hub; **pod-level** health needs spoke access. With the project SSO admin you can temporarily open the
API to your IP, diagnose, then **REVERT to private**:
```bash
MYIP=$(curl -s https://checkip.amazonaws.com)
aws eks update-cluster-config --name <c> --region <r> --profile <proj> \
  --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs=${MYIP}/32
# ... aws eks update-kubeconfig + kubectl describe node / get pods -n monitoring ...
# !!! ALWAYS REVERT:
aws eks update-cluster-config --name <c> --region <r> --profile <proj> \
  --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true
```
Or use an in-VPC WorkSpace/bastion (none exists until the toolchain fleet is up). Full procedure +
sign-off checklist in the **`eis-onesuite-e2e-verify`** skill.

## Phase 7 — Rollback

`git revert` on the same MR branch and push. ApplicationSet re-reconciles within `requeueAfterSeconds: 120`. Release names match adopted state, so prior resources restore cleanly.

For PV-level rollback, restore from Velero:
```bash
velero restore create restore-pre-mr --from-backup <backup-name> --kubecontext "$KCTX"
```

## Cross-references in memory

- `aws0v20perfdeveks01_mr230_backups.md` — real-world example (perf-dev cluster onboarding)
- `aws0caadeveks01_premerge_validation.md` — real-world example (CAA dev, manual-deployed cluster requiring full live-config port + chart extension)
- `gitops_adoption_caa_lessons.md` — 6 new adoption patterns surfaced by CAA work (secret-path mismatch, chart extension, ALB list/single, sub-chart enabling, dir-generator gate, bash 4)
- `helm_chart_adoption_gotchas.md` — 6 original adoption patterns (fullnameOverride, sub-chart re-enable, resource-name mismatch, helm-hook ES, missing `property:`, cross-ns DNS)
- `gen_dashboard_registry_secret_property.md` — two SM secret conventions; `property` must be opt-in (MR !268); zero-downtime ES proof
- `argocd_repo_ci_merge_ops.md` — repo CI pipeline shape, merge-not-pipeline-gated, skip-checkov, ArgoCD hard-refresh force-sync
- `istio_upgrade_route_reload.md` — istiod restart rule (404s after istio chart upgrade)
- `eis_argocd_hub_topology.md` — hub-spoke topology + ApplicationSet defaults
- `aws0fvdemoeks01_genesis420629_complete.md` — full real-world onboarding (FV demo, 18 components, K8s 1.35 + Istio 1.29)
- `argocd_post_onboarding_failed_hooks.md` — 3 patterns when Synced+Healthy but Operation=Failed
- `argocd_fresh_cluster_smooth_install.md` — fresh-cluster first-sync (CRD dry-run cascade + istiod packing); durable fixes in clusters template V1.0.8 + argocd MR !298 (Phase 6.9)
- `priorityclass_for_monitoring_daemonsets.md` — PriorityClass to guarantee monitoring DaemonSet coverage on CPU-saturated nodes (Phase 6.9 complement)
- `alb_tgb_targetType_immutable.md` — chart default ip vs TF instance; immutable webhook
- `bitnami_redis8_secret_reload.md` — Redis password reload pattern; restart cycle
- `tf_apply_live_monitoring_pattern.md` — real-time TF apply progress without tail buffer
- `istio_sidecar_injection_check.md` — skip mesh-wide restart when no app namespace injection
- `eis_secret_and_irsa_conventions.md` — Vault path conventions + IRSA naming

**Related skill:** `eis-onesuite-e2e-verify` — end-to-end env sign-off (private-cluster access, the two first-sync failure modes, full checklist); the verification phase that runs after this onboarding (Phase 6 of the OneSuite master flow).
