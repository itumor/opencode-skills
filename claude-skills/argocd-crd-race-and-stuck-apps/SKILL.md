---
name: argocd-crd-race-and-stuck-apps
description: Diagnose and fix ArgoCD Applications that are permanently stuck at phase Failed on the EIS multi-cluster hub — especially "resource mapping not found ... no matches for kind ServiceMonitor ... ensure CRDs are installed first" on a freshly onboarded cluster, or any app that needed a hand sync and will not self-heal. Use when an app shows Synced/OutOfSync + operationState.phase Failed with retryCount exhausted, when someone says "I have to sync it by hand every time", when a cold cluster bootstrap leaves monitoring apps red, or when reviewing/authoring a fix that relies on sync-wave ordering. Encodes why ApplicationSet sync-waves are inert, why SkipDryRunOnMissingResource is a placebo, the Capabilities gate that actually fixes it, retry-envelope sizing, the playground canary, and the guarded live remediation.
---

# ArgoCD CRD race & permanently-stuck Applications

Repo: `iac/argocd/argocd`. Hub context: `hub-iac`
(`arn:aws:eks:us-west-2:182399717428:cluster/aws0iacdeveks01`).
Reference incident: `aws02afadeveks01` (AFA) onboard, 2026-08-31 — 3 apps stuck, 9 resources
never applied, one of them a non-monitoring Secret.

---

## 0. The two facts that make this class exist

**Fact 1 — ApplicationSet sync-waves are inert.**
`apps/appsets/*-appset.yaml` stamp `argocd.argoproj.io/sync-wave` onto each generated
Application, driven by `syncWave` keys in `clusters/<c>/cluster-component-config.yaml`.
sync-wave orders resources **within** one Application. Ordering Applications against each
other needs `spec.strategy: RollingSync`, which **no appset declares** → AllAtOnce.

```bash
# Prove it in 10 seconds on any cluster
kubectl --context hub-iac -n argocd get applications -o json \
| jq -r '.items[]|select(.metadata.name|endswith("-<CLUSTER>"))
  |[(.metadata.annotations["argocd.argoproj.io/sync-wave"]//"-"),.metadata.name,
    (.status.operationState.startedAt//"-")]|@tsv' | sort -n | column -t
```
If waves 0..9 all start inside a ~20s window, ordering is fiction. (AFA: **17** wave-carrying
component apps, all inside 10:22:04-10:22:24. The 18th, `bootstrap-<cluster>`, comes from the
`cluster-bootstrap` appset, carries no sync-wave and has no `operationState` at all - exclude it.)

**Fact 2 — a Failed automated sync is NEVER re-attempted for the same revision.**
`selfHeal: true` does not rescue it. `reconciledAt` keeps advancing while
`operationState.finishedAt` stays frozen and `retryCount` sits at its limit. That is what
turns a transient cold-start race into a permanent hand-sync chore.

```bash
kubectl --context hub-iac -n argocd get application <app> -o json \
| jq '{sync:.status.sync.status, health:.status.health.status,
       phase:.status.operationState.phase, retryCount:.status.operationState.retryCount,
       finishedAt:.status.operationState.finishedAt, reconciledAt:.status.reconciledAt,
       selfHeal:.spec.syncPolicy.automated.selfHeal}'
```
`finishedAt` hours behind `reconciledAt` + `retryCount == limit` ⇒ stuck forever.

---

## 1. Do NOT reach for these — both are disproven

