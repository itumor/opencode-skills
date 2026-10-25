---
name: eks-namespace-slow-tests-triage
description: Use when someone reports an EKS environment/namespace is "very slow", "tests run 6-8 hours", "smoke/ETCS/regression suite too slow on <cluster>:<namespace>", or asks whether ScaleOps/rightsizing/nodes are throttling an env. Read-only triage that first proves whether load reached the namespace at all, then node/CPU/throttle/error checks. Reference GENESIS-447154 (aws0v20deveks01/certification, 2026-10-16).
---

# EKS namespace "slow tests" triage (read-only)

Core rule: **prove load arrived before blaming infra.** GENESIS-447154: "tests 8 h" turned out to be zero test traffic for 3 days. Env idle, runner stuck.

## 0. Access
Skill `aws-kubectl-readonly-access`. `aws sts get-caller-identity --profile <P>` first; expired SSO = ask user once for `aws sso login --profile <P>`, then re-run sts (reply button != proof).
zsh: use a function `k(){ kubectl --context <ctx> "$@"; }`, not `C="--context x"` (no word split).

## 1. Snapshot (now)
```bash
k get nodes -L eks.amazonaws.com/nodegroup,node.kubernetes.io/instance-type
k top nodes
k -n <ns> top pods --sort-by=cpu | head -25
k -n <ns> get pods            # restarts, Pending, Completed jobs
```
Idle now proves nothing about the run window. Go to 2.

## 2. Timeline over run window (the decisive step)
```bash
k -n monitoring port-forward svc/observascope-oss-thanos-query 19090:9090 &   # observascope clusters
python3 ~/.claude/scripts/ns-load-timeline.py --ns <ns> --hours 96
pkill -f 'port-forward svc/observascope-oss-thanos-query 19090'
```
Columns: cores, CFS throttle %, Istio req/h (reporter=source), non-200/h.
- Constant req/h every hour (v20 certification: 11,640/h = 1 req/20 s per svc) = **probes only**. Test run must show a burst above that.
- Flat cores at baseline during reported run = no load reached env -> runner side (stuck, wrong URL, waiting on async step).
- Throttle % > ~10 during run = CPU limits too low -> check ScaleOps (step 3) and limits.
- Non-200 steady = probe-path errors; break down: `sum by (response_code,destination_service_name)(increase(istio_requests_total{reporter="source",destination_service_namespace="<ns>",response_code!="200"}[4d]))`. Constant 1/min 5xx on one svc = app broken (endpoints present => app-side).
Ad-hoc range joins: ONE shared `end` for every query (memory `prom-query-range-shared-end`).

## 3. ScaleOps excluded or not
Memory `scaleops-acting-check`: `automatednamespaces -A -o wide` auto flags, `scaleops*` annotations on pods/workloads/ns, `downscaleconfigurations -A`, resources == chart, replicas == ready.

## 4. App logs as activity proxy (Istio access log often off)
```bash
k -n <ns> logs <pod> --since=80h --timestamps | cut -c1-13 | sort | uniq -c   # lines per UTC hour
```
Business app (e.g. policy-generic-app) busy hours = real test activity. Flat heartbeat + nightly 00Z spike = idle. Grep repeated exceptions (e.g. okio `NoSuchMethodError` in OTel exporter = tracing broken, app team).

## 5. Hand back
Jira draft (caveman full): status line, checked list with numbers, reading, ask requester for: runner host/job URL, target base URL, start/end per run, per-test durations or stuck-test log. Never post it.

## 6. "Deploy stuck / slower than onprem" variant (GENESIS-447154, 2026-10-22)
Onprem Helm values can leak into AWS (`nfs-csi-sc` PVCs; AWS RWM class is `efs-sc`). Check before blaming nodes:
```bash
k get sc; k get pods -A --no-headers | grep -v -E 'Running|Completed'; k get pvc -A --no-headers | grep -v Bound
k get sts,deploy,job,cronjob,pod -A -o json | grep -c 'nfs-csi'   # 0 = value comes from the deploy job's rendered values, not the cluster
k get events -A --sort-by=.lastTimestamp --field-selector type=Warning | tail -15
```
Also compare like with like: a from-scratch AWS rebuild (DB prep, postgres, solr, deployer jobs) is not an onprem re-run. Jira read: `zsh -ic 'curl ... $JIRA_TOKEN ... -o file'` (memory `jira-token-location`).
