---
name: cast-save
description: >
  Comprehensive CAST AI cluster optimization analysis. Combines seven checks into one skill:
  (1) Evictor log parsing to find nodes blocked from consolidation,
  (2) Pod health scan for Pending/Failed/CrashLoopBackOff pods,
  (3) Max-pod-per-node analysis showing each node configuration's pod limit and flagging nodes running at capacity,
  (4) Node template analysis identifying redundant templates and consolidation opportunities based on arch, capacity type, OS, and taints,
  (5) Node template CPU:Memory ratio profiling to recommend memory-heavy, compute-heavy, or general-purpose instance families plus a DaemonSet overhead advisory for large clusters,
  (6) Rebalancing analysis surfacing executed/partial/failed/skipped plans, last completed rebalance with savings, configured schedules, and leftover old on-demand nodes,
  (7) WOOP rollout strategy audit checking for one-by-one rollout and zero-downtime enforcement on single-replica workloads.
 
---

# Cast Optimise

Full CAST AI cluster optimization analysis: evictor blockers + pod health + max-pod-per-node capacity + node template consolidation.
Supports single-cluster and org-wide execution (batches of 10).

---

## Inputs

- **Cluster ID** (option A): UUID of a single target cluster.
- **Org ID** (option B): UUID of an org. Runs across all connected clusters in batches of 10.
- **Time range** (optional): Defaults to `now-5m` to `now` for evictor logs. Accept natural language like "last 1h", "last 30m".

---

## Input Resolution

### If a Cluster ID is provided
Proceed directly to Step 1 (single-cluster flow).

### If an Org ID is provided
Run the org-wide flow:

1. Call `castai-remote:list_clusters` with `organization_id = <org_id>`.
2. Filter to clusters where `status == "ready"` AND `agentStatus == "online"`. These are the connected clusters.
3. Announce: `Found <N> connected clusters. Running analysis in batches of 10.`
4. Split the list into batches of 10.
5. For each batch, announce: `Batch <X>/<total> -- processing: <name1>, <name2>, ...`
6. Run Steps 1 through 6 for each cluster in the batch sequentially.
7. After all batches complete, output the Org-Wide Summary (see bottom of this skill).

If a cluster times out or errors, mark it as `Timeout / Error` and continue. Do not abort the batch.

---

## Step 1: Evictor Log Query

Use `castai-remote:loki_query`:

```
query: {alert_group="console/evictor"} |= "<cluster_id>"
start: now-5m   (or user-specified)
end:   now
limit: 500
```

If zero results, retry with `start: now-1h` before declaring no data.

---

## Step 2: Parse Evictor Logs

Extract all entries matching:

```
msg="evictor log received: #<N> node - <node_name> eliminated by filters, reason: <reason> - <namespace>/<pod>"
```

Also capture:
- `msg="... work function finished"` -> extract `duration` for reconcile timing
- `msg="... found no nodes to evict"` -> no evictions
- `msg="... couldn't find any nodes to drain"` -> drain outcome

### Blocker reason categories

| Raw reason | Category |
|---|---|
| `single replica` | Single Replica |
| `statefulset pods` | StatefulSet |
| `removal disabled` | Removal Disabled (annotation) |
| `not reschedulable` | Not Reschedulable |
| `pdb` | PDB Violation |
| `local storage` | Local Storage |
| anything else | Other |

---

## Step 3: Evictor Output (per cluster)

### Header

```
Cluster: <cluster_name> (<cluster_id>)
Window:  <start> -> <end>
Reconcile cycles observed: <N>
Evictions: <count or "None">
```

### Blocker Table

Deduplicate nodes across reconcile cycles. Same node blocked repeatedly = one row.

| Node | Category | Blocking Pod | Namespace |
|---|---|---|---|
| `cast-pool-xxxxx` | StatefulSet | `pod-name` | `namespace` |

Sort order: StatefulSet -> Single Replica -> Removal Disabled -> Not Reschedulable -> PDB -> Other.

### Summary

```
X nodes blocked. Top blockers: <category (count)>, <category (count)>.
[If no evictions] Evictor is running but consolidation is fully blocked.
[If evictions happened] <N> evictions completed this window.
```

### Actionable callouts (only if applicable)

- **Single Replica**: adding a replica or enabling `spotInstances` unblocks the node.
- **Removal Disabled**: pod carries `cast.ai/node-removal-disabled` -- intentional customer config.
- **Not Reschedulable**: no suitable node exists to reschedule the pod.

---

## Step 4: Pod Health Scan (per cluster)

Run using `castai-remote:analyze_snapshot_with_code`:

### Analysis code

```python
pods = snapshot.get_pods()
result = []
for pod in pods:
    phase = safe_get(pod, 'status.phase', 'Unknown')
    if phase in ('Running', 'Succeeded'):
        container_statuses = safe_get(pod, 'status.containerStatuses', [])
        bad_containers = []
        for cs in container_statuses:
            state = cs.get('state', {})
            waiting = state.get('waiting', {})
            terminated = state.get('terminated', {})
            reason = waiting.get('reason', '') or terminated.get('reason', '')
            bad_reasons = {'CrashLoopBackOff', 'OOMKilled', 'ImagePullBackOff', 'ErrImagePull',
                           'Error', 'CreateContainerConfigError', 'InvalidImageName'}
            if reason in bad_reasons:
                bad_containers.append({
                    'container': cs.get('name'),
                    'state': 'waiting' if waiting else 'terminated',
                    'reason': reason,
                    'message': (waiting.get('message', '') or terminated.get('message', ''))[:200],
                    'restart_count': cs.get('restartCount', 0)
                })
        if bad_containers:
            result.append({
                'name': safe_get(pod, 'metadata.name'),
                'namespace': safe_get(pod, 'metadata.namespace'),
                'phase': phase,
                'containers': bad_containers
            })
    else:
        container_statuses = safe_get(pod, 'status.containerStatuses', [])
        init_container_statuses = safe_get(pod, 'status.initContainerStatuses', [])
        containers = []
        for cs in container_statuses + init_container_statuses:
            state = cs.get('state', {})
            waiting = state.get('waiting', {})
            terminated = state.get('terminated', {})
            last_state = cs.get('lastState', {})
            last_terminated = last_state.get('terminated', {})
            containers.append({
                'container': cs.get('name'),
                'ready': cs.get('ready', False),
                'restart_count': cs.get('restartCount', 0),
                'state': 'waiting' if waiting else ('terminated' if terminated else 'running'),
                'reason': waiting.get('reason', '') or terminated.get('reason', ''),
                'message': (waiting.get('message', '') or terminated.get('message', ''))[:200],
                'last_reason': last_terminated.get('reason', ''),
                'last_exit_code': last_terminated.get('exitCode', '')
            })
        result.append({
            'name': safe_get(pod, 'metadata.name'),
            'namespace': safe_get(pod, 'metadata.namespace'),
            'phase': phase,
            'reason': safe_get(pod, 'status.reason', ''),
            'message': safe_get(pod, 'status.message', ''),
            'containers': containers
        })
```

### Pod health output

```
### Pod Health

| Pod | Namespace | Phase | Container | State | Reason | Restarts |
|---|---|---|---|---|---|---|
| <pod> | <ns> | Failed/Pending | <container> | waiting/terminated | CrashLoopBackOff | 4 |
```

If no unhealthy pods: `All pods healthy -- no Pending/Failed/CrashLoopBackOff pods found.`

---

## Step 5: Cross-Reference Blockers with Unhealthy Pods

Check if any unhealthy pods from Step 4 also appear in the evictor blocker table from Step 3. If matched:

```
WARNING  Cross-match: <pod> in <namespace> is blocking node <node> AND is in a bad state (<reason>).
    This pod cannot be rescheduled, which explains the persistent eviction block.
```

Present cross-matches first, before the detailed tables. This is the highest-value output.

---

## Step 6: Max Pod Per Node Analysis

This step identifies the max pod limit for each node configuration and flags nodes running at or near capacity.

### 7a: Run snapshot analysis

Use `castai-remote:analyze_snapshot_with_code`:

```python
nodes = snapshot.get_nodes()
pods = snapshot.get_pods()

# Count running pods per node
from collections import defaultdict
pods_per_node = defaultdict(int)
for pod in pods:
    phase = safe_get(pod, 'status.phase', 'Unknown')
    node_name = safe_get(pod, 'spec.nodeName', '')
    if node_name and phase in ('Running', 'Pending'):
        pods_per_node[node_name] += 1

result = []
for node in nodes:
    name = safe_get(node, 'metadata.name', '')
    instance_type = safe_get(node, 'metadata.labels.node\\.kubernetes\\.io/instance-type', '')
    if not instance_type:
        instance_type = safe_get(node, 'metadata.labels.beta\\.kubernetes\\.io/instance-type', '')

    # Node config / template label (CAST AI specific)
    node_config = safe_get(node, 'metadata.labels.scheduling\\.cast\\.ai/node-template', '')
    if not node_config:
        node_config = safe_get(node, 'metadata.labels.provisioner\\.cast\\.ai/node-template', '')

    # Provider detection
    provider_id = safe_get(node, 'spec.providerID', '')
    provider = 'unknown'
    if 'aws' in provider_id:
        provider = 'EKS'
    elif 'gce' in provider_id or 'gke' in provider_id:
        provider = 'GKE'
    elif 'azure' in provider_id:
        provider = 'AKS'

    # Max pods from node status
    allocatable_pods = int(safe_get(node, 'status.allocatable.pods', '0'))
    capacity_pods = int(safe_get(node, 'status.capacity.pods', '0'))

    running_pods = pods_per_node.get(name, 0)

    # Utilization percentage
    utilization_pct = round((running_pods / allocatable_pods) * 100, 1) if allocatable_pods > 0 else 0

    # Flag if at or near capacity (>= 95%)
    at_capacity = running_pods >= allocatable_pods
    near_capacity = utilization_pct >= 95.0

    result.append({
        'node_name': name,
        'instance_type': instance_type,
        'node_config': node_config,
        'provider': provider,
        'capacity_pods': capacity_pods,
        'allocatable_pods': allocatable_pods,
        'running_pods': running_pods,
        'utilization_pct': utilization_pct,
        'at_capacity': at_capacity,
        'near_capacity': near_capacity
    })

# Sort: at-capacity first, then near-capacity, then by utilization descending
result.sort(key=lambda x: (not x['at_capacity'], not x['near_capacity'], -x['utilization_pct']))
```

### 7b: Max pod formula reference

Include this context in the output so the TAM/customer understands where the limits come from:

**EKS (AWS VPC CNI)**:
`Max pods = (Number of ENIs for instance type * (IPv4 addresses per ENI - 1)) + 2`
This is the default ENI-based formula. If prefix delegation is enabled, the formula changes to:
`Max pods = (Number of ENIs * ((IPv4 addresses per ENI - 1) * 16)) + 2`
The kubelet `--max-pods` flag or EKS `max-pods-calculator.sh` may override this.

**GKE**:
Default is 110 pods per node. Configurable via `--max-pods-per-node` at node pool creation. Cannot be changed after creation.

**AKS**:
Default is 30 pods per node (kubenet) or 250 (Azure CNI). Configurable via `--max-pods` at node pool creation.

### 7c: Output

```
### Max Pod Per Node Analysis

#### Node Configuration Summary

| Node Config | Instance Type | Provider | Max Pods (allocatable) | Nodes |
|---|---|---|---|---|
| default | m5.xlarge | EKS | 58 | 12 |
| high-pod | m5.2xlarge | EKS | 58 | 4 |
```

Group nodes by (node_config + instance_type) and show the allocatable pod count and number of nodes with that configuration.

#### Nodes at or Near Pod Capacity

| Node | Instance Type | Config | Allocatable | Running | Utilization |
|---|---|---|---|---|---|
| cast-pool-abc123 | m5.xlarge | default | 58 | 58 | 100% AT CAPACITY |
| cast-pool-def456 | m5.xlarge | default | 58 | 56 | 96.6% NEAR CAPACITY |

Only show nodes >= 95% utilization. If none, output: `No nodes at or near pod capacity.`

#### Callouts

- **Nodes at 100% pod capacity** cannot accept new pods regardless of CPU/memory availability. New pods targeting these nodes will remain Pending. This is a common silent issue on EKS clusters with small instance types.
- **If many nodes are near capacity**, consider: increasing instance size, enabling prefix delegation (EKS), or adjusting the `--max-pods` setting on the node configuration.
- **EKS-specific**: If max pods is low relative to instance size (e.g., m5.4xlarge with only 58 pods), prefix delegation is likely not enabled. Enabling it can increase the limit significantly.