| Tempting fix | Why it fails |
|---|---|
| `spec.strategy: RollingSync` on the appset | The hub is the **AWS-managed** EKS ArgoCD capability (`ARGOCD 3.3.10-eks-6`); `kubectl --context hub-iac get deploy,sts,ds,po -A \| grep argo` returns **nothing**, so there is no controller to set `ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_PROGRESSIVE_SYNCS=true` on, and AWS documents `argocd-params` as having no effect. The CRD **accepts** `spec.strategy.rollingSync`, so it merges green and silently does nothing. It also selects on Application **labels** (generated apps have `labels: null`) and forces autoSync **OFF** on every matched app — killing selfHeal+prune on 155 apps. |
| `SkipDryRunOnMissingResource=true` on the CR | **Placebo.** It was already on 100% of the CRs that failed. The error is RESTMapper resolution at **apply**, not a dry-run rejection. The appset already sets `Validate=false` + `ServerSideApply=true`. MR !298's premise is falsified. |
| Renumbering `syncWave` | Nothing reads it. The numbering is not even a valid total order (`istio-base` owns the istio CRDs at wave 2 while `istio-gateway-cluster` consumes `Gateway`/`VirtualService` at the **same** wave 2). |

---

## 2. Map the real dependency chain before fixing anything

On a cold cluster it is 11–24 minutes, and it is **not** what the wave numbers imply:

```
external-secrets-operator ─> ClusterSecretStore is a PostSync hook at weight 999
                             components/external-secrets-operator/templates/clustersecretstore.yaml:7-8
        │  gates the PreSync ExternalSecret hooks in EIGHT components
        ▼
observascope-oss ──────────> owns 10 monitoring.coreos.com CRDs (+ servicelevelobjectives.pyrra.dev)
        │  (~21 min on AFA: 10:22:15 → 10:43:38)
        ▼
gen-dashboard / observascope-exporters / observascope-logging
  ← exhausted 6 attempts at 11m24s / 13m05s / 17m31s wall-clock
    (the 155s below is the BACKOFF SUM, not the give-up time - each attempt also
     costs its own render+apply, so wall-clock = 155s + 6x per-attempt cost)
```

```bash
# who owns the CRDs, and were they Synced?
kubectl --context hub-iac -n argocd get application observascope-oss-<CLUSTER> -o json \
| jq -r '[.status.resources[]|select(.kind=="CustomResourceDefinition")|"\(.name)\t\(.status)"]|sort[]'
```

---

## 3. The durable fix — gate the CR on Helm Capabilities

**ArgoCD DOES populate `.Capabilities.APIVersions` from the destination cluster.** Proven live
on `aws0prefdeveks01` (MR !374): after the gate merged, `ServiceMonitor/gen-dashboard-sm` stayed
present and `Synced`. Had it not, the CR would have left desired state and `prune: true` would
have deleted it.

```gotemplate
{{- if and ($.Capabilities.APIVersions.Has "monitoring.coreos.com/v1/ServiceMonitor") .Values.monitoring.serviceMonitor.enabled }}
```

Missing CRD → renders nothing → **sync Succeeds** → selfHeal never poisoned → CR applied on the
next reconcile once the CRD appears.

**The natural experiment that proves it:** of `observascope-logging`'s 5 monitoring CRs on AFA,
exactly one was already gated (`charts/loki/templates/monitoring/servicemonitor.yaml`). It was
the **only one that did not fail**. 1:1 correlation.

Rules:
- Capability string must be the full **`group/version/Kind`** — Helm's `VersionSet` is
  exact-match, so `monitoring.coreos.com/v1` alone does NOT satisfy
  `Has(".../v1/ServiceMonitor")`. Same for `helm template --api-versions` and helm-unittest.
