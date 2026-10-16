---
name: eks-helm-app-decommission
description: Use when removing a self-hosted helm app and its whole footprint (namespace, PVCs and EBS volumes, Istio routes and policies, GitLab webhooks and tokens, repo and worktree copies) from an EKS cluster to stop its cost or licence exposure, and when proving nothing is left behind. Triggers - "remove X from the cluster", "stop paying for X", "uninstall the helm release and clean up", "decommission a self-hosted app". Not for feature-validation stages (fv-cluster-decommission) or EC2 hosts (ec2-idle-host-decommission).
---

# EKS helm app decommission

Built from the 2026-10-10 Kodus removal (cluster aws0iacdeveks01, namespace mr-review). Order matters: stop inbound traffic, revoke credentials, uninstall, decide on data, check cost, delete the namespace, verify, watch for re-creation, then clean repos.

## 0. Inventory first (read-only, literal ARN)
- `helm --kube-context <ARN> -n <ns> list` and `helm ... history <release>`.
- `kubectl --context <ARN> -n <ns> get deploy,sts,svc,pvc,cm,secret,networkpolicy -o name`. Objects without the label `app.kubernetes.io/instance` were applied by hand and survive `helm uninstall`.
- Cluster-wide `get` for the app name, one kind per call so a missing kind does not hide the rest: virtualservice, authorizationpolicy, gateway, ingress, clusterrole, clusterrolebinding, role, rolebinding, serviceaccount, poddisruptionbudget, horizontalpodautoscaler, servicemonitor, podmonitor, prometheusrule, externalsecret, secretstore, crd.
- Outside the cluster, names only: GitLab hooks (project and group), group members (bot users), CI variable KEYS (never values), remote branches; local worktrees (dirty files, unpushed commits), local Docker images and containers; AWS IAM roles and policies, S3, Route 53 records, ELB target groups, Secrets Manager, SSM parameters, log groups, alarms, security groups.
- Repo: `git grep -i <app>` for references. Check `git status` on the main worktree before any commit.

## 1. Stop inbound first
- Delete GitLab webhooks: `glab api -X DELETE projects/<pid>/hooks/<id>`. Check group hooks too; on CE the group hooks endpoint returned 404, which was read as none.
- Delete Istio VirtualServices and AuthorizationPolicies explicitly. `helm uninstall` may not remove objects in other namespaces.
- Before blaming a route, check for a catch-all VirtualService (host `*`). After Kodus was gone, its old webhook host still answered `200 ok` from `alb-healthcheck-200`.

## 2. Revoke credentials only the app used
- Group or project access token: check `last_used_at` (null = never used). Revoking a group token removes its bot user.
- Keep shared personal tokens that other tools use (PR-Agent's `LLM_TOKEN` in the Kodus case). Only the app's own secret copies go.

## 3. Uninstall
- `helm --kube-context <ARN> -n <ns> uninstall <release>`. A repeat after the release is gone returns `release: not found`, which changes nothing.
- Hand-applied objects remain. Delete them by name, or with the namespace in step 6.

## 4. Data decision (point of no return)
- StatefulSet PVCs survive uninstall. Default `persistentVolumeClaimRetentionPolicy` is `Retain`.
- Dump databases only while the DB pods still exist. After the StatefulSet is gone, a dump needs a temp pod mounting the PVC, which is another cluster write.
- Get an explicit go from the user before deleting PVCs.

## 5. Cost check: EBS
- The storage class `ebs-csi-default-sc` has reclaim `Delete`. Check each PV's reclaim policy with `kubectl get pv <name> -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'`. `Retain` keeps the EBS volume billing.
- Count volumes by CSI tag: `aws ec2 describe-volumes --profile <p> --region <r> --filters "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=<ns>" --query 'length(Volumes)' --output text`.
- Validate the filter first on a live namespace with a Bound PVC (it returned 1 for `helm-dependency`). A zero from an unvalidated filter proves nothing.

## 6. Delete the namespace
- `kubectl --context <ARN> delete namespace <ns>`. This cascades secrets and PVC objects. Expect a Terminating phase, then NotFound.

## 7. Verify with fresh reads
- Namespace NotFound. Cluster-wide names empty. Helm release not found. EBS count 0. `kubectl get pv` has no Released volumes and no claims from the namespace.
- Reads can contradict each other. On Kodus, a 'none' read of the AuthorizationPolicies was followed by a successful delete of the same objects minutes later; a helm uninstall also printed success after an earlier read showed the release gone. Cause not found. Re-check after a delay before reporting done.

## 8. Watch for re-creation (10 min)
- Arm a Monitor: loop every 30 s over the kinds from step 0, print the first hit, end with a CLEAN line.
- Find GitOps owners: ArgoCD apps with `prune` and `selfHeal` on the same namespaces. Read `spec.source` or `spec.sources`, and `status.resources`. Grep the GitOps repo for the object names.

## 9. Repos and local cleanup (ask first)
- Remove the app directory and its references on a branch with an MR. Never commit to main. Keep benchmark results and history docs.
- Worktrees: remove only clean ones with no unpushed commits. Push or keep the rest.
- Memory notes and Claude artifacts describing the app: mark them historical rather than delete, unless asked.

## Guardrails
- Deploy and prod guards block agent cluster writes. Give the user one command per block, with the literal `--context` ARN, and check each result with read-only `get`.
- Each destructive step needs an explicit go: webhook delete, token revoke, PVC or namespace delete, repo deletes.
- Report cost in plain terms: what stops billing (EBS, the app's pods) and what is now gone for good (DB data, review history).