---

## Step 7: Node Template Analysis

This step inventories all node templates active in the cluster and identifies consolidation opportunities based on architecture, capacity type, OS, and taints.

### 7a: Run snapshot analysis

Use `castai-remote:analyze_snapshot_with_code`:

```python
from collections import defaultdict

nodes = snapshot.get_nodes()

templates = defaultdict(lambda: {
    'count': 0,
    'arch': set(),
    'capacity_type': set(),
    'os': set(),
    'instance_types': set(),
    'taints': set(),
    'taint_keys': set(),
    'gpu': False
})

for node in nodes:
    labels = safe_get(node, 'metadata.labels', {})
    spec_taints = safe_get(node, 'spec.taints', [])

    template = (
        labels.get('scheduling.cast.ai/node-template') or
        labels.get('provisioner.cast.ai/node-template') or
        'unknown'
    )

    arch = labels.get('kubernetes.io/arch', 'unknown')
    os = labels.get('kubernetes.io/os', 'linux')
    instance_type = (
        labels.get('node.kubernetes.io/instance-type') or
        labels.get('beta.kubernetes.io/instance-type') or
        'unknown'
    )

    # Capacity type: spot vs on-demand
    is_spot = (
        labels.get('cast.ai/spot', '').lower() in ('true', '1') or
        labels.get('node.kubernetes.io/capacity-type', '').lower() == 'spot' or
        labels.get('topology.cast.ai/life-cycle', '').lower() == 'spot'
    )
    capacity = 'spot' if is_spot else 'on-demand'

    # GPU detection
    is_gpu = any(
        'gpu' in k.lower() or 'nvidia' in k.lower() or 'amd.com/gpu' in k.lower()
        for k in labels
    )

    # Taints: collect effect+key combos
    taint_strs = set()
    taint_keys = set()
    for t in spec_taints:
        key = t.get('key', '')
        effect = t.get('effect', '')
        value = t.get('value', '')
        taint_strs.add(f"{key}={value}:{effect}" if value else f"{key}:{effect}")
        taint_keys.add(key)

    t = templates[template]
    t['count'] += 1
    t['arch'].add(arch)
    t['capacity_type'].add(capacity)
    t['os'].add(os)
    t['instance_types'].add(instance_type)
    t['taints'].update(taint_strs)
    t['taint_keys'].update(taint_keys)
    if is_gpu:
        t['gpu'] = True

result = []
for name, data in templates.items():
    result.append({
        'template': name,
        'count': data['count'],
        'arch': sorted(data['arch']),
        'capacity_type': sorted(data['capacity_type']),
        'os': sorted(data['os']),
        'instance_types': sorted(data['instance_types']),
        'taints': sorted(data['taints']),
        'taint_keys': sorted(data['taint_keys']),
        'gpu': data['gpu']
    })

result.sort(key=lambda x: -x['count'])
```

### 7b: Consolidation logic

After collecting the template inventory, evaluate every pair of templates for merge candidacy:

**MERGE CANDIDATE** if ALL of:
- Same arch (e.g., both `arm64`, or both `amd64`)
- Same capacity type (both `on-demand` or both `spot`)
- Same OS
- Same taints (or both have no taints)
- No GPU on either

**KEEP SEPARATE** if ANY of:
- Different arch
- Different capacity type (spot vs on-demand = different reliability tier, never merge)
- GPU taint on one or both
- Different taints (workloads are explicitly scoped to the template)
- One template has dedicated namespace taints (e.g., `dedicated=<ns>:NoSchedule`)

**SPOT PREDICTION MODEL advisory**: For every template where `capacity_type` includes `spot`, check whether the Cast AI spot prediction model is enabled. Emit a recommendation regardless of whether the check can be confirmed from snapshot data -- spot template presence alone is sufficient to trigger this.

If a template has mixed arch or mixed capacity type within itself, flag it separately as a **MISCONFIGURED TEMPLATE** -- it means multiple node types are being grouped under one template, which reduces scheduling predictability.

### 7c: Output

```
### Node Template Analysis

#### Template Inventory

| Template | Nodes | Arch | Capacity | OS | Instance Types | Taints |
|---|---|---|---|---|---|---|
| default | 12 | amd64 | on-demand | linux | m5.xlarge, m5.2xlarge | None |
| arm-batch | 5 | arm64 | on-demand | linux | m7g.xlarge | None |
| arm-prod | 3 | arm64 | on-demand | linux | m7g.2xlarge | None |
| gpu-nodes | 2 | amd64 | on-demand | linux | p3.2xlarge | nvidia.com/gpu:NoSchedule |
| spot-workers | 8 | amd64 | spot | linux | m5.xlarge, m5.large | None |

Total templates: <N>
```

#### Consolidation Recommendations

For each merge candidate pair:

```
MERGE CANDIDATE: `<template-a>` + `<template-b>`
  Reason: Both <arch>, <capacity>, <os>, no taints
  Impact: Reduces template fragmentation. Workloads scheduled on either template
          will behave identically. Fewer templates = simpler node lifecycle management.
  Action: Merge into a single template. Validate workload node selectors / affinities
          to confirm no hard reference to either template name.
```

For each keep-separate:

```
KEEP SEPARATE: `<template>`
  Reason: <specific reason -- GPU taint / spot / different arch / dedicated taint>
```

For misconfigured templates (mixed arch or mixed capacity within one template):

```
MISCONFIGURED: `<template>` has mixed <arch/capacity>: [<values>]
  This reduces scheduling determinism. Split into separate templates per arch/capacity type.
```

If all templates are appropriately configured and distinct:

```
No consolidation opportunities found. All templates are differentiated by arch, capacity type, or taint.
```

#### Spot Prediction Model Advisory

For every template with `capacity_type == spot`, output the following (regardless of other findings):

```
SPOT ADVISORY: `<template>` uses spot instances.
  Enable the Cast AI Spot Prediction Model on this node template to reduce interruption
  risk. The model analyses real-time spot market signals and avoids instance types with
  high interruption probability, improving cluster stability without sacrificing cost savings.
  Action: In the Cast AI console -> Node Templates -> <template> -> enable Spot Prediction.
```

If no spot templates are found: omit this section entirely.

#### Summary line

```
<N> templates active. <M> merge candidates identified. <P> spot templates (spot prediction advisory). <Q> templates correctly scoped.
```

---

## Step 7d: Node Template CPU:Memory Ratio Analysis

This step analyses the CPU-to-memory ratio of workload requests per node template and recommends the appropriate instance family.

### 7d-i: Run snapshot analysis

Use `castai-remote:analyze_snapshot_with_code`:

```python
from collections import defaultdict

nodes = snapshot.get_nodes()
pods  = snapshot.get_pods()

# Map node name -> template
node_template_map = {}
for node in nodes:
    labels = safe_get(node, 'metadata.labels', {})
    template = (
        labels.get('scheduling.cast.ai/node-template') or
        labels.get('provisioner.cast.ai/node-template') or
        'unknown'
    )
    node_name = safe_get(node, 'metadata.name', '')
    node_template_map[node_name] = template

# Aggregate requested CPU and memory per template
# Only count non-DaemonSet pods for the ratio (DaemonSets are overhead)
template_requests = defaultdict(lambda: {'cpu_m': 0, 'mem_mi': 0, 'node_count': 0})
template_ds_requests = defaultdict(lambda: {'cpu_m': 0, 'mem_mi': 0})
node_templates_seen = defaultdict(set)

def parse_cpu(val):
    """Parse CPU string to millicores int."""
    if not val:
        return 0
    val = str(val).strip()
    if val.endswith('m'):
        return int(val[:-1])
    try:
        return int(float(val) * 1000)
    except:
        return 0

def parse_mem(val):
    """Parse memory string to MiB int."""
    if not val:
        return 0
    val = str(val).strip()
    units = {'Ki': 1/1024, 'Mi': 1, 'Gi': 1024, 'Ti': 1024*1024,
             'K': 1/1024*1000/1024, 'M': 1000/1024, 'G': 1000*1000/1024/1024}
    for suffix, factor in units.items():
        if val.endswith(suffix):
            try:
                return int(float(val[:-len(suffix)]) * factor)
            except:
                return 0
    try:
        return int(int(val) / (1024*1024))
    except:
        return 0

total_ds_cpu_m  = 0
total_cpu_m     = 0
total_mem_mi    = 0
total_node_count = len(nodes)

for pod in pods:
    phase     = safe_get(pod, 'status.phase', '')
    node_name = safe_get(pod, 'spec.nodeName', '')
    if phase not in ('Running', 'Pending') or not node_name:
        continue

    template = node_template_map.get(node_name, 'unknown')
    node_templates_seen[template].add(node_name)

    owners   = safe_get(pod, 'metadata.ownerReferences', [])
    is_ds    = any(o.get('kind') == 'DaemonSet' for o in owners)

    cpu_total  = 0
    mem_total  = 0
    for c in safe_get(pod, 'spec.containers', []):
        req = safe_get(c, 'resources.requests', {})
        cpu_total += parse_cpu(req.get('cpu', '0'))
        mem_total += parse_mem(req.get('memory', '0'))

    if is_ds:
        template_ds_requests[template]['cpu_m']  += cpu_total
        template_ds_requests[template]['mem_mi'] += mem_total
        total_ds_cpu_m += cpu_total
    else:
        template_requests[template]['cpu_m']  += cpu_total
        template_requests[template]['mem_mi'] += mem_total

    total_cpu_m  += cpu_total
    total_mem_mi += mem_total

# Build per-template profile
result = []
for tmpl, req in template_requests.items():
    cpu_m  = req['cpu_m']
    mem_mi = req['mem_mi']
    cpu_vcpu = cpu_m / 1000.0

    # Ratio: vCPU per GiB of memory
    mem_gi = mem_mi / 1024.0

    # Determine pattern from CPU:Memory ratio
    # cpu_per_gi = cpu_vcpu / mem_gi (how many vCPU per GiB)
    # 1:4 means 1 vCPU per 4 GiB -> cpu_per_gi = 0.25
    # 1:2 means 1 vCPU per 2 GiB -> cpu_per_gi = 0.50
    if mem_gi == 0:
        cpu_per_gi = 9999  # effectively infinite -> compute-heavy
    else:
        cpu_per_gi = cpu_vcpu / mem_gi

    if cpu_per_gi <= 0.25:       # 1:4 or more memory-heavy
        pattern = 'memory-heavy'
    elif cpu_per_gi >= 0.5:      # 1:2 or more compute-heavy
        pattern = 'compute-heavy'
    else:                         # between 1:4 and 1:2
        pattern = 'general-purpose'

    result.append({
        'template':    tmpl,
        'node_count':  len(node_templates_seen.get(tmpl, set())),
        'cpu_vcpu':    round(cpu_vcpu, 1),
        'mem_gi':      round(mem_gi, 1),
        'cpu_per_gi':  round(cpu_per_gi, 3),
        'ratio_str':   f"1:{round(1/cpu_per_gi, 1)}" if cpu_per_gi > 0 else "1:∞",
        'pattern':     pattern,
    })

# DaemonSet advisory: check if DS pods use >= 15% of total cluster CPU
# and cluster has >= 50 nodes
ds_pct = round((total_ds_cpu_m / total_cpu_m * 100), 1) if total_cpu_m > 0 else 0
ds_advisory = total_node_count >= 50 and ds_pct >= 15

result.sort(key=lambda x: -x['node_count'])
```

### 7d-ii: Classification rules

| cpu_per_gi (vCPU per GiB) | Equivalent ratio | Pattern | Instance families |
|---|---|---|---|
| <= 0.25 | 1:4 or higher | memory-heavy | AWS: `r6i/r7g`, GCP: `n2-highmem`, Azure: `Epsv5` |
| >= 0.50 | 1:2 or lower | compute-heavy | AWS: `c6i/c7g`, GCP: `n2-highcpu`, Azure: `Fsv2` |
| 0.25 < x < 0.50 | between 1:2 and 1:4 | general-purpose | AWS: `m6i/m7g`, GCP: `n2-standard`, Azure: `Dsv5` |

Default when memory requests are zero: compute-heavy.

### 7d-iii: Output

