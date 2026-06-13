---
name: eks-nodegroup-upgrade-unblock
description: Diagnose and resolve EKS managed-node-group version upgrades stalled on PodEvictionFailure. Locates the un-evictable pod via PDB math (`minAvailable >= currentHealthy`), inspects pods on the stuck node, and applies one of three mitigation paths (Option A delete pod, Option B temp PDB patch, Option C AWS console force-update). Use when an `aws_eks_node_group` Terraform resource is stuck >15 min in `Updating`, or when `terraform apply` errors with `PodEvictionFailure: Reached max retries`.
---

# EKS Node Group Upgrade Unblocker

## When to use

- Atlantis or Terraform apply on an `aws_eks_node_group` resource has been "Still modifying..." for >15 minutes
- AWS console shows node group status `Updating` for an unusually long time
- Terraform error: `unexpected state 'Failed', wanted target 'Successful'. last error: ...PodEvictionFailure: Reached max retries while trying to evict pods from nodes in node group ...`

This skill assumes the user is **mid-incident** and wants results fast, not a code change.

## Phase 1 — Discover state (read-only)

Identify the cluster, node group, AWS profile, region. Common shape on EIS IaC:

```bash
export AWS_PROFILE=<from aws_profiles memory> AWS_REGION=us-west-2
aws sts get-caller-identity   # confirm SSO valid; if expired prompt user to run `aws sso login`
CLUSTER=<cluster-name>
NG=<nodegroup-name>            # from terraform error or AWS console URL

aws eks list-updates --name $CLUSTER --nodegroup-name $NG --region us-west-2

# describe each update (newest first) until you find status=Failed with PodEvictionFailure
aws eks describe-update --name $CLUSTER --nodegroup-name $NG \
  --update-id <id> --region us-west-2 \
  --query 'update.{status:status,errors:errors,params:params,created:createdAt}'
```

The `errors[0].resourceIds[0]` = the stuck node FQDN. Save as `DRAIN`.

```bash
aws eks update-kubeconfig --name $CLUSTER --region us-west-2 --alias <short-alias>
kubectl config current-context   # confirm
```

## Phase 2 — Find the blocking PDB

```bash
DRAIN=<from above>

# A) Pods left on the stuck node (filter DaemonSets — those don't block drain)
kubectl get pods -A --field-selector spec.nodeName=$DRAIN -o json | \
  jq -r '.items[] | select(.metadata.ownerReferences[0].kind != "DaemonSet") |
    "\(.metadata.namespace)/\(.metadata.name)  owner=\(.metadata.ownerReferences[0].kind // "none")/\(.metadata.ownerReferences[0].name // "-")  age=\(.status.startTime)"'

# B) PDBs that disallow disruptions (the math trap)
kubectl get pdb -A -o json | jq -r '.items[] |
  select(.status.disruptionsAllowed == 0) |
  "\(.metadata.namespace)/\(.metadata.name)  min=\(.spec.minAvailable)  max=\(.spec.maxUnavailable)  healthy=\(.status.currentHealthy)/\(.status.desiredHealthy)  selector=\(.spec.selector.matchLabels)"'
```

**Cross-reference:** the blocking PDB's `selector` matches one of the non-DaemonSet pods on `$DRAIN`. Classic culprit: 1-replica `Recreate` Deployment with `minAvailable: 1` → mathematically unevictable.

## Phase 3 — Pick a mitigation

Always **confirm with the user before mutating** — list the three options and explain trade-offs. Reproduce this table verbatim:

| Option | Action | Cost | When best |
|--------|--------|------|-----------|
| **A** | `kubectl delete pod <name> -n <ns>` — Deployment respawns on already-upgraded node | ~30-60s outage of the workload | Fastest; works only if owner is Deployment/ReplicaSet (not StatefulSet with PVC) |
| **B** | `kubectl patch pdb <name> -n <ns> --type=merge -p '{"spec":{"minAvailable":0}}'` → wait for upgrade → restore `{"spec":{"minAvailable":1}}` | Brief PDB protection gap | Planned upgrades, when user wants minimal pod disruption |
| **C** | AWS Console → node group → Update → **Force update version** | EKS terminates pods after PDB retry timeout (~15 min more) | Last resort, no kubectl access |

## Phase 4 — Verify recovery

```bash
# Watch the newest update flip to Successful
aws eks describe-update --name $CLUSTER --nodegroup-name $NG \
  --update-id <new-id> --region us-west-2 --query 'update.status'

# All nodes should be on the target K8s version
kubectl get nodes -o wide | awk 'NR==1 || /'<old-version>'/ {print}'

# Blocker pod alive on a new node
kubectl -n <ns> get pods -l <blocker-selector> -o wide
```

## Phase 5 — Permanent fix (post-incident)

If the PDB lives in a Helm chart, a `kubectl patch` reverts on the next `helm upgrade`. Locate the chart deploy source and add a values override:

```yaml
pdb:
  enabled: false         # OR
  maxUnavailable: 1      # protects against ≥2-replica disruption but allows single-replica drain
```

Check the install path first:
```bash
helm -n <ns> list
helm -n <ns> get values <release>
kubectl -n <ns> get pdb <name> -o yaml | grep -E 'managed-by|helm.sh/release'
```

If chart is **not under Argo CD** (`kubectl get applications.argoproj.io -A` returns nothing), and rev=1 with no recent upgrade, a direct `kubectl edit pdb` is reasonably durable — but flag the revert risk to the user.

## Common stuck-node selectors (EIS clusters)

| Namespace | PDB | Cause | Notes |
|-----------|-----|-------|-------|
| `fivetran` | `hd-agent-pdb` | `minAvailable:1`, 1 replica, `Recreate` | Chart `hybrid-deployment-agent`. Documented in [[aws0caadeveks01-eks-135-upgrade]] |
| `kube-system` | `cluster-autoscaler` etc. | Usually drainable | Check `disruptionsAllowed` field |

## References

- [[aws0caadeveks01-eks-135-upgrade]] — first known incident; full timeline
- [[eks-nodegroup-podeviction-failure]] — terser checklist version of this skill
- [[atlantis-caa-workflow]] — how to trigger plan/apply once the cluster is unblocked
- [[aws-profiles]] — profile-to-account map
