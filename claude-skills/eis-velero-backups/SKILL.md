---
name: eis-velero-backups
description: Use when an EIS EKS cluster was onboarded without Velero (no backup S3 bucket, no velero IRSA role), when bringing Velero "to parity" with CAA, when adding/restoring the velero ArgoCD component, when the velero App is OutOfSync/Missing or BackupStorageLocation is not Available, when a test backup must be proven, or when promoting Velero into the iac/terraform/template/client Copier template so every new cluster gets backups by default. Reference run: EISSAASDEV-302 / aws0axajpdeveks01 (template MR !19, Jira GENESIS-429532).
---

# EIS Velero Backups (per-cluster + template baseline)

Velero on an EIS cluster needs a **triad** that spans two repos. Missing any one → the velero App never goes Healthy.

| Piece | Repo / file | Produces |
|---|---|---|
| S3 bucket | terraform project `lower/<stage>/services` — `terraform.tfvars` `s3` map | `<project_prefix>velero-backups` |
| IRSA role | same project — `eks.tf` `irsa_custom` + `files/iam/eks/velero-aws.json` | `<cluster>-velero-Role`, OIDC-bound to `system:serviceaccount:velero:velero` |
| ArgoCD component | `iac/argocd/argocd` — `clusters/<c>/velero/values.yaml` + `velero:` entry in `cluster-component-config.yaml` | velero App from shared `components/velero` chart |

`<project_prefix>` = `module.env_common_utility.prefix_short` (e.g. `aws0axajpdev`). Bucket = `aws0axajpdevvelero-backups`, role = `aws0axajpdeveks01-velero-Role`.

## Terraform side (mirror CAA `credit-agricole/.../dev/services`)

1. **locals.tf** — velero settings + gate:
```hcl
velero = merge({ enabled = false, bucket_key = "velero-backups", namespace = "velero", service_account = "velero", enable_volume_snapshots = true }, var.velero)
velero_enabled         = try(local.velero.enabled, false)
velero_bucket_key      = try(local.velero.bucket_key, "velero-backups")
velero_namespace       = try(local.velero.namespace, "velero")
velero_service_account = try(local.velero.service_account, "velero")
```
2. **variables.tf** — `variable "velero" { type = any  default = {} }`.
3. **eks.tf** — extend `irsa_custom` (gated, so disabled clusters create nothing):
```hcl
}, local.velero_enabled ? {
  velero = {
    namespace       = local.velero_namespace
    service_account = local.velero_service_account
    policy_file     = "${path.module}/files/iam/eks/velero-aws.json"
    policy_variables = { "bucket_name" = try(module.s3[local.velero_bucket_key].name, local.velero_bucket_key) }
  }
} : {})
```
4. **terraform.tfvars** — add `velero-backups` to the `s3` map (versioning on, AES256) AND a `velero = { enabled = true ... }` block.
5. **outputs.tf** — `velero_bucket_name` + `velero_irsa` (both gated on `local.velero_enabled`), consumed by the ArgoCD values.
6. **files/iam/eks/velero-aws.json** — scoped policy: `s3:ListBucket` on bucket, `s3:Get/Put/Delete/PutObjectTagging/Abort/ListMultipartUploadParts` on `/*`, plus `ec2:Describe/Create/DeleteSnapshot|Volumes|CreateTags` on `*`. `${bucket_name}` is a terraform `templatefile` var (not Copier) — copies through Copier untouched.

Apply via **Atlantis** (`atlantis apply -p lower-<stage>-services`). Expect ~7 to add, 0 destroy (policy + role + role-attachment + bucket + public-access-block + SSE + versioning). Confirm outputs show the role ARN + bucket name.

## ArgoCD side (`iac/argocd/argocd`)

`components/velero` is a shared chart already in the repo. Per cluster you add only:

- `clusters/<c>/velero/values.yaml` — copy from CAA, fix three values: SA annotation `eks.amazonaws.com/role-arn: arn:aws:iam::<acct>:role/<cluster>-velero-Role`, `configuration.backupStorageLocation[0].bucket: <prefix>velero-backups`, region. Keep `features: EnableCSI`, `deployNodeAgent: false`.
- `cluster-component-config.yaml` — `velero:` entry (`namespace: "velero"`, `syncWave: "3"`).