```
### Node Template Resource Profile

| Template | Nodes | CPU Requested | Memory Requested | Ratio (CPU:Mem) | Pattern | Recommendation |
|---|---|---|---|---|---|---|
| default    | 10 | 10.0 vCPU | 60.0 Gi | 1:6.0 | memory-heavy    | r6i/r7g (AWS) · n2-highmem (GCP) · Epsv5 (Azure) |
| batch      | 5  | 20.0 vCPU | 30.0 Gi | 1:1.5 | compute-heavy   | c6i/c7g (AWS) · n2-highcpu (GCP) · Fsv2 (Azure) |
| api-pool   | 8  | 16.0 vCPU | 48.0 Gi | 1:3.0 | general-purpose | m6i/m7g (AWS) · n2-standard (GCP) · Dsv5 (Azure) |
```

If DaemonSet advisory fires:

```
ADVISORY: DaemonSet pods are consuming <ds_pct>% of total cluster CPU across <N> nodes.
On the current instance sizes, DaemonSet overhead per node is disproportionately high.
Recommendation: Set minCPU=4 in node templates to enforce a minimum instance size
and reduce DaemonSet-to-workload CPU dilution.
```

---

## Step 7e: Rebalancing Analysis

This step surfaces recent rebalancing activity: executed / partial / failed / skipped plans, the last completed rebalance with savings, configured rebalancing schedules, and leftover old on-demand CAST-managed nodes. There is no dedicated MCP tool for rebalancing -- the endpoints are read via `castai-remote:make_api_call`.

### 7e-i: Fetch rebalancing data

Use `castai-remote:make_api_call` (method `GET`) for these four requests.
**Two hard-won quirks:** the plans endpoint is cluster-scoped
(`/v1/kubernetes/clusters/{cluster_id}/rebalancing-plans` -- the flat
`/v1/rebalancing-plans` 404s), and `filter.statuses` must be passed as **repeated
params** (a comma-joined string fails 400 `not a valid value`), and the org
must be supplied (`organization_id` / `X-CastAi-Organization-Id`) or the route
404s on enterprise tokens.

Skipped plans (generated but never executed):

```
path: /v1/kubernetes/clusters/{cluster_id}/rebalancing-plans?limit=20&filter.statuses=generated&includeNegative=true&includeOperations=false
```

Executed plans (finished / error / partially finished):

```
path: /v1/kubernetes/clusters/{cluster_id}/rebalancing-plans?limit=10&filter.statuses=finished&filter.statuses=error&filter.statuses=partially_finished&includeConfigurations=true&includeNegative=true&includeOperations=false
```

Last completed rebalance:

```
path: /v1/kubernetes/clusters/{cluster_id}/rebalancing-plans?limit=1&filter.statuses=finished&includeOperations=true&includeConfigurations=true&includeNegative=true
```

Schedules (org-level endpoint; keep only schedules with a `jobs[].clusterId` matching this cluster):

```
path: /v1/rebalancing-schedules
```

- Merge the skipped + executed plan lists, deduplicate by `rebalancingPlanId` (fallback `id`), sort newest first by the resolved timestamp (`finishedAt`, fallback `updatedAt`, then `createdAt`).
- Do not attempt pagination beyond the `limit` query params above; no page cursors are needed for this analysis.
- If a rebalancing request fails: single-cluster prints `Rebalancing data not available (<status>)` and skips to Step 8. Org-wide marks the cluster `Timeout / Error` in the summary and continues with the next cluster (never abort the batch).

### 7e-ii: Event classification and field mapping

| Plan status | Classification | Icon |
|---|---|---|
| `finished` and `errors[]` empty | Success | ✔ |
| `partially_finished` | Partial | ⚠ |
| `error` | Failed | ✖ |
| `generated`, `triggeredAt` empty | Skipped | ⏭ |
| `generated` and `triggeredAt` set | Pending execution -- excluded from the table entirely (not counted as skipped) | -- |

Field mapping per event:

- Timestamp: `finishedAt` (fallback `updatedAt`, then `createdAt`). Drop events with a null/empty timestamp.
- `error` plans whose ONLY `errors[].reason` is `achievedSavingsBelowThreshold` (or `savingsBelowThreshold`) are really **skips** -- surface them with the skipped-note wording, not as failures.
- `error_summary`: join `errors[*]` as `<reason>: <message>`, truncated to 150 chars.
- `schedule_name`: resolve `scheduleId` against the schedules response (`schedules[].id` -> `name`); empty when triggered manually.
- Nodes: `configurations.blue.totals.nodes` -> before, `configurations.green.totals.nodes` -> after.
- CPU: `configurations.blue.totals.milliCpu / 1000` -> before, `configurations.green.totals.milliCpu / 1000` -> after.
- Savings $/mo: `configurations.achievedDiff.priceMonthly` (fallback `configurations.diff.priceMonthly`), rounded to whole dollars; omitted for skipped plans.
- %: `configurations.achievedDiff.savingsPercentage` (fallback `clusterSavingsPercentage` at the same level).
- `skip_reason` for skipped events, verbatim: `Savings below threshold — plan generated but not executed`.

Last-rebalance summary (from the `limit=1` finished plan):

- Blue nodes = `configurations.blue.nodes[]` filtered to `rebalancingNodeIds` when those IDs are present, else all blue nodes. Green nodes = `configurations.green.nodes[]` excluding nodes with `isLegacy == true`.
- `nodes_before` / `nodes_after` = node counts per side; `cpu_before` / `cpu_after` = sum of `milliCpu / 1000` per side.
- `cost_before_hourly` / `cost_after_hourly` = sum of each side's node `priceHourly`; `cost_savings_monthly` = (before - after) x 730.
- `days_since` = full days between `finishedAt` (handle the trailing `Z`) and now; reduction % = (before - after) / before x 100.

### 7e-iii: Old on-demand node detection

Run using `castai-remote:analyze_snapshot_with_code`.

**Two hard-won runtime quirks:**

1. **The snapshot runtime does not un-escape `\.` dots in `safe_get` paths.** A lookup like
   `safe_get(node, 'metadata.labels.provisioner\.cast\.ai/managed-by', '')` silently returns the
   fallback (a live run returned cast=0 while the same cluster had 20 cast-managed nodes). Use the
   key-scan form below for the managed/spot/instance-type label lookups.
2. **The snapshot runtime rejects import statements** (`from datetime import ...` fails with
   "Imports are not allowed") and does not pre-define `datetime`/`timezone`. Do the age math
   client-side: the snippet returns raw `{name, instance_type, created}` rows, and the
   `age_days >= 30` filtering happens in the agent's next step OUTSIDE the snapshot call.

```python
nodes = snapshot.get_nodes()
old_ondemand = []
for node in nodes:
    labels = safe_get(node, 'metadata.labels', {})

    # CAST-managed iff provisioner/managed-by label or createdBy says cast — use key
    # scans, NOT escaped safe_get paths (the runtime does not un-escape `\.` dots,
    # so `provisioner\.cast\.ai/managed-by` silently returns the fallback).
    managed_vals = [str(v) for k, v in labels.items() if 'managed-by' in k.lower()]
    created_by   = [str(v) for k, v in labels.items() if k == 'createdBy']
    is_cast = any('cast' in v.lower() for v in managed_vals) or any(
        v.lower() in ('cast.ai', 'castai') for v in created_by)
    if not is_cast:
        continue

    # Exclude spot: any lifecycle/capacity/spot-ish label value containing 'spot'
    spot_vals = [str(v).lower() for k, v in labels.items()
                 if ('lifecycle' in k.lower() or 'capacity-type' in k.lower()
                     or k.lower().endswith('/spot') or k.lower() == 'cloud.google.com/gke-spot')]
    if any('spot' in v and v not in ('false', 'no', '0') for v in spot_vals):
        continue

    # Return the raw creationTimestamp; drop null/empty timestamps here.
    # Malformed-timestamp handling happens in the age-math step below.
    created = safe_get(node, 'metadata.creationTimestamp', '')
    if not created:
        continue

    # instance type: any label key ending in '/instance-type'
    it = next((str(v) for k, v in labels.items() if k.endswith('instance-type')), '')

    old_ondemand.append({
        'name': safe_get(node, 'metadata.name', ''),
        'instance_type': it,
        'created': created,
    })
```

