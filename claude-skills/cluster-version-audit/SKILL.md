---
name: cluster-version-audit
description: Live version audit of EIS EKS clusters — queries running pod images and node kubelet version for all standard components (eso, istio, external-dns, metrics-server, oauth-proxy, gen-dashboard, grafana, cluster-autoscaler, aws-lb-controller, headlamp). Use when asked to verify, update, or compare cluster component versions across the EIS fleet.
---

# EIS Cluster Version Audit

Produces a live version matrix from `kubectl` — not from git. Git config drifts from live state (ArgoCD OutOfSync, manual changes). Always query clusters directly.

## Cluster → AWS Profile map

| Cluster | AWS Profile | Account |
|---------|------------|---------|
| aws0prefdeveks01 | PTO-Reference | 468381823127 |
| aws0caadeveks01 | Credit-Agricole | 691064586749 |
| aws0iacdeveks01 | EIS-IaC | 182399717428 |
| aws0v20deveks01 | V20-Sandbox | 851725487952 |
| aws0v20perfdeveks01 | PNT-Performance | 850995559528 |
| aws0fvfv01eks01 | Feature-Validation | 207414098330 |
| aws0fvfv04eks01 | Feature-Validation | 207414098330 |
| aws0fvfv05eks01 | Feature-Validation | 207414098330 |
| aws0fvdemoeks01 | Feature-Validation | 207414098330 |

**Gone (decommissioned, not in any account as of 2026-05-22):** aws0obsdeveks01, aws0fvfv03eks01

## Phase 1 — Ensure kubeconfig contexts exist

```bash
# Already present (from previous setup):
# arn:aws:eks:us-west-2:468381823127:cluster/aws0prefdeveks01
# arn:aws:eks:us-west-2:691064586749:cluster/aws0caadeveks01
# arn:aws:eks:us-west-2:182399717428:cluster/aws0iacdeveks01
# arn:aws:eks:us-west-2:850995559528:cluster/aws0v20perfdeveks01

# Add if missing:
aws --profile V20-Sandbox      eks update-kubeconfig --name aws0v20deveks01   --region us-west-2 --alias aws0v20deveks01
aws --profile Feature-Validation eks update-kubeconfig --name aws0fvfv01eks01 --region us-west-2 --alias aws0fvfv01eks01
aws --profile Feature-Validation eks update-kubeconfig --name aws0fvfv04eks01 --region us-west-2 --alias aws0fvfv04eks01
aws --profile Feature-Validation eks update-kubeconfig --name aws0fvfv05eks01 --region us-west-2 --alias aws0fvfv05eks01
aws --profile Feature-Validation eks update-kubeconfig --name aws0fvdemoeks01 --region us-west-2 --alias aws0fvdemoeks01
```

## Phase 2 — Per-cluster version probe script

```bash
cat << 'EOF' > /tmp/get_cluster_versions.sh
#!/bin/bash
CTX="$1"
CLUSTER=$(echo $CTX | sed 's|.*cluster/||')
k() { kubectl --context "$CTX" "$@" 2>/dev/null; }
img_ver() { echo "$1" | sed 's/.*://' | sed 's/^v//'; }

K8S=$(k get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' | sed 's/v//' | sed 's/-eks.*//')

ESO=$(k get pods -n external-secrets -l 'app.kubernetes.io/name=external-secrets' \
  -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/version}' | sed 's/^v//')
[ -z "$ESO" ] && ESO="-"

ISTIO_IMG=$(k get pods -n istio-system -l app=istiod -o jsonpath='{.items[0].spec.containers[0].image}')
ISTIO=$(img_ver "$ISTIO_IMG"); [ -z "$ISTIO" ] && ISTIO="-"

EDNS_IMG=$(k get pods -n kube-system -l 'app.kubernetes.io/name=external-dns' -o jsonpath='{.items[0].spec.containers[0].image}')
[ -z "$EDNS_IMG" ] && EDNS_IMG=$(k get pods -n kube-system -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep external-dns | head -1)
EDNS=$(img_ver "$EDNS_IMG"); [ -z "$EDNS" ] && EDNS="-"

MS_IMG=$(k get pods -n kube-system -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep metrics-server | head -1)
MS=$(img_ver "$MS_IMG"); [ -z "$MS" ] && MS="-"

OAUTH_IMG=$(k get pods -n oidc -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep oauth2-proxy | head -1)
OAUTH=$(img_ver "$OAUTH_IMG"); [ -z "$OAUTH" ] && OAUTH="-"

GENDASH_IMG=$(k get pods -n monitoring -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep gen-dashboard | head -1)
GENDASH=$(img_ver "$GENDASH_IMG"); [ -z "$GENDASH" ] && GENDASH="-"

# GOTCHA: grafana pod has sidecars first — must get container named exactly "grafana"
GRAFANA=$(k get pods -n monitoring -l 'app.kubernetes.io/name=grafana' \
  -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/version}')
if [ -z "$GRAFANA" ]; then
  POD=$(k get pods -n monitoring 2>/dev/null | grep grafana | awk '{print $1}' | head -1)
  GRAFANA_IMG=$(k get pod -n monitoring "$POD" \
    -o jsonpath='{range .spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}' \
    | grep '^grafana	' | awk '{print $2}')
  GRAFANA=$(img_ver "$GRAFANA_IMG")
fi
[ -z "$GRAFANA" ] && GRAFANA="-"

CA_IMG=$(k get pods -n kube-system -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep cluster-autoscaler | head -1)
CA=$(img_ver "$CA_IMG"); [ -z "$CA" ] && CA="-"

ALB_IMG=$(k get pods -n kube-system -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep aws-load-balancer-controller | head -1)
ALB=$(img_ver "$ALB_IMG"); [ -z "$ALB" ] && ALB="-"

HL_IMG=$(k get pods -n monitoring -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | grep headlamp | head -1)
HL=$(img_ver "$HL_IMG"); [ -z "$HL" ] && HL="-"

echo "$CLUSTER	$K8S	$ESO	$ISTIO	$EDNS	$MS	$OAUTH	$GENDASH	$GRAFANA	$CA	$ALB	$HL"
EOF
chmod +x /tmp/get_cluster_versions.sh
```