**The ApplicationSet `all-components` creates the velero App only when BOTH the config entry AND the `clusters/<c>/velero/` dir exist.** A commented-out config entry or a missing dir = no App, silently.

Render-audit before MR: `helm template velero components/velero -f components/velero/values.yaml -f clusters/<c>/values.yaml -f clusters/<c>/velero/values.yaml --namespace velero` — pure CREATE (new component, zero prune). MR reviewer = eramadan (argocd routing).

## Verify (proves S3 + IRSA actually work)

```bash
kubectl --context <spoke> -n velero get backupstoragelocation   # PHASE must be Available
velero backup create test-<c>-$(date -u +%Y%m%d-%H%M%S) \
  --include-namespaces monitoring --snapshot-volumes=false --kubecontext <spoke> --wait
aws s3 ls s3://<prefix>velero-backups/backups/<name>/ --profile <p>   # objects landed
```
`snapshot-volumes=false` proves the S3 write + IRSA path fast (the parity goal). BSL `Available` + velero-server `1/1` + backup `Completed` = done. First-sync **OutOfSync is transient** (CRDs settling) — selfHeal converges to Synced; Healthy + server 1/1 is enough to back up.

## Promote to the client template (every new cluster gets backups)

Promote the SAME six terraform pieces into `iac/terraform/template/client/lower/[% yield ... %]/services/` (plain HCL — no Jinja needed; the IAM JSON has no `[[`/`[%` so it passes through). Make it an **always-on baseline**: `velero = { enabled = true ... }` in template tfvars, with `var.velero` opt-out (`velero = { enabled = false }`). **No new Copier question** — `var.velero` defaults to `{}`. Add a Common-tasks opt-out row to the template `CLAUDE.md`. Validate with `bash ci/mock-test.sh` (fmt + Checkov + hooks). Merge cuts a minor template tag → Renovate fans out `copier update` (additive: new bucket + role, no destroy). Template MR reviewer = **Markuss (mzivarts)**; CAA already carries identical inline velero → its update 3-way-merges clean.

## Gotchas

- **checkov CI (`scripts/ci/checkov-helm.sh`) runs `--soft-fail`** — policy failures (CKV_K8S_*) do NOT block; only **preprocessing `errors`** (helm-repo-add / `helm dependency build` failures) block. The velero/metrics-server `chart requires kubeVersion >=1.31 incompatible with v1.29.0` line is a **soft-fail WARNING, not counted** (checkov renders at its default v1.29; velero is simply left unscanned, same as long-merged metrics-server). When checkov fails, grep the trace for the single `[ERROR]` line — a transient `istio-base` helm-repo-add to `istio-release.storage.googleapis.com` is a common network blip → **retry the checkov job** (it added fine in `render_manifests` moments earlier).
- **Cannot skip checkov.** `merge_status: ci_must_pass` is a branch/group protection that overrides project `only_allow_merge_if_pipeline_succeeds=False`. Cancelling the job makes the pipeline red (`canceled` ≠ `success`) → still blocked. The only path is a **green** pipeline; retry checkov, don't cancel.
- **`glab api` defaults to gitlab.com** (whose OAuth token expires → `Token is expired` / malformed JSON). Always `export GITLAB_HOST=sfo-cvdevopsgit01.eqxdev.exigengroup.com` for `glab api`, or run from inside the repo dir (glab infers host from the remote). SSH push is unaffected (key-based).
- **Retry tracking:** after a job retry, the jobs API returns multiple same-named jobs — select the **max id** to read the live status, not `[0]`.
- See [[argocd-cluster-onboarding]] (Phase 3 velero bootstrap-vs-appset collision note, Phase 4 backups), [[eis-secret-and-irsa-conventions]] (IRSA naming), [[feedback-mr-reviewer-routing]] (argocd→eramadan, terraform/template→Markuss).