Then, OUTSIDE the snapshot call (in the agent's next step), compute age and filter. Parse each
`created` with `datetime.fromisoformat(created.replace('Z', '+00:00'))`, wrapped in
`try/except (ValueError, TypeError): continue` (drop null/empty/malformed timestamps), compute
`age_days = (datetime.now(timezone.utc) - created_dt).days`, keep rows with `age_days >= 30`, and
sort oldest-first (`-age_days`).

### 7e-iv: Output

```
### Rebalancing Analysis

| Date | Status | Schedule | Nodes | CPU | Savings $/mo | % |
|---|---|---|---|---|---|---|
| 2024-05-12 | ✔ Success | nightly | 14 → 9 | 120 → 85 vCPU | $620 | 29% |
| 2024-05-05 | ⚠ Partial | nightly | 14 → 11 | 120 → 98 vCPU | $240 | 18% |
| 2024-05-01 | ✖ Failed | weekly | -- | -- | -- | -- |
| 2024-04-28 | ⏭ Skipped | -- | -- | -- | -- | Savings below threshold |
```

Last rebalance summary:

```
Last rebalance: 2024-05-12 02:14 UTC (12 days ago)
Nodes: 14 → 9 (-36%)  |  CPU: 120 → 85 vCPU (-29%)
Cost: $2.40 → $1.70/hr  |  Savings: ~$511/mo (29%)
```

Schedules:

```
Schedules: nightly, weekly
```

or, when the schedules call returns nothing matching this cluster:

```
Schedules: None configured
```

Old on-demand nodes (>= 30 days, oldest first):

| Node | Instance Type | Age days |
|---|---|---|
| `cast-pool-xyz` | m5.xlarge | 45 |

Empty states (use exactly one line each). These exact strings apply to the **console output** only; PDF Section 6 uses its own copy (e.g. `No rebalancing has run.`, `No recent rebalancing plans.`) and renders skip_reason under the Status cell — do not expect console/PDF wording to match:

- No events: `No rebalancing events found.`
- No completed rebalance: `No completed rebalance found.`
- No schedules: `Schedules: None configured`
- No old on-demand nodes: `No old on-demand CAST-managed nodes (>= 30 days) found.`

Report `old_ondemand_count` = number of rows in the old on-demand table; it feeds the Org-Wide Summary aggregate and the Step 9a severity rule (>= 3 -> HIGH).

### 7e-v: Callouts (only if applicable)

- **No schedule configured**: recommend creating a rebalancing schedule in the CAST AI console.
- **days_since > 30**: a schedule may exist but is broken or disabled -- verify schedule health and trigger conditions.
- **Skipped plans present**: savings repeatedly fell below the threshold -- suggest tuning the schedule's savings-percentage trigger condition.
- **Old on-demand nodes present**: cross-reference the Step 3 blocker table (same node names) and flag leftover on-demand capacity the last rebalance did not remove.
- **Failed plans**: surface `error_summary` verbatim under the events table.

Step 7e notes:

- **Pagination trap**: the rebalancing-plans endpoint ignores ascending-sort params and always returns finished plans newest-first ("The Cast.ai rebalancing-plans endpoint ignores ascending-sort params and always returns finished plans newest-first"), so when paginating with `page.cursor` you must filter statuses **client-side**; the API is always newest-first.
- Cloud Connect clusters have no rebalancing data.
- The audit-events window is 14 days, capped at 30 rows.

---

## Step 7f: Rebalancing Health Findings

This step is the assessment half of the rebalancing analysis (Step 7e is the events/savings half). It ports the dashboard's `/api/rebalancing-health` finding engine: schedule configuration issues, label-selector mismatches, skip patterns, and reverse node coverage. Findings are sorted critical > warning > info and feed the `rebalancing_health` key in the Step 9a JSON.

### 7f-i: Data sources (reuse the Step 7e plumbing)

1. **Schedules** -- `/v1/rebalancing-schedules`, already fetched in Step 7e. Keep the **full schedule objects** for this cluster (jobs filtered by `jobs[].clusterId`), not just the names: the selector, trigger-conditions, and `lastTriggerAt` checks below need them.
2. **Node labels** -- run `castai_prod_master_analyze_snapshot_with_code` returning per-node labels for all nodes: `[{name: metadata.name, labels: metadata.labels}]`. Embed the schedule selector terms (from source 1) into the follow-up analysis code, or evaluate them client-side from the returned labels.
3. **Audit events** -- `GET /v1/audit-events` via `castai-remote:make_api_call`:
   - params: `page.limit=100`, `clusterId=<id>`, `fromDate`, `toDate` (14-day window)
   - header: `x-castai-cluster-id: <id>` (plus the org header when needed)
   - keep events whose `eventType`, `action`, or `message` contains `rebalanc` (case-insensitive); record `time` (`createdAt`), `event_type`, `action`, `message` (truncated to 300 chars), `initiator` (`initiator.email` -> `initiator.name` -> `system`); cap at the 30 most recent.

### 7f-ii: Skip-streak source (deviation from the dashboard)

The dashboard computes `skipped_count / total_jobs` from `schedules[].jobs[]`. **Do not do that here**: the API returns only one job per cluster per schedule, so a dashboard-style `skipped_count/total_jobs` from `jobs` can never exceed 1. Instead compute `skipped_count` and the skip streak over the Step 7e merged skipped+executed plan list, grouped by `scheduleId`:

- `skipped_count` = number of skipped events for that schedule (including `error` plans whose only `errors[].reason` is `achievedSavingsBelowThreshold`/`savingsBelowThreshold`, which Step 7e already classifies as skips).
- `skip_streak` = consecutive skipped events since the last non-skipped event, newest first.
- Streak wording (mirrors the dashboard): `last <N> consecutive skipped, <skipped>/<total> total · last: today|yesterday|<d>d ago (<YYYY-MM-DD>)`.

### 7f-iii: Finding taxonomy

Exactly these types (severity critical > warning > info):

| Type | Severity | Trigger |
|---|---|---|
| `NO_SCHEDULE` | warning | No schedule has a job for this cluster. Detail: without a schedule nodes are not periodically consolidated and old on-demand nodes accumulate. |
| `SELECTOR_NO_MATCHING_NODES` | critical | A nodeSelectorTerm matches 0 nodes. |
| `SELECTOR_PARTIAL_MATCH` | info | A term matches n < N nodes; report n/N and the excluded-node count in the detail. |
| `NO_SELECTOR` | info | Schedule has no nodeSelectorTerms (targets all N nodes). |
| `JOB_SKIPPED_SAVINGS_THRESHOLD` | warning | The schedule's most recent plan for this cluster is a skip AND `triggerConditions.ignoreSavings` is false AND `savingsPercentage > 0`. Title includes the threshold % and the skip streak from 7f-ii plus the humanized last-plan date. |
| `JOB_SKIPPED` | warning | Same, but the skip is not attributable to a savings threshold. |
| `STALE_SCHEDULE` | warning | Schedule `lastTriggerAt` older than 7 days. |
| `HIGH_SAVINGS_THRESHOLD` | warning | `triggerConditions.savingsPercentage >= 10` AND `!ignoreSavings` AND `launchConfiguration.rebalancingOptions.executionConditions.enabled == false`. |
| `NODES_NOT_COVERED_BY_ANY_SCHEDULE` | warning | No catch-all schedule exists and cast-managed nodes match no selector. Sample up to 5 uncovered node names in the detail. **Downgrade to INFO** with the spot-only wording ("...Cast-managed on-demand node(s) not targeted by any schedule (spot-only schedule)") if EVERY schedule with selectors has a spot filter in every term. |
| `UNMANAGED_NODES_NOT_COVERED` | info | Same coverage gap for non-cast-managed nodes (expected, informational). |
| `API_ERROR` | warning | The schedules fetch failed; still render the remaining findings. |

- Cast-managed = label `provisioner.cast.ai/managed-by == "cast.ai"`. A node is covered if a schedule without `nodeSelectorTerms` exists (catch-all), or it matches any term of any schedule with selectors.
- Spot-key heuristic set (for the spot-only downgrade): `scheduling.cast.ai/spot`, `cloud.google.com/gke-spot`, `kubernetes.azure.com/scalesetpriority`, `eks.amazonaws.com/capacityType`.

### 7f-iv: Selector evaluator semantics (replicate exactly)

- `nodeSelectorTerms` are **OR'd**; `matchExpressions` within a term are **AND'd**; supported operators: `Exists`, `DoesNotExist`, `In`, `NotIn`.
- Evaluate each term as a unit so counts reflect the real combined match; a term with empty `matchExpressions` is skipped.
- Term label: humanize each expression -- `key: Exists`, `key: DoesNotExist`, `key in [v1, v2]`, `key notin [v1, v2]` -- and join with ` AND `; multi-term schedules qualify titles with ` (term i/n)`.

### 7f-v: Output

Populates `data["rebalancing_health"]` in the Step 9a JSON:

```python
"rebalancing_health": {
    "audit_window_days": 14,
    "findings": [
        # {"type": "JOB_SKIPPED_SAVINGS_THRESHOLD", "severity": "warning",  # critical|warning|info
        #  "title": "'iac-dev-bi-hourly-spot': last run skipped — savings threshold 25% not met (last 6 consecutive skipped, 6/20 total) · last: today",
        #  "detail": "…", "schedule_name": "iac-dev-bi-hourly-spot"}
    ],
    "audit_events": [           # keep for finding wordings only — NOT rendered in the PDF;
        # audit rows on a skipping-but-healthy cluster just repeat the events table
        # {"time": "2026-10-13T23:00:40Z", "event_type": "...", "action": "...",
        #  "message": "<=300 chars", "initiator": "user@cast.ai|system"}
    ]
},
```

PDF Section 6 renders a "Rebalancing Health Findings" subsection (severity badges: critical red, warning amber, info blue) only when findings exist; an absent subsection means healthy / no data. Audit events do NOT appear in the PDF — use them inline in finding details when they explain a skip/no-trigger, never as a table.

Exec-summary severity mapping: any finding with severity `critical` -> exec CRITICAL; any finding with severity `warning` -> exec HIGH; findings with severity `info` do NOT enter the exec summary.

---

## Org-Wide Summary (org ID flow only)

After all batches complete, output a consolidated summary:

```
## Org-Wide Summary
Org: <org_id>
Total connected clusters analysed: <N>  |  Errors/Timeouts: <N>

| Cluster | Eviction Blockers | Unhealthy Pods | Cross-matches | Nodes at Pod Capacity | Template Merge Candidates | Status |
|---|---|---|---|---|---|---|
| einstein-prod | 8 nodes blocked | 52 evicted | 2 | 2 at 100% | 1 pair | ACTION NEEDED |
| sb-cluster-prod | None | 0 | 0 | 0 | None | CLEAN |
| mcafee-int-tools | None | 1 Pending | 0 | 0 | 2 pairs | MINOR |
| dh-prod | -- | -- | -- | -- | -- | TIMEOUT |

Rebalancing: <N> clusters with active rebalancing  |  Total savings: $<X>/mo  |  Old on-demand nodes: <N>  |  health findings: <C> critical / <W> warning
Events roll-up: <N> success / <N> partial / <N> failed / <N> skipped

Top issues across org:
1. <cluster>: <worst finding>
2. <cluster>: <finding>
```

Sort order: cross-matches first -> blockers only -> nodes at capacity -> unhealthy pods only -> clean -> timeouts last.

Rebalancing aggregates come from Step 7e: a cluster counts as having active rebalancing if `last_rebalance.has_rebalancing` is true; total savings sums only positive last-rebalance `cost_savings_monthly` values.

---

## Step 8: WOOP Rollout Strategy Audit

This step checks whether WOOP-managed workloads are using the one-by-one rollout strategy and, for single-replica workloads, whether zero-downtime updates are enforced.

### 8a: Fetch WOOP workloads

Use `castai-remote:woop_get_workloads`:

```
cluster_id: <cluster_id>
```

If the cluster has no WOOP workloads, output:
`WOOP not active on this cluster or no managed workloads found.` and skip to Step 9.

### 8b: Per-workload policy check

For each workload inspect the scaling policy fields.

**One-by-one rollout:**
- Look for `scalingPolicy.rolloutStrategy` or `scalingPolicy.applyType` at the outer policy level or inside `scalingPolicy.recommendationPolicies[*]`.
- Value `ONE_BY_ONE` or equivalent = correct.
- Value `BATCH`, `ALL_AT_ONCE`, or field missing = flag as `rollout not one-by-one`.

**Zero-downtime (single-replica workloads ONLY):**
- Only apply this check if `minReplicas == 1` or `currentReplicas == 1`.
- Correct if `scalingPolicy.maxUnavailablePodsPercentage == 0` OR `scalingPolicy.minAvailablePercentage >= 100`.
- If neither is set and workload has 1 replica: flag as `zero-downtime not enforced`.
- Multi-replica workloads: skip this check entirely, mark as `N/A`.

### 8c: Classification per workload

| Condition | Status |
|---|---|
| One-by-one correct AND (multi-replica OR zero-downtime enforced) | `OK` |
| Rollout strategy not one-by-one | `WARN: rollout not one-by-one` |
| Single replica AND zero-downtime not enforced | `WARN: zero-downtime not enforced` |
| Both issues on same workload | `ACTION NEEDED` |

### 8d: Output

```
### WOOP Rollout Strategy Audit

Total WOOP workloads checked: <N>
OK: <N>  |  Warnings: <N>  |  Action Needed: <N>

| Workload | Namespace | Replicas | Rollout Strategy | Zero-Downtime | Status |
|---|---|---|---|---|---|
| api-server  | prod   | 1 | BATCH       | Not enforced | ACTION NEEDED |
| worker      | prod   | 3 | ONE_BY_ONE  | N/A (multi)  | OK            |
| scheduler   | infra  | 1 | ONE_BY_ONE  | Not enforced | WARN          |
```

Only show workloads with warnings or action needed in the table. If all clean:
`All WOOP workloads are using one-by-one rollout. No zero-downtime issues found.`

---

## Step 9: PDF Report Generation

After all analysis steps complete, generate a branded PDF report using Python + ReportLab.

### 9a: Write analysis data to JSON

Collect all outputs from Steps 1-8 into a structured dict and write to `/home/claude/cast_optimise_data.json`:

```python
import json
from datetime import datetime, timezone

data = {
    "cluster_name": "<cluster_name>",
    "cluster_id":   "<cluster_id>",
    "generated_at": datetime.now(timezone.utc).strftime("%d %B %Y %H:%M UTC"),

    "evictor": {
        "window_start": "<start>",
        "window_end":   "<end>",
        "reconcile_cycles": 0,
        "blocked_nodes": [
            # {"node": "cast-pool-xxx", "category": "StatefulSet", "blocking_pod": "pod-name", "namespace": "ns"}
        ],
        "top_blockers": [],   # [{"category": "StatefulSet", "count": 3}]
        "evictions_completed": 0,
        "cross_matches": []   # [{"pod": "x", "namespace": "ns", "node": "n", "reason": "CrashLoopBackOff"}]
    },

    "pod_health": {
        "unhealthy": [
            # {"name": "pod", "namespace": "ns", "phase": "Running", "container": "c", "state": "waiting", "reason": "CrashLoopBackOff", "restarts": 4}
        ]
    },

    "max_pod_per_node": {
        "provider": "EKS",   # EKS / GKE / AKS
        "config_summary": [
            # {"node_config": "default", "instance_type": "m5.xlarge", "max_pods": 58, "node_count": 12}
        ],
        "at_capacity": [
            # {"node": "cast-pool-abc", "instance_type": "m5.xlarge", "config": "default", "allocatable": 58, "running": 58, "pct": 100.0}
        ]
    },

    "node_templates": {
        "inventory": [
            # {"template": "default", "count": 12, "arch": ["amd64"], "capacity_type": ["on-demand"], "os": ["linux"], "instance_types": ["m5.xlarge"], "taints": [], "gpu": false}
        ],
        "merge_candidates": [
            # {"templates": ["arm-batch", "arm-prod"], "reason": "Both arm64, on-demand, linux, no taints"}
        ],
        "keep_separate": [
            # {"template": "gpu-nodes", "reason": "GPU taint present"}
        ],
        "misconfigured": [
            # {"template": "mixed-pool", "issue": "Mixed arch: amd64, arm64"}
        ],
        "spot_templates": [
            # list of template names that have capacity_type == "spot"
            # e.g. ["spot-workers", "arm-spot"]
        ]
    },

    "nt_resource_profile": {
        "templates": [
            # {"template": "default", "node_count": 10, "cpu_vcpu": 10.0, "mem_gi": 60.0,
            #  "ratio_str": "1:6.0", "pattern": "memory-heavy",
            #  "recommendation": "r6i/r7g (AWS) · n2-highmem (GCP) · Epsv5 (Azure)"}
        ],
        "ds_advisory": False,       # True if DaemonSet CPU >= 15% and cluster >= 50 nodes
        "ds_cpu_pct": 0.0,
        "total_nodes": 0
    },

    "rebalancing": {
        "events": [
            # {"plan_id": "abc", "timestamp_iso": "2024-05-12T02:14:00+00:00", "date": "2024-05-12",
            #  "status": "finished|partially_finished|error|generated", "is_success": True,
            #  "is_partial": False, "is_skipped": False, "schedule_name": "nightly",
            #  "error_summary": "", "skip_reason": "",
            #  "nodes_before": 14, "nodes_after": 9, "cpu_before": 120.0, "cpu_after": 85.0,
            #  "cost_savings_monthly": 620.0, "cost_savings_pct": 29.0}
        ],
        "last_rebalance": {
            "has_rebalancing": False,        # True once a `finished` plan exists
            "last_rebalance_date": "",
            "days_since": None,              # int; feeds MEDIUM severity when > 30
            "nodes_before": None, "nodes_after": None,
            "nodes_reduction_pct": None,
            "cpu_before": None, "cpu_after": None,
            "cpu_reduction_pct": None,
            "cost_before_hourly": None, "cost_after_hourly": None,
            "cost_savings_monthly": None,    # (before_hourly - after_hourly) x 730
            "cost_savings_pct": None
        },
        "schedules": [],                     # [{"id": "...", "name": "nightly"}] matching this cluster
        "old_ondemand_nodes": [
            # {"name": "cast-pool-xyz", "instance_type": "m5.xlarge", "age_days": 45}
        ],
        "old_ondemand_count": 0
    },

    "rebalancing_health": {
        "audit_window_days": 14,
        "findings": [
            # {"type": "JOB_SKIPPED_SAVINGS_THRESHOLD", "severity": "warning",  # critical|warning|info
            #  "title": "'iac-dev-bi-hourly-spot': last run skipped — savings threshold 25% not met (last 6 consecutive skipped, 6/20 total) · last: today",
            #  "detail": "…", "schedule_name": "iac-dev-bi-hourly-spot"}
        ],
        "audit_events": [
            # {"time": "2026-10-13T23:00:40Z", "event_type": "...", "action": "...",
            #  "message": "<=300 chars", "initiator": "user@cast.ai|system"}
        ]
    },

    "woop_rollout": {
        "active": True,             # False if no WOOP workloads found
        "total_checked": 0,
        "ok": 0,
        "warnings": 0,
        "action_needed": 0,
        "issues": [
            # {"workload": "api-server", "namespace": "prod", "replicas": 1,
            #  "rollout_strategy": "BATCH", "zero_downtime": False, "status": "ACTION NEEDED"}
        ]
    },

    # Exec summary: populated AFTER all analysis steps complete.
    # Build this from the findings before writing the JSON file.
    "exec_summary": {
        "critical": [
            # {"area": "Evictor", "finding": "3 cross-matched pods blocking consolidation entirely", "action": "Resolve CrashLoopBackOff on pod X in namespace Y"}
        ],
        "high": [
            # {"area": "Pod Health", "finding": "7 pods in CrashLoopBackOff", "action": "Investigate container logs for root cause"}
        ],
        "medium": [
            # {"area": "Node Templates", "finding": "2 spot templates missing spot prediction model", "action": "Enable Cast AI Spot Prediction on templates: spot-workers, arm-spot"}
        ]
    }
}

# Build exec_summary from findings BEFORE writing the file.
# Rules:
#   CRITICAL: cross-matched pods (evictor + bad pod state), nodes at 100% pod capacity,
#             any rebalancing_health finding with severity "critical"
#   HIGH:     evictor blockers (> 3 nodes), CrashLoopBackOff/OOMKilled pods, WOOP ACTION NEEDED items,
#             rebalancing error plan, old_ondemand_count >= 3,
#             any rebalancing_health finding with severity "warning" ("info" findings never enter the exec summary)
#   MEDIUM:   spot templates without spot prediction model, WOOP warnings, merge candidates,
#             misconfigured node templates, nodes near (95-99%) pod capacity, NT profile non-standard patterns,
#             days_since > 30 (only when last_rebalance.has_rebalancing is true; this rule is ours -- the
#             dashboard has no equivalent -- and supersedes the old "skipped plan / no schedule" MEDIUM
#             bullets, which are now NO_SCHEDULE / JOB_SKIPPED / STALE_SCHEDULE warnings)
#
# Each item: {"area": "<section name>", "finding": "<concise description>", "action": "<imperative action>"}
# Spot prediction model check: for every template in data["node_templates"]["spot_templates"],
#   add a MEDIUM item: area="Node Templates", finding="<template> uses spot instances — spot prediction model not confirmed enabled",
#   action="Enable Cast AI Spot Prediction on node template <template> via Cast AI console."
#
# Deduplicate: one item per distinct issue, not one per pod/node.
# Cap at 5 items per priority level. If more, add a summary item: "<N> additional issues — see detailed sections."

with open("/home/claude/cast_optimise_data.json", "w") as f:
    json.dump(data, f, indent=2)
```

### 9b: Generate PDF

Write and execute `/home/claude/generate_cast_optimise_report.py`:

```python
#!/usr/bin/env python3
import json, sys, os
from html import escape
from datetime import date
from reportlab.lib.pagesizes import letter
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import (
    BaseDocTemplate, Frame, PageTemplate, PageBreak,
    Paragraph, Spacer, Table, TableStyle, HRFlowable, KeepTogether,
)
from reportlab.lib.enums import TA_LEFT, TA_CENTER

# ── Brand palette (matches CAST AI cluster-readiness reports) ──────────────────
CAST_BLUE   = colors.HexColor("#0669FD")
CAST_BLACK  = colors.HexColor("#0E0F13")
CAST_WHITE  = colors.white
RED_FAIL    = colors.HexColor("#EF4444")
RED_LIGHT   = colors.HexColor("#FEE2E2")
AMBER_WARN  = colors.HexColor("#F59E0B")
AMBER_LIGHT = colors.HexColor("#FEF3C7")
AMBER_DARK  = colors.HexColor("#92400E")
GREEN_PASS  = colors.HexColor("#22C55E")
GREEN_LIGHT = colors.HexColor("#DCFCE7")
BLUE_INFO   = colors.HexColor("#3B82F6")
BLUE_LIGHT  = colors.HexColor("#DBEAFE")
GRAY_LIGHT  = colors.HexColor("#F4F6FA")
GRAY_MID    = colors.HexColor("#D1D5DB")
GRAY_DARK   = colors.HexColor("#6B7280")
DARK_ROW    = colors.HexColor("#1E2228")
PURPLE      = colors.HexColor("#8B5CF6")
PURPLE_LIGHT= colors.HexColor("#EDE9FE")
ORANGE_WARN = colors.HexColor("#F97316")
ORANGE_LIGHT= colors.HexColor("#FFEDD5")

ICON_CANDIDATES = [
    "/mnt/skills/private/cluster-readiness/assets/castai_icon.png",
    "/mnt/skills/user/cluster-readiness/assets/castai_icon.png",
]
ICON_PATH = next((p for p in ICON_CANDIDATES if os.path.exists(p)), "")

def S(name, **kw):
    base = dict(fontName="Helvetica", fontSize=9, textColor=CAST_BLACK, leading=13)
    base.update(kw)
    return ParagraphStyle(name, **base)

def grid(extra=None):
    ts = extra or []
    return ts + [
        ("GRID",         (0,0),(-1,-1), 0.3, GRAY_MID),
        ("LEFTPADDING",  (0,0),(-1,-1), 7),
        ("RIGHTPADDING", (0,0),(-1,-1), 7),
        ("TOPPADDING",   (0,0),(-1,-1), 5),
        ("BOTTOMPADDING",(0,0),(-1,-1), 5),
        ("FONTSIZE",     (0,0),(-1,-1), 8),
        ("VALIGN",       (0,0),(-1,-1), "TOP"),
    ]

def section_header(title, W):
    hdr = S(f"sh_{id(title)}", fontName="Helvetica-Bold", fontSize=10, textColor=CAST_WHITE)
    t = Table([[Paragraph(f"  {title}", hdr)]], colWidths=[W])
    t.setStyle(TableStyle([
        ("BACKGROUND",    (0,0),(0,0), CAST_BLUE),
        ("TOPPADDING",    (0,0),(0,0), 8),
        ("BOTTOMPADDING", (0,0),(0,0), 8),
    ]))
    return t

def callout(text, W, bg=AMBER_LIGHT, border=AMBER_WARN, tc=AMBER_DARK):
    p = S(f"co_{id(text)}", fontSize=8.5, textColor=tc, leading=13)
    t = Table([[Paragraph(text, p)]], colWidths=[W])
    t.setStyle(TableStyle([
        ("BACKGROUND",    (0,0),(0,0), bg),
        ("BOX",           (0,0),(0,0), 1, border),
        ("TOPPADDING",    (0,0),(0,0), 7),
        ("BOTTOMPADDING", (0,0),(0,0), 7),
        ("LEFTPADDING",   (0,0),(0,0), 10),
        ("RIGHTPADDING",  (0,0),(0,0), 10),
    ]))
    return t

def make_decorator(cluster_name, cluster_id, generated_at):
    def decorate(canvas_obj, doc):
        W, H = letter
        canvas_obj.setFillColor(CAST_BLACK)
        canvas_obj.rect(0, H-50, W, 50, fill=1, stroke=0)
        if ICON_PATH:
            canvas_obj.drawImage(ICON_PATH, 28, H-46, width=34, height=34,
                                 mask="auto", preserveAspectRatio=True)
            canvas_obj.setFillColor(CAST_WHITE)
            canvas_obj.setFont("Helvetica-Bold", 16)
            canvas_obj.drawString(68, H-33, "CAST AI")
        else:
            canvas_obj.setFillColor(CAST_BLUE)
            canvas_obj.circle(44, H-25, 12, fill=1, stroke=0)
            canvas_obj.setFillColor(CAST_WHITE)
            canvas_obj.setFont("Helvetica-Bold", 16)
            canvas_obj.drawString(62, H-33, "CAST AI")
        canvas_obj.setFont("Helvetica-Bold", 7)
        canvas_obj.setFillColor(CAST_WHITE)
        canvas_obj.drawRightString(W-28, H-16, "CAST AI TAM · CLUSTER OPTIMISATION")
        canvas_obj.setFont("Helvetica", 7)
        canvas_obj.setFillColor(CAST_BLUE)
        canvas_obj.drawRightString(W-28, H-28, "CONFIDENTIAL")
        canvas_obj.setFillColor(CAST_BLUE)
        canvas_obj.rect(0, H-54, W, 4, fill=1, stroke=0)
        # Footer
        canvas_obj.setFillColor(CAST_BLACK)
        canvas_obj.rect(0, 0, W, 22, fill=1, stroke=0)
        if ICON_PATH:
            canvas_obj.drawImage(ICON_PATH, 28, 3, width=16, height=16,
                                 mask="auto", preserveAspectRatio=True)
            canvas_obj.setFillColor(CAST_WHITE)
            canvas_obj.setFont("Helvetica-Bold", 8)
            canvas_obj.drawString(48, 7, "CAST AI")
        else:
            canvas_obj.setFillColor(CAST_BLUE)
            canvas_obj.circle(36, 11, 6, fill=1, stroke=0)
            canvas_obj.setFillColor(CAST_WHITE)
            canvas_obj.setFont("Helvetica-Bold", 8)
            canvas_obj.drawString(46, 7, "CAST AI")
        canvas_obj.setFillColor(GRAY_DARK)
        canvas_obj.setFont("Helvetica", 6.5)
        foot = f"CAST AI Customer Success · Confidential · {generated_at} · {cluster_name} · {cluster_id}"
        canvas_obj.drawString(92, 7, foot)
    return decorate

# ── Cover page ─────────────────────────────────────────────────────────────────
def cover(story, data, W):
    story.append(Spacer(1, 0.6*inch))
    t = Table([[Paragraph("Cluster Optimisation Report",
                           S("cov_t", fontName="Helvetica-Bold", fontSize=22,
                             textColor=CAST_BLUE, leading=28))]], colWidths=[W])
    story.append(t)
    story.append(Spacer(1, 0.15*inch))

    meta = [
        ["Cluster",    data.get("cluster_name","—")],
        ["Cluster ID", data.get("cluster_id","—")],
        ["Generated",  data.get("generated_at","—")],
    ]
    mt = Table(meta, colWidths=[1.4*inch, W-1.4*inch])
    mt.setStyle(TableStyle([
        ("FONTNAME",  (0,0),(-1,-1), "Helvetica"),
        ("FONTNAME",  (0,0),(0,-1),  "Helvetica-Bold"),
        ("FONTSIZE",  (0,0),(-1,-1), 9),
        ("TEXTCOLOR", (0,0),(0,-1),  GRAY_DARK),
        ("TOPPADDING",(0,0),(-1,-1), 4),
        ("BOTTOMPADDING",(0,0),(-1,-1), 4),
        ("LINEBELOW", (0,0),(-1,-2), 0.3, GRAY_MID),
    ]))
    story.append(mt)
    story.append(Spacer(1, 0.3*inch))

    # Summary scorecard
    ev   = data["evictor"]
    ph   = data["pod_health"]
    mpn  = data["max_pod_per_node"]
    nt   = data["node_templates"]
    ntrp = data.get("nt_resource_profile", {})
    wr   = data.get("woop_rollout", {})

    blocked   = len(ev["blocked_nodes"])
    xmatch    = len(ev["cross_matches"])
    unhealthy = len(ph["unhealthy"])
    at_cap    = len(mpn["at_capacity"])
    merge_c   = len(nt["merge_candidates"])
    misconfig = len(nt["misconfigured"])
    nt_issues = sum(1 for t in ntrp.get("templates", []) if t.get("pattern") != "general-purpose")
    woop_issues = wr.get("warnings", 0) + wr.get("action_needed", 0)

    def badge(val, label, warn_threshold=1, crit_threshold=None):
        if crit_threshold is not None and val >= crit_threshold:
            bg, tc = RED_LIGHT, RED_FAIL
        elif val >= warn_threshold:
            bg, tc = AMBER_LIGHT, AMBER_DARK
        else:
            bg, tc = GREEN_LIGHT, GREEN_PASS
        cell = Table([[
            Paragraph(str(val), S(f"b_{label}", fontName="Helvetica-Bold", fontSize=18, textColor=tc, leading=22, alignment=TA_CENTER)),
            Paragraph(label, S(f"bl_{label}", fontSize=8, textColor=tc, leading=11)),
        ]], colWidths=[0.55*inch, 1.2*inch])
        cell.setStyle(TableStyle([
            ("BACKGROUND", (0,0),(-1,-1), bg),
            ("BOX",        (0,0),(-1,-1), 1, tc),
            ("TOPPADDING", (0,0),(-1,-1), 8),
            ("BOTTOMPADDING",(0,0),(-1,-1), 8),
            ("LEFTPADDING",(0,0),(-1,-1), 8),
            ("VALIGN",     (0,0),(-1,-1), "MIDDLE"),
        ]))
        return cell

    cw = W / 7
    badges = Table([[
        badge(blocked,    "Nodes Blocked",       1, 5),
        badge(xmatch,     "Cross-matches",        1, 3),
        badge(unhealthy,  "Unhealthy Pods",       1, 10),
        badge(at_cap,     "Nodes at Pod Cap",     1, 5),
        badge(merge_c,    "Merge Candidates",     1, 99),  # warn only, never red
        badge(nt_issues,  "NT Profile Issues",    1, 99),  # warn only, never red
        badge(woop_issues,"WOOP Rollout Issues",  1, 3),
    ]], colWidths=[cw]*7)
    badges.setStyle(TableStyle([("LEFTPADDING",(0,0),(-1,-1),3),("RIGHTPADDING",(0,0),(-1,-1),3)]))
    story.append(badges)
    story.append(PageBreak())

# ── Exec Summary page ────────────────────────────────────────────────────────
def section_exec_summary(story, data, W):
    es = data.get("exec_summary", {})
    critical = es.get("critical", [])
    high     = es.get("high", [])
    medium   = es.get("medium", [])

    if not critical and not high and not medium:
        return  # nothing to show

    story.append(section_header("Executive Summary — Priority Actions", W))
    story.append(Spacer(1, 8))

    intro_s = S("es_intro", fontSize=8.5, textColor=GRAY_DARK, leading=13)
    story.append(Paragraph(
        "The following actions are ranked by impact. Address critical items before enabling "
        "further Cast AI automation features.",
        intro_s))
    story.append(Spacer(1, 10))

    PRIORITY_CONFIG = [
        ("CRITICAL", critical, RED_FAIL,   RED_LIGHT),
        ("HIGH",     high,     AMBER_WARN, AMBER_LIGHT),
        ("MEDIUM",   medium,   BLUE_INFO,  BLUE_LIGHT),
    ]

    for priority_label, items, border_color, bg_color in PRIORITY_CONFIG:
        if not items:
            continue

        # Priority label header
        lbl_s = S(f"es_lbl_{priority_label}", fontName="Helvetica-Bold",
                  fontSize=8, textColor=border_color)
        story.append(Paragraph(priority_label, lbl_s))
        story.append(Spacer(1, 4))

        hdr_s = S(f"es_hdr_{priority_label}", fontName="Helvetica-Bold",
                  fontSize=8, textColor=CAST_WHITE)
        row_s = S(f"es_row_{priority_label}", fontSize=8, textColor=CAST_BLACK)
        act_s = S(f"es_act_{priority_label}", fontSize=8, textColor=border_color,
                  fontName="Helvetica-Bold")

        rows = [[
            Paragraph("Area", hdr_s),
            Paragraph("Finding", hdr_s),
            Paragraph("Recommended Action", hdr_s),
        ]]
        for item in items:
            rows.append([
                Paragraph(item.get("area", ""), row_s),
                Paragraph(item.get("finding", ""), row_s),
                Paragraph(item.get("action", ""), act_s),
            ])

        t = Table(rows, colWidths=[W*0.15, W*0.42, W*0.43])
        t.setStyle(TableStyle(grid([
            ("BACKGROUND", (0,0),(-1,0), CAST_BLUE),
            ("ROWBACKGROUNDS", (0,1),(-1,-1), [bg_color, CAST_WHITE]),
        ])))
        story.append(t)
        story.append(Spacer(1, 10))

    story.append(PageBreak())

# ── Section 1: Evictor ────────────────────────────────────────────────────────
def section_evictor(story, data, W):
    ev = data["evictor"]
    story.append(section_header("1. Evictor Analysis", W))
    story.append(Spacer(1, 6))

    meta_p = S("em", fontSize=8.5, textColor=GRAY_DARK)
    story.append(Paragraph(
        f"Window: {ev.get('window_start','—')} → {ev.get('window_end','—')}  |  "
        f"Reconcile cycles: {ev.get('reconcile_cycles',0)}  |  "
        f"Evictions completed: {ev.get('evictions_completed',0)}",
        meta_p))
    story.append(Spacer(1, 6))

    xm = ev.get("cross_matches", [])
    if xm:
        for x in xm:
            story.append(callout(
                f"CROSS-MATCH  {x['pod']} in {x['namespace']} is blocking node "
                f"{x['node']} AND is in a bad state ({x['reason']}). "
                f"This pod cannot be rescheduled — explains the persistent eviction block.",
                W, bg=RED_LIGHT, border=RED_FAIL, tc=RED_FAIL))
            story.append(Spacer(1, 4))

    blocked = ev.get("blocked_nodes", [])
    if blocked:
        hdr_s = S("eh", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("er", fontSize=8, textColor=CAST_BLACK)
        rows = [[
            Paragraph("Node", hdr_s),
            Paragraph("Category", hdr_s),
            Paragraph("Blocking Pod", hdr_s),
            Paragraph("Namespace", hdr_s),
        ]]
        for b in blocked:
            rows.append([
                Paragraph(b.get("node",""), row_s),
                Paragraph(b.get("category",""), row_s),
                Paragraph(b.get("blocking_pod",""), row_s),
                Paragraph(b.get("namespace",""), row_s),
            ])
        t = Table(rows, colWidths=[W*0.28, W*0.18, W*0.30, W*0.24])
        ts_extra = [("BACKGROUND",(0,0),(-1,0), CAST_BLUE),
                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE, GRAY_LIGHT])]
        t.setStyle(TableStyle(grid(ts_extra)))
        story.append(t)
    else:
        story.append(callout("No evictor blockers found in the analysis window.", W,
                             bg=GREEN_LIGHT, border=GREEN_PASS, tc=GREEN_PASS))
    story.append(Spacer(1, 12))

# ── Section 2: Pod Health ─────────────────────────────────────────────────────
def section_pod_health(story, data, W):
    ph = data["pod_health"]
    story.append(section_header("2. Pod Health", W))
    story.append(Spacer(1, 6))

    unhealthy = ph.get("unhealthy", [])
    if not unhealthy:
        story.append(callout("All pods healthy — no Pending/Failed/CrashLoopBackOff pods found.", W,
                             bg=GREEN_LIGHT, border=GREEN_PASS, tc=GREEN_PASS))
    else:
        hdr_s = S("ph", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("pr", fontSize=8, textColor=CAST_BLACK)
        rows = [[Paragraph(c, hdr_s) for c in ["Pod","Namespace","Phase","Container","State","Reason","Restarts"]]]
        for p in unhealthy:
            reason = p.get("reason","")
            bg_c = RED_LIGHT if reason in ("CrashLoopBackOff","OOMKilled") else AMBER_LIGHT
            rows.append([
                Paragraph(p.get("name",""), row_s),
                Paragraph(p.get("namespace",""), row_s),
                Paragraph(p.get("phase",""), row_s),
                Paragraph(p.get("container",""), row_s),
                Paragraph(p.get("state",""), row_s),
                Paragraph(reason, S(f"rr_{reason}", fontSize=8,
                                    textColor=RED_FAIL if reason in ("CrashLoopBackOff","OOMKilled") else AMBER_DARK)),
                Paragraph(str(p.get("restarts",0)), row_s),
            ])
        cw = [W*0.20, W*0.14, W*0.10, W*0.14, W*0.10, W*0.20, W*0.12]
        t = Table(rows, colWidths=cw)
        t.setStyle(TableStyle(grid([("BACKGROUND",(0,0),(-1,0), CAST_BLUE),
                                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE,GRAY_LIGHT])])))
        story.append(t)
    story.append(Spacer(1, 12))


# ── Section 4: Max Pod Per Node ───────────────────────────────────────────────
def section_max_pod(story, data, W):
    mpn = data["max_pod_per_node"]
    story.append(section_header("3. Max Pod Per Node", W))
    story.append(Spacer(1, 6))

    cfg = mpn.get("config_summary", [])
    if cfg:
        hdr_s = S("mph", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("mpr", fontSize=8, textColor=CAST_BLACK)
        rows = [[Paragraph(c, hdr_s) for c in ["Node Config","Instance Type","Provider","Max Pods","Nodes"]]]
        for r in cfg:
            rows.append([
                Paragraph(r.get("node_config",""), row_s),
                Paragraph(r.get("instance_type",""), row_s),
                Paragraph(r.get("provider",""), row_s),
                Paragraph(str(r.get("max_pods","")), row_s),
                Paragraph(str(r.get("node_count","")), row_s),
            ])
        t = Table(rows, colWidths=[W*0.24, W*0.22, W*0.14, W*0.18, W*0.12, W*0.10][:5])
        t.setStyle(TableStyle(grid([("BACKGROUND",(0,0),(-1,0), CAST_BLUE),
                                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE,GRAY_LIGHT])])))
        story.append(t)
        story.append(Spacer(1, 8))

    at_cap = mpn.get("at_capacity", [])
    if at_cap:
        story.append(Paragraph("Nodes at or Near Pod Capacity",
                                S("mpnhdr", fontName="Helvetica-Bold", fontSize=9, textColor=RED_FAIL)))
        story.append(Spacer(1, 4))
        hdr_s = S("mph2", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("mpr2", fontSize=8, textColor=CAST_BLACK)
        rows = [[Paragraph(c, hdr_s) for c in ["Node","Instance","Config","Allocatable","Running","Utilization"]]]
        for r in at_cap:
            pct = r.get("pct", 0)
            flag = "AT CAPACITY" if pct >= 100 else "NEAR CAPACITY"
            pct_style = S(f"pct_{pct}", fontSize=8,
                          textColor=RED_FAIL if pct >= 100 else AMBER_DARK,
                          fontName="Helvetica-Bold")
            rows.append([
                Paragraph(r.get("node",""), row_s),
                Paragraph(r.get("instance_type",""), row_s),
                Paragraph(r.get("config",""), row_s),
                Paragraph(str(r.get("allocatable","")), row_s),
                Paragraph(str(r.get("running","")), row_s),
                Paragraph(f"{pct}% {flag}", pct_style),
            ])
        t = Table(rows, colWidths=[W*0.26, W*0.16, W*0.14, W*0.12, W*0.10, W*0.22])
        t.setStyle(TableStyle(grid([("BACKGROUND",(0,0),(-1,0), CAST_BLUE),
                                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[RED_LIGHT,CAST_WHITE])])))
        story.append(t)
    else:
        story.append(callout("No nodes at or near pod capacity.", W,
                             bg=GREEN_LIGHT, border=GREEN_PASS, tc=GREEN_PASS))
    story.append(Spacer(1, 12))

# ── Section 5: Node Template Analysis ────────────────────────────────────────
def section_node_templates(story, data, W):
    nt = data["node_templates"]
    story.append(section_header("4. Node Template Analysis", W))
    story.append(Spacer(1, 6))

    inventory = nt.get("inventory", [])
    if inventory:
        hdr_s = S("nth", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("ntr", fontSize=8, textColor=CAST_BLACK)
        rows = [[Paragraph(c, hdr_s) for c in ["Template","Nodes","Arch","Capacity","OS","Instance Types","Taints","GPU"]]]
        for r in inventory:
            rows.append([
                Paragraph(r.get("template",""), row_s),
                Paragraph(str(r.get("count","")), row_s),
                Paragraph(", ".join(r.get("arch",[])), row_s),
                Paragraph(", ".join(r.get("capacity_type",[])), row_s),
                Paragraph(", ".join(r.get("os",[])), row_s),
                Paragraph(", ".join(r.get("instance_types",[])), row_s),
                Paragraph(", ".join(r.get("taints",[])) or "None", row_s),
                Paragraph("Yes" if r.get("gpu") else "No", row_s),
            ])
        cw = [W*0.17, W*0.06, W*0.08, W*0.10, W*0.07, W*0.22, W*0.20, W*0.06]
        t = Table(rows, colWidths=cw)
        t.setStyle(TableStyle(grid([("BACKGROUND",(0,0),(-1,0), CAST_BLUE),
                                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE,GRAY_LIGHT])])))
        story.append(t)
        story.append(Spacer(1, 10))

    merge = nt.get("merge_candidates", [])
    keep  = nt.get("keep_separate", [])
    misc  = nt.get("misconfigured", [])

    story.append(Paragraph("Consolidation Recommendations",
                            S("crhdr", fontName="Helvetica-Bold", fontSize=9, textColor=CAST_BLACK)))
    story.append(Spacer(1, 4))

    if merge:
        for m in merge:
            tnames = " + ".join(f"`{x}`" for x in m.get("templates",[]))
            story.append(callout(
                f"MERGE CANDIDATE: {tnames}\n{m.get('reason','')}",
                W, bg=BLUE_LIGHT, border=BLUE_INFO, tc=BLUE_INFO))
            story.append(Spacer(1, 4))

    if misc:
        for ms in misc:
            story.append(callout(
                f"MISCONFIGURED: {ms.get('template','')} — {ms.get('issue','')}",
                W, bg=RED_LIGHT, border=RED_FAIL, tc=RED_FAIL))
            story.append(Spacer(1, 4))

    if keep:
        for k in keep:
            story.append(callout(
                f"KEEP SEPARATE: {k.get('template','')} — {k.get('reason','')}",
                W, bg=GRAY_LIGHT, border=GRAY_MID, tc=GRAY_DARK))
            story.append(Spacer(1, 4))

    if not merge and not misc and not keep:
        story.append(callout("No consolidation opportunities found. All templates are correctly scoped.", W,
                             bg=GREEN_LIGHT, border=GREEN_PASS, tc=GREEN_PASS))
    story.append(Spacer(1, 12))

# ── Section 6: NT Resource Profile ───────────────────────────────────────────
def section_nt_resource_profile(story, data, W):
    ntrp = data.get("nt_resource_profile", {})
    story.append(section_header("5. Node Template Resource Profile", W))
    story.append(Spacer(1, 6))

    templates = ntrp.get("templates", [])
    if not templates:
        story.append(callout("No resource profile data available.", W,
                             bg=GRAY_LIGHT, border=GRAY_MID, tc=GRAY_DARK))
        story.append(Spacer(1, 12))
        return

    PATTERN_COLORS = {
        "memory-heavy":    (PURPLE_LIGHT, PURPLE),
        "compute-heavy":   (ORANGE_LIGHT, ORANGE_WARN),
        "general-purpose": (GREEN_LIGHT,  GREEN_PASS),
    }
    PATTERN_RECO = {
        "memory-heavy":    "r6i/r7g (AWS)  ·  n2-highmem (GCP)  ·  Epsv5 (Azure)",
        "compute-heavy":   "c6i/c7g (AWS)  ·  n2-highcpu (GCP)  ·  Fsv2 (Azure)",
        "general-purpose": "m6i/m7g (AWS)  ·  n2-standard (GCP)  ·  Dsv5 (Azure)",
    }

    hdr_s = S("ntrph", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
    row_s = S("ntrpr", fontSize=8, textColor=CAST_BLACK)
    rows  = [[Paragraph(c, hdr_s) for c in
              ["Template", "Nodes", "CPU Req", "Mem Req", "CPU:Mem Ratio", "Pattern", "Recommendation"]]]

    for t in templates:
        pattern = t.get("pattern", "general-purpose")
        _, tc   = PATTERN_COLORS.get(pattern, (CAST_WHITE, CAST_BLACK))
        pat_s   = S(f"pat_{t.get('template','')}", fontSize=8, textColor=tc, fontName="Helvetica-Bold")
        reco    = t.get("recommendation") or PATTERN_RECO.get(pattern, "")
        rows.append([
            Paragraph(t.get("template", ""), row_s),
            Paragraph(str(t.get("node_count", "")), row_s),
            Paragraph(f"{t.get('cpu_vcpu', 0)} vCPU", row_s),
            Paragraph(f"{t.get('mem_gi', 0)} Gi", row_s),
            Paragraph(t.get("ratio_str", ""), row_s),
            Paragraph(pattern, pat_s),
            Paragraph(reco, row_s),
        ])

    t = Table(rows, colWidths=[W*0.14, W*0.06, W*0.09, W*0.09, W*0.12, W*0.14, W*0.36])
    t.setStyle(TableStyle(grid([("BACKGROUND", (0,0),(-1,0), CAST_BLUE),
                                ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE,GRAY_LIGHT])])))
    story.append(t)
    story.append(Spacer(1, 8))

    if ntrp.get("ds_advisory"):
        ds_pct = ntrp.get("ds_cpu_pct", 0)
        total  = ntrp.get("total_nodes", 0)
        story.append(callout(
            f"ADVISORY: DaemonSet pods are consuming {ds_pct}% of total cluster CPU across {total} nodes.\n"
            f"On the current instance sizes, DaemonSet overhead per node is disproportionately high.\n"
            f"Recommendation: Set minCPU=4 in node templates to enforce a minimum instance size "
            f"and reduce DaemonSet-to-workload CPU dilution.",
            W, bg=AMBER_LIGHT, border=AMBER_WARN, tc=AMBER_DARK))

    story.append(Spacer(1, 12))

# ── Section 7: WOOP Rollout Strategy ─────────────────────────────────────────
def section_woop_rollout(story, data, W):
    wr = data.get("woop_rollout", {})
    story.append(section_header("7. WOOP Rollout Strategy Audit", W))
    story.append(Spacer(1, 6))

    if not wr.get("active", False):
        story.append(callout("WOOP not active on this cluster or no managed workloads found.",
                             W, bg=GRAY_LIGHT, border=GRAY_MID, tc=GRAY_DARK))
        story.append(Spacer(1, 12))
        return

    total   = wr.get("total_checked", 0)
    ok      = wr.get("ok", 0)
    warns   = wr.get("warnings", 0)
    actions = wr.get("action_needed", 0)

    summary_s = S("wrsumm", fontSize=9, textColor=CAST_BLACK)
    story.append(Paragraph(
        f"Total WOOP workloads checked: <b>{total}</b>  |  "
        f"<font color='#22C55E'>OK: {ok}</font>  |  "
        f"<font color='#F59E0B'>Warnings: {warns}</font>  |  "
        f"<font color='#EF4444'>Action Needed: {actions}</font>",
        summary_s))
    story.append(Spacer(1, 8))

    issues = wr.get("issues", [])
    if not issues:
        story.append(callout(
            "All WOOP workloads are using one-by-one rollout. No zero-downtime issues found.",
            W, bg=GREEN_LIGHT, border=GREEN_PASS, tc=GREEN_PASS))
    else:
        hdr_s = S("wrhdr", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("wrrow", fontSize=8, textColor=CAST_BLACK)
        rows  = [[Paragraph(c, hdr_s) for c in
                  ["Workload", "Namespace", "Replicas", "Rollout Strategy", "Zero-Downtime", "Status"]]]
        for issue in issues:
            status = issue.get("status", "")
            if status == "ACTION NEEDED":
                st_s = S(f"wrs_{issue.get('workload','')}", fontSize=8,
                         textColor=RED_FAIL, fontName="Helvetica-Bold")
                row_bg = RED_LIGHT
            else:
                st_s = S(f"wrs_{issue.get('workload','')}", fontSize=8,
                         textColor=AMBER_DARK, fontName="Helvetica-Bold")
                row_bg = AMBER_LIGHT

            replicas = issue.get("replicas", "")
            zdt_val  = issue.get("zero_downtime")
            if replicas != 1:
                zdt_str = "N/A (multi)"
            else:
                zdt_str = "Enforced" if zdt_val else "Not enforced"

            rows.append([
                Paragraph(issue.get("workload", ""), row_s),
                Paragraph(issue.get("namespace", ""), row_s),
                Paragraph(str(replicas), row_s),
                Paragraph(issue.get("rollout_strategy", ""), row_s),
                Paragraph(zdt_str, row_s),
                Paragraph(status, st_s),
            ])

        t = Table(rows, colWidths=[W*0.22, W*0.15, W*0.09, W*0.18, W*0.16, W*0.20])
        t.setStyle(TableStyle(grid([("BACKGROUND", (0,0),(-1,0), CAST_BLUE),
                                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE,GRAY_LIGHT])])))
        story.append(t)

    story.append(Spacer(1, 12))

# ── Section 6: Rebalancing ───────────────────────────────────────────────────
def _rb_int(v):
    return "—" if v is None else str(v)

def _rb_num(v, nd=1, suffix=""):
    if v is None:
        return "—"
    try:
        return f"{float(v):,.{nd}f}{suffix}"
    except (TypeError, ValueError):
        return str(v)

def _rb_money(v):
    if v is None:
        return "—"
    try:
        return f"${float(v):,.2f}"
    except (TypeError, ValueError):
        return str(v)

def _rb_status(e):
    # Flag-based checks first (preserves existing behaviour when flags are set).
    if e.get("is_skipped"):
        return "Skipped", GRAY_DARK
    if e.get("is_partial"):
        return "Partial", AMBER_DARK
    if e.get("is_success") is not None:
        return ("Success", GREEN_PASS) if e.get("is_success") else ("Failed", RED_FAIL)
    # Flag-absence path: key off the raw status string. Missing/unknown status
    # renders as "Unknown" — never silently "Failed".
    status = str(e.get("status") or "").lower()
    if status == "error":
        return "Failed", RED_FAIL
    if status == "partially_finished":
        return "Partial", AMBER_DARK
    if status == "generated":
        return "Skipped", GRAY_DARK
    if status == "finished":
        return ("Success", GREEN_PASS) if e.get("is_success") else ("Failed", RED_FAIL)
    return "Unknown", GRAY_DARK

# severity -> (row background, badge/border color, title text color)
_RB_SEV_STYLES = {
    "critical": (RED_LIGHT,   RED_FAIL,   RED_FAIL),
    "warning":  (AMBER_LIGHT, AMBER_WARN, AMBER_DARK),
    "info":     (BLUE_LIGHT,  BLUE_INFO,  BLUE_INFO),
}

def section_rebalancing(story, data, W):
    rb = data.get("rebalancing") or {}
    story.append(section_header("6. Rebalancing", W))
    story.append(Spacer(1, 6))

    # Schedules
    schedules   = rb.get("schedules") or []
    sched_names = ", ".join(s.get("name", "") for s in schedules if s.get("name"))
    story.append(Paragraph(
        f"Rebalancing schedules: {escape(str(sched_names)) if sched_names else 'None configured'}",
        S("rbmeta", fontSize=8.5, textColor=GRAY_DARK)))
    story.append(Spacer(1, 8))

    # Last completed rebalance
    story.append(Paragraph("Last Completed Rebalance",
                            S("rblh", fontName="Helvetica-Bold", fontSize=9, textColor=CAST_BLACK)))
    story.append(Spacer(1, 4))
    lr = rb.get("last_rebalance") or {}
    if not lr.get("has_rebalancing"):
        story.append(callout("No rebalancing has run.", W,
                             bg=GRAY_LIGHT, border=GRAY_MID, tc=GRAY_DARK))
    else:
        lbl_s = S("rblbl", fontName="Helvetica-Bold", fontSize=8, textColor=GRAY_DARK)
        val_s = S("rbval", fontSize=8, textColor=CAST_BLACK)
        days  = lr.get("days_since")
        days_str = f"{days} days ago" if days is not None else "—"
        pairs = [
            ("Date",
             f"{escape(str(lr.get('last_rebalance_date') or '—'))} ({escape(str(days_str))})"),
            ("Nodes",
             f"{_rb_int(lr.get('nodes_before'))} → {_rb_int(lr.get('nodes_after'))}  "
             f"({_rb_num(lr.get('nodes_reduction_pct'))}% reduction)"),
            ("CPU",
             f"{_rb_num(lr.get('cpu_reduction_pct'))}% reduction"),
            ("Cost",
             f"{_rb_money(lr.get('cost_before_hourly'))}/hr → {_rb_money(lr.get('cost_after_hourly'))}/hr"),
            ("Savings",
             f"{_rb_money(lr.get('cost_savings_monthly'))}/mo  "
             f"({_rb_num(lr.get('cost_savings_pct'))}%)"),
        ]
        rows = [[Paragraph(l, lbl_s), Paragraph(v, val_s)] for l, v in pairs]
        t = Table(rows, colWidths=[W*0.16, W*0.84])
        t.setStyle(TableStyle(grid([("BACKGROUND", (0,0),(0,-1), GRAY_LIGHT)])))
        story.append(t)
    story.append(Spacer(1, 10))

    # Recent events
    story.append(Paragraph("Recent Rebalancing Events",
                            S("rbev", fontName="Helvetica-Bold", fontSize=9, textColor=CAST_BLACK)))
    story.append(Spacer(1, 4))
    events = rb.get("events") or []
    if not events:
        story.append(callout("No recent rebalancing plans.", W,
                             bg=GRAY_LIGHT, border=GRAY_MID, tc=GRAY_DARK))
    else:
        hdr_s = S("rbh", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("rbr", fontSize=8, textColor=CAST_BLACK)
        rows  = [[Paragraph(c, hdr_s) for c in
                  ["Date", "Status", "Schedule", "Nodes", "CPU", "Savings $/mo", "%"]]]
        for e in events:
            status, tc = _rb_status(e)
            st_s = S(f"rbs_{e.get('plan_id','')}", fontSize=8, textColor=tc,
                     fontName="Helvetica-Bold")
            status_text = status
            if status == "Skipped" and e.get("skip_reason"):
                status_text = (f"Skipped<br/><font size=6.5 color='#6B7280'>"
                               f"{escape(str(e['skip_reason']))}</font>")
            elif status == "Failed" and e.get("error_summary"):
                status_text = (f"Failed<br/><font size=6.5 color='#EF4444'>"
                               f"{escape(str(e['error_summary']))}</font>")
            rows.append([
                Paragraph(escape(str(e.get("date") or "—")), row_s),
                Paragraph(status_text, st_s),
                Paragraph(escape(str(e.get("schedule_name") or "—")), row_s),
                Paragraph(f"{_rb_int(e.get('nodes_before'))} → {_rb_int(e.get('nodes_after'))}", row_s),
                Paragraph(f"{_rb_num(e.get('cpu_before'))} → {_rb_num(e.get('cpu_after'))}", row_s),
                Paragraph(_rb_money(e.get("cost_savings_monthly")), row_s),
                Paragraph(_rb_num(e.get("cost_savings_pct"), suffix="%"), row_s),
            ])
        t = Table(rows, colWidths=[W*0.12, W*0.24, W*0.13, W*0.13, W*0.14, W*0.14, W*0.10])
        t.setStyle(TableStyle(grid([("BACKGROUND",(0,0),(-1,0), CAST_BLUE),
                                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE,GRAY_LIGHT])])))
        story.append(t)
    story.append(Spacer(1, 10))

    # Old on-demand nodes
    story.append(Paragraph("Old On-Demand CAST-Managed Nodes (>= 30 Days)",
                            S("rbod", fontName="Helvetica-Bold", fontSize=9, textColor=CAST_BLACK)))
    story.append(Spacer(1, 4))
    od = rb.get("old_ondemand_nodes") or []
    if not od:
        story.append(callout("No old on-demand CAST-managed nodes (>= 30 days).", W,
                             bg=GREEN_LIGHT, border=GREEN_PASS, tc=GREEN_PASS))
    else:
        hdr_s = S("rbodh", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("rbodr", fontSize=8, textColor=CAST_BLACK)
        rows  = [[Paragraph(c, hdr_s) for c in ["Node", "Instance Type", "Age (days)"]]]
        for n in od:
            rows.append([
                Paragraph(escape(str(n.get("name", ""))), row_s),
                Paragraph(escape(str(n.get("instance_type", ""))), row_s),
                Paragraph(escape(str(n.get("age_days", ""))), row_s),
            ])
        t = Table(rows, colWidths=[W*0.50, W*0.28, W*0.22])
        t.setStyle(TableStyle(grid([("BACKGROUND",(0,0),(-1,0), CAST_BLUE),
                                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE,GRAY_LIGHT])])))
        story.append(t)
        story.append(Spacer(1, 4))
        story.append(Paragraph(
            f"Total old on-demand nodes: <b>{escape(str(rb.get('old_ondemand_count', len(od))))}</b>",
            S("rbodt", fontSize=8.5, textColor=GRAY_DARK)))
    story.append(Spacer(1, 10))

    # Rebalancing health findings (Step 7f) — rendered only when findings exist;
    # an absent subsection means healthy / no data (no "no findings" noise).
    rbh          = data.get("rebalancing_health") or {}
    rb_findings  = rbh.get("findings") or []
    if rb_findings:
        story.append(Paragraph("Rebalancing Health Findings",
                                S("rbfh", fontName="Helvetica-Bold", fontSize=9, textColor=CAST_BLACK)))
        story.append(Spacer(1, 4))
        _sev_order = {"critical": 0, "warning": 1, "info": 2}
        for f in sorted(rb_findings,
                        key=lambda x: _sev_order.get(str(x.get("severity", "info")).lower(), 2)):
            sev = str(f.get("severity", "info")).lower()
            bg, border, tc = _RB_SEV_STYLES.get(sev, _RB_SEV_STYLES["info"])
            badge_text = str(f.get("severity", "info")).upper()
            badge_s = S(f"rbfb_{id(f)}", fontName="Helvetica-Bold", fontSize=7,
                        textColor=CAST_WHITE, alignment=TA_CENTER, leading=9)
            badge = Table([[Paragraph(badge_text, badge_s)]], colWidths=[0.72*inch])
            badge.setStyle(TableStyle([
                ("BACKGROUND",    (0,0),(-1,-1), border),
                ("TOPPADDING",    (0,0),(-1,-1), 2),
                ("BOTTOMPADDING", (0,0),(-1,-1), 2),
            ]))
            title_s  = S(f"rbft_{id(f)}", fontName="Helvetica-Bold", fontSize=8.5,
                         textColor=tc, leading=12)
            detail_s = S(f"rbfd_{id(f)}", fontSize=8, textColor=CAST_BLACK, leading=11.5)
            body = [Paragraph(escape(str(f.get("title", ""))), title_s)]
            if f.get("detail"):
                body += [Spacer(1, 2), Paragraph(escape(str(f.get("detail", ""))), detail_s)]
            row = Table([[badge, body]], colWidths=[0.82*inch, W-0.82*inch])
            row.setStyle(TableStyle([
                ("BACKGROUND",    (0,1),(-1,-1), bg),
                ("BOX",           (0,0),(-1,-1), 1, border),
                ("LEFTPADDING",   (0,0),(-1,-1), 8),
                ("RIGHTPADDING",  (0,0),(-1,-1), 8),
                ("TOPPADDING",    (0,0),(-1,-1), 6),
                ("BOTTOMPADDING", (0,0),(-1,-1), 6),
                ("VALIGN",        (0,0),(-1,-1), "TOP"),
            ]))
            story.append(row)
            story.append(Spacer(1, 4))
        story.append(Spacer(1, 6))

    # Audit events are Step 7f diagnostic context (they inform finding wording,
    # e.g. why a schedule skipped) — they never render as a PDF table: on
    # healthy-but-skipping clusters the raw trail just repeats the events table.
    story.append(Spacer(1, 6))

# ── Main ──────────────────────────────────────────────────────────────────────
def generate(data, output_path):
    doc = BaseDocTemplate(
        output_path, pagesize=letter,
        leftMargin=30, rightMargin=30,
        topMargin=68, bottomMargin=30,
    )
    W     = doc.width
    frame = Frame(doc.leftMargin, doc.bottomMargin, W, doc.height, id="main")
    deco  = make_decorator(
        data.get("cluster_name",""),
        data.get("cluster_id",""),
        data.get("generated_at",""))
    doc.addPageTemplates([PageTemplate(id="main", frames=[frame], onPage=deco)])

    story = []
    cover(story, data, W)
    section_exec_summary(story, data, W)
    section_evictor(story, data, W)
    section_pod_health(story, data, W)
    section_max_pod(story, data, W)
    section_node_templates(story, data, W)
    section_nt_resource_profile(story, data, W)
    section_rebalancing(story, data, W)
    section_woop_rollout(story, data, W)
    doc.build(story)
    print(f"Report written: {output_path}")

if __name__ == "__main__":
    data_path   = sys.argv[1] if len(sys.argv) > 1 else "/home/claude/cast_optimise_data.json"
    output_path = sys.argv[2] if len(sys.argv) > 2 else "/home/claude/cast_optimise_report.pdf"
    with open(data_path) as f:
        data = json.load(f)
    generate(data, output_path)
```

Run the script:

```bash
pip install reportlab --break-system-packages --quiet
python3 /home/claude/generate_cast_optimise_report.py \
    /home/claude/cast_optimise_data.json \
    /home/claude/cast_optimise_report.pdf
```

### 9c: Copy to outputs

```bash
import re
cluster_safe = re.sub(r"[^\w\-]", "-", data.get("cluster_name") or data.get("cluster_id","report")).strip("-")
output_filename = f"Cast AI Optimisation Report – {cluster_safe}.pdf"
```

Copy final PDF to `/mnt/user-data/outputs/<output_filename>` and call `present_files` to surface it to the user.

### 9d: PDF structure summary

| Section | Content |
|---|---|
| Cover | Cluster metadata + 7-badge scorecard (blocked nodes, cross-matches, unhealthy pods, nodes at pod cap, merge candidates, NT profile issues, WOOP rollout issues) |
| Exec Summary | Priority-ranked action table (Critical / High / Medium) derived from all findings. Skipped if no issues found. |
| 1. Evictor Analysis | Cross-match callouts (red), blocker table |
| 2. Pod Health | Unhealthy pod table with CrashLoopBackOff/OOMKilled highlighted |
| 3. Max Pod Per Node | Config summary table + nodes at capacity |
| 4. Node Template Analysis | Inventory table + MERGE/KEEP/MISCONFIGURED callouts |
| 5. NT Resource Profile | Per-template CPU:Memory ratio, pattern classification, instance family recommendation, DaemonSet advisory |
| 6. Rebalancing | Events table, last completed rebalance, old on-demand nodes, Rebalancing Health Findings (severity badges critical/warning/info) |
| 7. WOOP Rollout Strategy | Per-workload rollout strategy + zero-downtime check (single-replica only) |

---

## Notes

- A cluster is "connected" only if `status == "ready"` AND `agentStatus == "online"`.
- Evictor logs use `component_timestamp` as the true timestamp, not Loki ingest time.
- Each reconcile cycle has a unique `reconcile_id`. Use it to count distinct cycles.
- Persistent blockers (same node every cycle) must be called out explicitly.
- Pod health scan uses the latest snapshot. Note if snapshot age > 15 min.
- Max pod values come from `status.allocatable.pods` on each node object in the snapshot. This reflects the effective limit after kubelet and CNI configuration.
- On MCP timeout mid-batch, skip the cluster and continue. Never abort the run.
- PDF generation (Step 10) runs after all analysis steps complete for a single cluster. For org-wide runs, generate one PDF per cluster plus a summary-only PDF for the org.
- The PDF script embeds the CAST AI brand palette matching the cluster-readiness report. If the icon asset is absent, a fallback blue circle is used.
- All section data is passed via the JSON file in 10a. Populate every field before calling the generator.