- **Never gate something the app functionally needs** (headlamp's `ExternalSecret`,
  observascope-logging's `loki-gateway` Secret) → green-but-broken.
- Trade-off to state in the MR: while the CRD is absent the CR is absent from desired state, so
  with `prune: true` a render flap removes a previously-applied CR. Bounded monitoring gap.
- **5 of the 8** gated files live under a vendored `charts/<subchart>/` directory (both
  exporters x2, alloy); the other 3 are our own chart templates. The vendored 5 are exploded
  directories, not `.tgz`, — these are vendored-chart edits
  and can be lost on the next chart bump. Precedent: `d116b76`.
- **Gating a block can silently swallow a `fail()`/`required()` inside it.** If the CR template
  contains its own config-validation guard (e.g.
  `x509-certificate-exporter/templates/prometheusrule.yaml`'s
  `disableBuiltinAlertGroup` + empty `extraAlertGroups` → `fail "Extra alert groups..."`), wrapping
  the whole thing in the Capabilities `if` means that validation error only fires once the CRD
  exists — on a cold cluster the misconfigured render just looks like the intended no-op instead of
  erroring. Grep every file you gate for `fail(`/`required(` before merging; today's zero blast
  radius (no cluster sets the flag) is not permanent.

### Prove it with a control-diff render, never by reading the diff

```bash
SP=$(mktemp -d); WT=$SP/wt; git worktree add -q --detach "$WT" origin/main
AV=(--api-versions monitoring.coreos.com/v1/ServiceMonitor --api-versions monitoring.coreos.com/v1/PrometheusRule)
CL=clusters/<CLUSTER>
render(){ local t="$1" c="$2" o="$3"; shift 3
  helm template "$c" "$t/components/$c" -f "$t/components/$c/values.yaml" \
    -f "$t/$CL/values.yaml" -f "$t/$CL/$c/values.yaml" "$@" >"$o" 2>"$o.err"; }
for c in gen-dashboard observascope-exporters observascope-logging; do
  helm dependency build "$WT/components/$c" >/dev/null 2>&1
  helm dependency build "components/$c"     >/dev/null 2>&1
  render "$WT" "$c" "$SP/$c.A"            # ungated, no CRD
  render "."   "$c" "$SP/$c.B"            # gated,  no CRD  -> MUST be 0
  render "."   "$c" "$SP/$c.C" "${AV[@]}" # gated,  CRD     -> MUST equal A
  echo "$c A=$(grep -cE '^kind: (ServiceMonitor|PrometheusRule)$' $SP/$c.A)" \
       "B=$(grep -cE '^kind: (ServiceMonitor|PrometheusRule)$' $SP/$c.B)" \
       "C=$(grep -cE '^kind: (ServiceMonitor|PrometheusRule)$' $SP/$c.C)"
  diff -q "$SP/$c.A" "$SP/$c.C" && echo "  A==C byte-identical (no regression)"
done
```

Acceptance: **B == 0 everywhere**, and **A ≡ C byte-identical**. A chart whose C > A is fine iff
the surplus is a *pre-existing* gated template (suppressed in the no-api-versions control) —
confirm by diffing `^# Source:` lines, do not hand-wave it.

> ⚠️ **zsh does not word-split unquoted expansions.** `$AV` as a plain string becomes ONE
> argument and helm dies with `unknown flag`. Use an array and `"${AV[@]}"`.

### helm-unittest will break, and the fix is more coverage not less

helm-unittest supplies **no** cluster apiVersions, so any test asserting the CR renders fails
with `no manifest found`. Assert all three directions:

```yaml
  - it: renders when enabled and the CRD is present
    capabilities:
      apiVersions: [monitoring.coreos.com/v1/ServiceMonitor]   # full group/version/Kind
    asserts: [...original assertions unchanged...]
  - it: does not render when disabled
    capabilities:
      apiVersions: [monitoring.coreos.com/v1/ServiceMonitor]   # else it passes by accident
    set: { monitoring: { serviceMonitor: { enabled: false } } }
    asserts: [{ hasDocuments: { count: 0 } }]
  - it: does not render when the CRD is absent, even though enabled   # the incident case
    set: { monitoring: { serviceMonitor: { enabled: true } } }
    asserts: [{ hasDocuments: { count: 0 } }]
```

Run the whole sweep **with deps built** — `components-playground/endpoint-status-check` fails
locally without `helm dependency build` and it is a pre-existing local artifact, not your bug
(reproduce on clean `origin/main` before believing otherwise):

```bash
for root in components components-playground templates; do
  find "$root" -maxdepth 2 -type d -name tests | while read t; do c=$(dirname "$t")
    helm dependency build "$c" >/dev/null 2>&1
    helm unittest "$c" 2>&1 | grep -q FAIL && echo "FAIL $c" || echo "ok   $c"; done
done
```

---

## 4. Mitigation — retry envelope sizing

`limit: 5` / `duration 5s` / `factor 2` = `5+10+20+40+80 = 155s` over 6 attempts, against an
11–24 min requirement. Shipped (MRs !371/!373):

```yaml
retry:
  limit: 16          # was 5
  backoff:
    duration: 5s     # UNCHANGED - see below
    factor: 2        # UNCHANGED
    maxDuration: 60s # was 3m
```
= `5+10+20+40+60×12 = 795s` (13m15s) over 17 attempts.

**Why `duration`/`factor` must not be coarsened.** The CRD provider is *itself* a retrying
Application, so a coarser grid pushes **its own** post-dependency attempt later and inflates the
gap you are sizing against:

| settings | provider attempt-start grid (s) | first attempt after dep (702s) |
|---|---|---|
| `5 / 5s / 3m` | 0, 193, 391, 599, **827**, 1095 | 827 |
| `10 / 15s / 5m` | 0, 203, 421, 669, **977**, 1405 | **977 — worse** |
| `16 / 5s / 60s` | 0, 193, 391, 599, **827**, 1075 | **827 — unchanged** |

Costs to state honestly in the MR:
- Time-to-red rises to **~38-74 min** for the observed apps (it is `795s + 17 x per-attempt
  cost`, so it scales with how slow the app is: headlamp ~86s/attempt -> 37m45s; gen-dashboard
  ~88s -> 38m14s; observascope-logging ~149s -> 55m33s; observascope-eis ~216s -> 74m21s. A
  fast-failing app is ~19 min). **Alert on `sync.status` / `health.status`** (still move in
  2-4 min), never on `operationState.phase`.
- The `.operation` lock grows correspondingly; while set, autoSync early-returns and a UI sync is
  refused. Escape hatch:
  `kubectl --context hub-iac -n argocd patch application <app> --type json -p '[{"op":"remove","path":"/operation"}]'`
  (An op can hang regardless of `limit`: two `oidc` apps have had `.operation` set since
  2026-06-01/02.)
- Hook-secret churn scales with attempts: `observascope-oss` and `headlamp` `secrets.yaml`
  combine `randAlphaNum` with `hook-delete-policy: before-hook-creation` and set no
  `creationPolicy` → up to 17 delete/recreate cycles on a failing sync.

---

## 5. Canary on the playground first — it is genuinely isolated

`components-playground/` and `apps/appsets/playground-components-appset.yaml` are consumed by
**exactly one cluster**, `aws0prefdeveks01` (file generator pins it; and it is *excluded* from
`all-components`). **18** apps — the cluster's 19th, `bootstrap-aws0prefdeveks01`, comes from
`cluster-bootstrap` and does not consume `components-playground/`. That is the right place to land any appset or component change first.

What the canary can and cannot prove:
- **Can** prove blast radius: no re-sync storm, apps stay Synced+Healthy, `spec.project` stays
  `apps-allowed`. (That last one matters — it is recomputed from the cluster secret's
  `argocd.argoproj.io/kubernetes-version` label on **every** re-render, and a missing label parks
  apps in `apps-denied`, whose window is `deny / manualSync: false` and is **not** recoverable by
  a hand sync.)
- **Cannot** prove cold-start recovery — prefdev is already fully synced. Say so rather than
  overclaiming.

Snapshot **before**, so the after-check is a real diff:

```bash
kubectl --context hub-iac -n argocd get applications -o json \
| jq -r '.items[]|select(.metadata.name|endswith("-aws0prefdeveks01"))|.metadata.name as $n
  |.status.resources[]?|select(.kind=="ServiceMonitor" or .kind=="PrometheusRule" or .kind=="PodMonitor")
  |"\($n)\t\(.kind)/\(.name)\t\(.status)"' | sort > /tmp/mon-BEFORE.tsv
```
Reference baseline: **74** CRs, all Synced — of which only ~8 are gated, so the other ~66
(observascope-eis / observascope-oss / oidc) are a free control group.

---

## 6. Propagation is a 3-hop chain — do not conclude "it did not work"

A merge to `main` does **not** immediately change generated Applications:

```
GitLab main  →  CodeConnections mirror  →  app-of-apps Application  →  ApplicationSet  →  the Applications
```

`app-of-apps` syncs `apps/appsets` from the **CodeConnections** URL, so the appset *manifest*
only updates once app-of-apps picks up the new revision (~3 min poll + mirror lag).

```bash
kubectl --context hub-iac -n argocd get application app-of-apps \
  -o jsonpath='{.status.sync.revision}{"\n"}'      # compare against origin/main
kubectl --context hub-iac -n argocd get applicationset <appset> \
  -o jsonpath='{.spec.template.spec.syncPolicy.retry}'   # has the manifest updated?
```

Force it (same code path as its normal poll, safe):
```bash
kubectl --context hub-iac -n argocd annotate application app-of-apps \
  argocd.argoproj.io/refresh=hard --overwrite
```

Two traps here:
- **`git fetch` before you claim a revision "does not exist".** An agent (and I) both reported
  `app-of-apps` synced to a nonexistent sha; it was a stale local clone — the commit had just
  been merged. Always `git fetch -q origin` first.
- **All 155 `all-components` apps track `targetRevision: HEAD` on the same monorepo**, so *any*
  commit to main bumps their revision and triggers a re-sync. Blast radius is "playground-only"
  for **manifest content**, never for **sync activity**. Do not promise otherwise.

---

## 7. Remediating an already-stuck Application

Preconditions: the dependency now exists, and no operation is in flight. **Prefer the ArgoCD UI**
— it builds the operation correctly without hand-typing.

Headless equivalent. The 173 `all-components` + `playground-components` apps are
**multi-source** (of 182 generated — the 9 `bootstrap-*` apps use singular `source:`, so this
recipe would emit `revisions: null, sources: null` on them; do not run it against those) (`spec.source` absent,
`spec.sources` present, `status.sync.revision` null, `status.sync.revisions` populated), so the
singular `revision` field is inert and `syncOptions` are **not** inherited — derive everything
from the live object:

```bash
for app in <apps> ; do
  cur=$(kubectl --context hub-iac -n argocd get application "$app" -o json)
  [ "$(jq -r 'if .operation then "busy" else "free" end' <<<"$cur")" = free ] || { echo "SKIP $app busy"; continue; }
  payload=$(jq -c '{operation:{initiatedBy:{username:"'"$USER"'"},
      info:[{name:"Reason",value:"resync after CRD race (CRDs now present)"}],
      sync:{revisions:.status.sync.revisions, sources:.spec.sources, prune:true,
            syncOptions:.spec.syncPolicy.syncOptions, syncStrategy:{hook:{}}}}}' <<<"$cur")
  kubectl --context hub-iac -n argocd patch application "$app" --type merge -p "$payload"
done
```

**Do NOT blanket-resync.** Specifically leave alone:
- `observascope-oss` — if it is Synced/Healthy with only a cosmetic `phase: Failed`, a resync
  delete/recreates its 3 credential `ExternalSecrets` (`before-hook-creation`) and re-enters the
  health gate that actually failed. Net-zero at best.
- Anything Synced+Healthy whose only symptom is a stale `Failed` op — cosmetic.

Acceptance: the unapplied-resource list is empty.
```bash
kubectl --context hub-iac -n argocd get applications -o json \
| jq -r '.items[]|select(.spec.destination.server|test("<CLUSTER>"))|.metadata.name as $n
  |.status.resources[]?|select(.status!="Synced" and .status!=null)|"\($n) \(.kind)/\(.name) -> \(.status)"'
```

---

## 8. Not covered by any of the above

- **`endpoint-status-check` is architecturally doomed on a cold bootstrap** and the cause is a
  *template* line: `iac/argocd/template/clusters` hardcodes `runMode: Both` while repo A's
  default is `CronJob`. `Both` renders a **PostSync hook** Job (`backoffLimit: 0`,
  `restartPolicy: Never`) that probes 7 public HTTPS endpoints owned by four other Applications
  plus DNS+ALB+cert. 4 of the 8 clusters carrying it are parked at `Failed`, one since
  2026-05-11. Fix = delete that one template line; `failJobOnFailure: false` is the WRONG fix
  (shared configmap script, would blind the CronJob monitor too). Deleting it in the template
  fixes only *future* clusters — the 8 live `clusters/*/endpoint-status-check/values.yaml` need
  the same edit to unpark the existing ones.
- **`observascope-eis` / `observascope-oss` render ~66 more ungated monitoring CRs.**
  `observascope-eis` survived on AFA only because its sync was slow enough to outlast the CRD
  gap — luck, not design. Same bug class, not yet fixed. (`observascope-oss-chart` ≈95
  `ServiceMonitor`/`PrometheusRule` template lines across `karma/kube-prometheus-stack/
  monitoring-istio/pyrra/thanos`; `observascope-eis-chart` ≈51 across
  `monitoring-rules/pyrra-slo` — `grep -rl 'Capabilities.APIVersions' components/observascope-eis-chart/`
  = 0 hits as of !372.)
- **Two landmines sitting *inside* the very subcharts !372 gated, left ungated because their
  toggle defaults `false` fleet-wide today:** `observascope-exporters-chart/charts/
  x509-certificate-exporter/templates/podmonitor.yaml` (`.Values.prometheusPodMonitor.create`)
  and `observascope-logging-chart/templates/minio-buckets-sm.yaml`
  (`.Values.grafana-loki.minio.enabled`). Either flag flipping true on any cluster reintroduces
  this exact bug with zero warning. `components/coredns/templates/servicemonitor.yaml` is also
  fully unprotected (no gate, no `SkipDryRunOnMissingResource`).
- **A values comment can assert wave-based protection Fact 1 already disproves.**
  `clusters/<c>/cluster-component-config.yaml`'s `aws-inventory` entry carries "Wave 6: after
  ... observascope-oss (3, provides the ServiceMonitor/PrometheusRule CRDs)" — but
  `apps/appsets/all-components-appset.yaml` has no `spec.strategy` (AllAtOnce), so that ordering
  is fiction and `aws-inventory`'s own `prometheusrule.yaml`/`exporter.yaml` ServiceMonitor are
  ungated. Don't take a component's own comments as proof it's safe.
- **`apps/**` has no CI.** `.gitlab-ci.yml` `workflow.rules[].changes` omits `apps/` and
  `bootstrap/`, so an MR touching only the appsets runs **no pipeline**. Validate locally
  (`yaml.safe_load_all` + recompute the envelope from the *parsed* YAML).
- `spec.syncPolicy` is absent on all three appsets while 182/183 apps carry
  `resources-finalizer` → consider `preserveResourcesOnDeletion: true` before any appset change.

## Related
- [[argocd-appset-sync-wave-inert]] · [[argocd-capabilities-gate-from-destination-cluster]]
- [[argocd-clusters-template-lockstep]] · [[argocd_reconciliation_timing]]
- [[eks-managed-argocd-is-the-hub]] · [[argocd-appset-sync-wave-inert]]
- Skills: `argocd-cluster-onboarding` (failure mode 1), `eis-onesuite-e2e-verify`,
  `argocd-clusters-template-change`