## Phase 3 — Run all clusters in parallel

```bash
printf "Cluster\tK8s\teso\tistio\texternal-dns\tmetrics-server\toauth-proxy\tgen-dashboard\tgrafana\tcluster-autoscaler\taws-lb-controller\theadlamp\n"

CLUSTERS=(
  "arn:aws:eks:us-west-2:468381823127:cluster/aws0prefdeveks01"
  "arn:aws:eks:us-west-2:691064586749:cluster/aws0caadeveks01"
  "arn:aws:eks:us-west-2:182399717428:cluster/aws0iacdeveks01"
  "aws0v20deveks01"
  "arn:aws:eks:us-west-2:850995559528:cluster/aws0v20perfdeveks01"
  "aws0fvfv01eks01"
  "aws0fvfv04eks01"
  "aws0fvfv05eks01"
  "aws0fvdemoeks01"
)

TMPDIR_R=$(mktemp -d)
for ctx in "${CLUSTERS[@]}"; do
  (bash /tmp/get_cluster_versions.sh "$ctx" > "$TMPDIR_R/$(echo $ctx | sed 's|.*cluster/||')" 2>/dev/null) &
done
wait

for ctx in "${CLUSTERS[@]}"; do
  name=$(echo $ctx | sed 's|.*cluster/||')
  cat "$TMPDIR_R/$name" 2>/dev/null || echo "$name	ERROR"
done
rm -rf "$TMPDIR_R"
```

## Phase 4 — update the tracking Google Sheet

Results feed a fleet version-tracking sheet:
- **Doc id:** `1p_SUd3NU4zkumgFdFFESQANcpcJAxD_40KR9LB3vafc` (gid 1773962645). Two tables: on-prem `*genkub*` (top) and **AWS EKS** (bottom — matches this skill's columns + `ArgoCD-managed?` + `comments`).
- Read current content: `mcp__claude_ai_Google_Drive__read_file_content` with that fileId (returns both tables as markdown — gives you existing `comments` to preserve).

**WRITE IS BLOCKED:** only Google **Drive** MCP tools exist (read/create/copy) — no Sheets cell/range-write. Cannot edit the existing sheet in place. Deliver to the user instead:
1. **Exact cell edits** — table of `cluster | column | sheet-now → live`, only changed cells.
2. **Paste-ready TSV** — full updated AWS table, tab-delimited, in a code block, for paste-over.

Preserve the existing `comments` column and the `~~CLUSTER GONE~~` rows (obs/fv03) when emitting the TSV. Only direct push path is an out-of-band `gspread`/Sheets-API script the user runs as `! python ...`.

## Critical gotchas

### grafana sidecar container order
The kube-prometheus-stack grafana pod has 3 containers: `grafana-sc-dashboard`, `grafana-sc-datasources`, `grafana` (the actual one). `{.spec.containers[0].image}` gives the sidecar (`kiwigrid/k8s-sidecar`), NOT grafana. Use the `app.kubernetes.io/version` pod label (newer charts set this), or filter by exact container name `grep '^grafana\t'`.

### helm list is useless for version detection here
All ArgoCD-managed components are wrapper charts with `appVersion: 1.0`. `helm list -A` returns `1.0` for every component — does not reflect the actual dependency chart version deployed. Always query pod images.

### external-dns: config ≠ deployed
`cluster-component-config.yaml` may list external-dns but if there is no `external-dns/` subdirectory under `clusters/<name>/` in the ArgoCD repo, the AppSet never creates the Application and it is NOT deployed. Prefdev, iacdev, v20dev all have it in config but no directory → NOT deployed.

### oauth-proxy: chart version vs image tag (NOT drift)
`components/oidc/Chart.yaml` declares the oauth2-proxy **helm chart** `7.13.0`, whose `appVersion`/image tag is `v7.9.0`. The probe reads the image → `7.9.0`. So git `7.13.0` rendering live `7.9.0` is **in sync**, not drift. Verified 2026-06-01: all `oidc` apps Synced. Do not flag this as OutOfSync by comparing the two numbers — confirm real drift via hub app status (Phase 3.5). Exception: aws0v20perfdeveks01 genuinely runs a literal image tag `7.13.0` (different bundle).

### confirm real drift via ArgoCD hub (Phase 3.5)
The hub is **aws0iacdeveks01** `argocd` namespace; it manages all spokes. To separate real OutOfSync from chart-vs-image noise:
```bash
kubectl --context arn:aws:eks:us-west-2:182399717428:cluster/aws0iacdeveks01 \
  get applications -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
  --no-headers | grep -v 'Synced *Healthy' | sort
```
istiod git declares multiple subcharts (1.15.5/1.19.1/1.20.3/1.29.0) gated by `istiod_<v>.enabled` conditions — live istio = whichever flag is enabled; verify via Synced app status, not the first dep line.

### fv01 grafana version
aws0fvfv01eks01 uses an older kube-prometheus-stack bundle → grafana `10.4.1`, not `11.6.0` like all other clusters.
