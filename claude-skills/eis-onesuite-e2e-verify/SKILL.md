---
name: eis-onesuite-e2e-verify
description: End-to-end verification that a freshly-provisioned EIS OneSuite client/POC environment is healthy — account/IAM, all Terraform stages applied, network/TGW, EKS + node groups + addons, RDS/MSK, internal ALB/NLB, Cognito SAML, and ArgoCD all-Synced+Healthy. Use when the user says "do e2e testing", "verify the new environment", "is the cluster healthy", "check the OneSuite env end-to-end", "confirm <cluster> is up", or after argocd-cluster-onboarding (Phase 6) to sign off a new env. Covers the PRIVATE-cluster access problem (spoke API is private + the hub kubectl is RBAC-scoped to ArgoCD CRDs only), the temp-endpoint-open-then-revert diagnosis trick, and the two first-sync failure modes (ServiceMonitor-CRD dry-run cascade + istiod node-packing that starves monitoring DaemonSets) with exactly how to confirm each is resolved. Reference run: EISSAASDEV-302 / aws0axajpdeveks01 (AXA Japan POC).
---

# EIS OneSuite — end-to-end environment verification

Final sign-off that a new env (account + network + EKS + data + ArgoCD) is healthy. This is the verification phase **after** P0–P6. The reference env is `aws0axajpdeveks01` (project `axajp`, EISSAASDEV-302).

## 0. Access model — read first (the private-cluster trap)

EIS dev clusters are **private** (`endpointPublicAccess=false`). Three consequences:

- **Your laptop CANNOT `kubectl` the spoke** (its API resolves to private IPs). Confirm: `aws eks describe-cluster --name <c> --region <r> --profile <proj> --query 'cluster.resourcesVpcConfig.endpointPublicAccess'` → `false`.
- **The ArgoCD hub** (`aws0iacdeveks01`, profile `iac`, acct 182399717428) reaches the spoke over TGW. Your hub kubectl is usually **RBAC-scoped to ArgoCD CRDs only** — you can `get applications/applicationsets/secrets -n argocd` but NOT `get pods/svc` (and the argocd-server pods aren't on this cluster, so no resource-tree API). So **app-level health = hub; pod-level health = needs spoke access**.
- To get **pod-level** on a private spoke when you have the project SSO admin: temporarily open the API to your IP, diagnose, **then revert** (see §6). Or use an in-VPC WorkSpace/bastion (none exists until the toolchain fleet is up).

Profiles: `<proj>` = the spoke account SSO admin (e.g. `axajp`); `iac` = the hub account. `aws eks update-kubeconfig --name aws0iacdeveks01 --region us-west-2 --profile iac --alias iac-hub`.

## 1. Account / IAM
```bash
aws sts get-caller-identity --profile <proj>          # right 12-digit account
```
Atlantis assume-roles exist (`aws0iacdeveks01-atlantis-{plan,apply}-Role`), account in the correct OU.

## 2. Terraform — every Atlantis project applied (via the MR)
Each `lower/{infra,dev}/{bootstrap,core,services}` plans clean then applies `0 destroy`, in exec order (infra bootstrap=11→core=12→services=13; dev core=22→services=23). On the provisioning MR, the last per-project note should be `Apply complete! Resources: N added, 0 changed, 0 destroyed`. (infra/services EC2 fleet stays blocked until Red Hat Cloud Access — that's expected, not a failure.)

## 3. Network
```bash
aws ec2 describe-transit-gateway-attachments --profile <proj> --region <r> ...   # Active
```
TGW attachment Active; private DNS zone resolves; the dev VPC can reach the Network-Hub Nexus.

## 4. EKS + data plane (AWS API — no kubectl needed)
```bash
aws eks describe-cluster --name <c> --region <r> --profile <proj> --query 'cluster.status'        # ACTIVE
aws eks list-nodegroups --cluster-name <c> ... ; aws eks describe-nodegroup ... --query 'nodegroup.{status:status,health:health.issues}'   # ACTIVE, health []
aws eks list-addons --cluster-name <c> ...                                                          # vpc-cni, coredns, kube-proxy, ebs-csi, efs-csi
aws eks describe-addon --cluster-name <c> --addon-name aws-ebs-csi-driver ... --query 'addon.{status:status,health:health.issues}'   # ACTIVE, [] (PVCs need this)
aws rds describe-db-instances --region <r> --profile <proj> --query 'DBInstances[0].DBInstanceStatus'   # available
aws kafka list-clusters-v2 --region <r> --profile <proj> --query 'ClusterInfoList[0].State'             # ACTIVE (MSK is the slow one, 25-40 min)
aws ec2 describe-volumes --filters Name=tag:kubernetes.io/cluster/<c>,Values=owned --query 'length(Volumes)'  # >0 = PVCs binding
```

## 5. Cognito SAML
```bash
aws cognito-idp list-user-pools --max-results 30 --region <r> --profile <proj>          # exactly ONE pool
aws cognito-idp describe-identity-provider --user-pool-id <pool> --provider-name SSO --region <r> --profile <proj> --query 'IdentityProvider.ProviderDetails.MetadataURL'
curl -s -o /dev/null -w '%{http_code}' "<that-metadata-url>"                              # MUST be 200
```
GOTCHA (axajp): if the IdC app the pool federates to was deleted/replaced, the metadata URL 404s → SAML broken. The metadata id = `ins-<the apl- application's hex suffix>` (base64 of `<account>_ins-<hex>`). Repoint `metadata_url` in `lower/infra/services/terraform.tfvars` + targeted apply `module.cognito[0]`.

## 6. ArgoCD — the core health check (run against the HUB)
```bash
kubectl --context iac-hub get applications -n argocd --request-timeout=25s -o json 2>/dev/null | python3 -c '
import sys,json; from collections import Counter
d=json.load(sys.stdin)
rows=[(a["metadata"]["name"].replace("-<c>",""),a.get("status",{}).get("sync",{}).get("status"),a.get("status",{}).get("health",{}).get("status")) for a in d["items"] if "<c>" in a["metadata"]["name"]]
print("TOTAL %d | HEALTH=%s | SYNC=%s"%(len(rows),dict(Counter(r[2] for r in rows)),dict(Counter(r[1] for r in rows))))
for c,sy,h in sorted(rows):
  if sy!="Synced" or h!="Healthy": print("  <-- %-30s %s/%s"%(c,sy,h))
'
```
SIGN-OFF: every app **Synced + Healthy** (axajp = 18/18 incl. velero). If the apps aren't even generated, the `cluster-bootstrap` ApplicationSet hasn't reconciled — force it: `kubectl --context iac-hub annotate application app-of-apps -n argocd argocd.argoproj.io/refresh=hard --overwrite`; the cluster secret comes from `bootstrap/clusters/aws0iacdeveks01/manifest/cluster-secret-<c>.yaml`.

### 6a. Known first-sync failure modes (verify each is resolved)
Both are durably fixed in **clusters template ≥ V1.0.8** + argocd MR !298 — a new cluster on ≥V1.0.8 should NOT hit them. If you DO see them:

- **"one or more synchronization tasks are not valid"** on oidc/gen-dashboard/observascope-eis/exporters = the **ServiceMonitor/PrometheusRule CRD doesn't exist yet** (observascope-oss hasn't installed). Root cause is usually observascope-oss itself blocked on a missing SM secret. Durable fix = `SkipDryRunOnMissingResource=true` on the CRD-consumers (MR !298). See [[argocd_fresh_cluster_smooth_install]].
- **observascope-{oss,exporters,logging} stuck Progressing** (no error, StatefulSets never go Degraded) = the **monitoring DaemonSet pods (node-exporter/x509/alloy) are Pending** because **istiod packed 3×2-core replicas onto one node** (100% CPU). Durable fix = istiod soft `topologySpread` (clusters template V1.0.8). Per-cluster hot-fix = drop istiod `pilot.resources.requests.cpu` to 500m. Confirm node CPU: `kubectl --context <spoke> describe node <n> | sed -n '/Allocated resources/,/Events/p' | grep cpu` (needs spoke access — §6c).
- **OutOfSync from the start on gen-dashboard / headlamp / observascope-oss** = env-specific **ExternalSecrets 404** until the per-cluster secrets are seeded (`<c>/monitoring/gen-dashboard/registry`, `<c>/monitoring/observascope-oss/{ldap,objstore,slack-api-urls}`, `<c>/monitoring/headlamp/headlamp-oidc`). NOT template-fixable — seed in Vault/SM **before** first sync. observascope-oss is the keystone (it provides the CRDs); seeding its 3 secrets (or disabling unused ldap/slack) cascade-unblocks the rest.

### 6b. Failed hooks (app Synced+Healthy but Operation=Failed)
```bash
kubectl --context iac-hub get application <app>-<c> -n argocd -o jsonpath='{.status.operationState.phase}'   # Failed?
```
Patterns: gen-dashboard PreSync ExternalSecret 404 (registry path); smoke-test empty URL; stale failed Job (`kubectl delete job <app>-smoke-test -n <ns>`). See [[argocd_post_onboarding_failed_hooks]].

### 6c. Pod-level on the private spoke (temp endpoint open → REVERT)
Only with the project SSO admin, and only if hub app-status isn't enough:
```bash
MYIP=$(curl -s https://checkip.amazonaws.com)
aws eks update-cluster-config --name <c> --region <r> --profile <proj> \
  --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs=${MYIP}/32   # ~5-10 min
# wait Successful, then:
aws eks update-kubeconfig --name <c> --region <r> --profile <proj> --alias <c>-spoke
kubectl --context <c>-spoke get pods -n monitoring -o wide   # find Pending/ImagePull/CrashLoop
kubectl --context <c>-spoke describe pod <p> -n <ns> | sed -n '/Events:/,$p'   # FailedScheduling reason
# !!! ALWAYS REVERT:
aws eks update-cluster-config --name <c> --region <r> --profile <proj> --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true
```
zsh note: don't store the kubectl invocation in a var (`$K get ...` is NOT word-split in zsh → "command not found"); write `kubectl ...` literally. `timeout` is not on macOS — use `kubectl --request-timeout`.

## 7. Sign-off checklist
- [ ] account correct, all Atlantis projects applied (0 destroy)
- [ ] TGW Active, DNS resolves
- [ ] EKS ACTIVE, node groups ACTIVE (health []), ebs-csi ACTIVE, RDS available, MSK ACTIVE
- [ ] Cognito = 1 pool, SAML metadata URL returns 200
- [ ] **ArgoCD N/N apps Synced+Healthy**, no failed hooks
- [ ] API endpoint back to **private** (if you opened it for §6c)
- [ ] (toolchain/Ansible) only if Red Hat Cloud Access + Vault `secret2/data/<proj>` are done — else document as the known external blockers

Related: [[eissaasdev302_axajp_env_state]], [[argocd_fresh_cluster_smooth_install]], [[argocd_post_onboarding_failed_hooks]], skill `argocd-cluster-onboarding` (P6).
