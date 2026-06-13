---
name: fv-cluster-decommission
description: End-to-end playbook for decommissioning a feature-validation stage (fv01/fv03/etc) from the EIS IaC monorepo. Covers cross-state ownership transfer of shared resources (R53 parent zones + IAM policies) to demo, ordered terraform destroy (services → core → bootstrap), S3 versioned bucket purge, R53 stray-record cleanup, and final code-removal MR. Use when an FV stage needs decommissioning per a Jira ticket.
---

# FV Cluster Decommission

## When to use

- A Jira ticket approved to decommission an FV stage (e.g. fv01, fv03)
- The stage has its own `lower/<stage>/` directory in `iac/projects/aws/feature-validation/terraform`
- Cluster is still live with workloads and S3 telemetry data
- **FV does NOT use Atlantis** — all destroys via plain `terraform` CLI

## Critical context: state-vs-code drift on shared resources

FV stages share parent R53 zones (`fv.eisdemo.cloud`, `aws0.fv.eisdemo.cloud`) and one IAM policy (`AWSEKSClusterConsoleReadOnly`). Originally created by fv01 — but state may have been moved to demo with code left unchanged. Verify state before destroying:

```bash
# Check fv01 state for parent zones + IAM policy
aws --profile Feature-Validation s3 cp s3://aws0fv<stage>tfstate/<stage>/core.tfstate - | \
  jq '.resources[] | select(.type=="aws_iam_policy" or (.type=="aws_route53_zone" and (.module|test("route53_zone_main|route53_zone_region"))))'

# Same check on demo state
aws --profile Feature-Validation s3 cp s3://aws0fvdemotfstate/demo/core.tfstate - | jq '...'
```

Three possible states:
1. **Code matches state** (both code+state say demo owns them) → no transfer MR needed
2. **State already transferred, code lags** (state owned by demo, code says fv01 creates) → file MR to fix code only
3. **Nothing transferred yet** (state + code both say fv01 owns) → full transfer with `state rm` + `import`

## Phase 1 — Cross-state transfer (if not already done)

### 1a — Pre-destroy verification

```bash
# Both fv01 and demo backends use same account 207414098330 but different profile names
# fv<stage> backend profile = "fv<stage>"  (must exist in ~/.aws/config)
# demo backend profile = "fv"
# networkhub provider profile = "pnthub" (account 729852324759, must SSO login)

aws sso login --profile pnthub  # required for any FV terraform run
aws sso login --profile fv<stage>  # add to ~/.aws/config if missing
```

### 1b — DNS transfer (parent zones)

If state already has zones in demo but code says false:
- `lower/demo/core/dns.tf`: `create_main_zone = true`, `create_region_zone = true`
- `lower/<stage>/core/dns.tf`: `create_main_zone = false`, `create_region_zone = false`

Plan demo/core — expect tag-drift updates only, NS records may show "must be replaced" due to data-source pessimism (idempotent on apply, same NS values). NO destroys of parent zones.

### 1c — IAM policy transfer (cross-backend)

`terraform state mv` does NOT work across S3 backends with different profiles. Use `state rm` + `import`:

```bash
# Remove from source state
cd lower/<stage>/core
AWS_PROFILE=fv<stage> terraform state rm 'module.iam_policy_eks_cluster_read_only.aws_iam_policy.policy[0]'

# Import into target state
cd ../../demo/core
git checkout <branch-with-uncommented-iam.tf>
AWS_PROFILE=Feature-Validation terraform init -upgrade
AWS_PROFILE=Feature-Validation terraform import \
  'module.iam_policy_eks_cluster_read_only.aws_iam_policy.policy[0]' \
  'arn:aws:iam::207414098330:policy/AWSEKSClusterConsoleReadOnly'
```

> **Often the policy is already in demo state** (double-managed). State rm clears the duplicate, import errors with "already managed" — that's a no-op success.

Verify both states with `terraform state list | grep iam_policy_eks` after.

## Phase 2 — Pre-destroy checks

```bash
# Cluster check
aws --profile Feature-Validation eks update-kubeconfig --name aws0fv<stage>eks01 --region us-west-2 --alias <stage>
kubectl --context <stage> get nodes
kubectl --context <stage> get ns

# S3 bucket sizes
aws --profile Feature-Validation s3 ls s3://aws0fv<stage>observascope --recursive --summarize | tail -3
aws --profile Feature-Validation s3 ls s3://aws0fv<stage>observascope-loki --recursive --summarize | tail -3
```

**ALWAYS confirm with user before destroying** — TruStage clusters can run 200+ days with 50+ services. Get explicit "OK to delete N GB" confirmation.

## Phase 3 — Destroy sequence

### 3a — Scale down log writers FIRST

S3 buckets keep getting new objects from loki/grafana during emptying — race condition. Scale down first:

```bash
kubectl --context <stage> scale -n loki sts --all --replicas=0
kubectl --context <stage> scale -n loki deploy --all --replicas=0
kubectl --context <stage> scale -n monitoring sts --all --replicas=0
kubectl --context <stage> scale -n monitoring deploy --all --replicas=0
```

### 3b — Purge S3 buckets (current + all versions + delete markers)

eis-s3 module does NOT pass `force_destroy=true` to underlying terraform-aws-modules/s3-bucket. Buckets with versioning enabled WILL block destroy with `BucketNotEmpty`. Pre-purge:

```bash
cat > /tmp/empty_bucket.sh <<'EOF'
#!/bin/bash
BUCKET=$1
PROFILE=${2:-Feature-Validation}
TOTAL=0
while true; do
  PAYLOAD=$(aws --profile $PROFILE s3api list-object-versions --bucket $BUCKET --max-keys 1000 2>/dev/null | \
    jq -c '{Objects: ((.Versions // []) + (.DeleteMarkers // []) | map({Key, VersionId})), Quiet: true}')
  COUNT=$(echo "$PAYLOAD" | jq '.Objects | length')
  if [ "$COUNT" = "0" ]; then echo "DONE $BUCKET total=$TOTAL"; break; fi
  aws --profile $PROFILE s3api delete-objects --bucket $BUCKET --delete "$PAYLOAD" --output text > /dev/null 2>&1
  TOTAL=$((TOTAL + COUNT))
  echo "$BUCKET: deleted batch=$COUNT total=$TOTAL"
done
EOF
chmod +x /tmp/empty_bucket.sh
/tmp/empty_bucket.sh aws0fv<stage>observascope
/tmp/empty_bucket.sh aws0fv<stage>observascope-loki
```

> **jq precedence gotcha**: `[(.Versions // [])[] | {K,V}, (.DeleteMarkers // [])[] | {K,V}]` returns wrong stream because `|` has lower precedence than `,`. Use array addition: `((.Versions // []) + (.DeleteMarkers // []) | map({Key, VersionId}))`.
>
> **Loki bucket can have 38k+ delete markers** from many versions. Empty before destroy.

### 3c — Destroy services

```bash
cd lower/<stage>/services
AWS_PROFILE=fv<stage> terraform init -upgrade
AWS_PROFILE=fv<stage> terraform plan -destroy \
  -var-file=../terraform.tfvars.json -var-file=terraform.tfvars.json
AWS_PROFILE=fv<stage> terraform apply -destroy -auto-approve \
  -var-file=../terraform.tfvars.json -var-file=terraform.tfvars.json
```

Expect ~130 resources. EKS+ALB destroy takes 5-10 min. If S3 errors with `BucketNotEmpty` re-run `/tmp/empty_bucket.sh` then re-apply destroy.

### 3d — Destroy core

```bash
cd ../core
AWS_PROFILE=fv<stage> terraform apply -destroy -auto-approve \
  -var-file=../terraform.tfvars.json -var-file=terraform.tfvars.json
```

Expect ~52 resources. **R53 private stage zone may have stray manually-added records** (e.g. `test.fv01.aws0.fv.eisdemo.cloud A 192.168.0.1`). If zone destroy errors `HostedZoneNotEmpty`, delete the strays manually:

```bash
aws --profile Feature-Validation route53 list-resource-record-sets --hosted-zone-id <ID> \
  --query "ResourceRecordSets[?Type!='NS' && Type!='SOA']"
# Build DELETE change-batch and submit
aws --profile Feature-Validation route53 change-resource-record-sets --hosted-zone-id <ID> --change-batch "$CHANGE"
# Re-run terraform destroy
```

### 3e — Destroy bootstrap (state bucket)

Bootstrap state lives in the bucket it manages — chicken-and-egg. Migrate to local backend:

```bash
cd ../bootstrap

# Backup state first
mkdir -p /tmp/fv<stage>_state_backup
aws --profile Feature-Validation s3 cp s3://aws0fv<stage>tfstate/ /tmp/fv<stage>_state_backup/ --recursive

# Remove S3 backend block, init local
cp main.tf main.tf.bak
python3 -c "
import re
with open('main.tf') as f: c=f.read()
c=re.sub(r'backend\s*\"s3\"\s*\{[^}]+\}\s*', '', c)
with open('main.tf','w') as f: f.write(c)
"
AWS_PROFILE=fv<stage> terraform init -migrate-state -force-copy

# Empty state bucket (still has core/services tfstate files)
/tmp/empty_bucket.sh aws0fv<stage>tfstate

# Destroy
AWS_PROFILE=fv<stage> terraform apply -destroy -auto-approve -var-file=../terraform.tfvars.json

# Cleanup
mv main.tf.bak main.tf
rm -f terraform.tfstate terraform.tfstate.backup
rm -rf .terraform
```

## Phase 4 — Code cleanup MR

```bash
cd <repo-root>
git checkout main && git pull
git checkout -b <TICKET>-remove-<stage>
git rm -rf lower/<stage>/
git commit -m "<TICKET>: Remove <stage> bootstrap, core, and services Terraform configurations"
git push -u origin <TICKET>-remove-<stage>
glab mr create --title "..." --description "..." --source-branch <branch> --target-branch main --no-editor
```

Reference past commit: `0935379 GENESIS-415730` (fv03 decom pattern).

## Phase 5 — Verification

```bash
# No FV<stage> S3 buckets
aws --profile Feature-Validation s3 ls | grep fv<stage>  # empty

# Parent zones survived
aws --profile Feature-Validation route53 list-hosted-zones \
  --query "HostedZones[?contains(Name,'eisdemo')].[Name,Id]"
# expect fv.eisdemo.cloud + aws0.fv.eisdemo.cloud + other-stages

# fv<stage> stage zones gone
dig <stage>.aws0.fv.eisdemo.cloud NS  # NXDOMAIN
```

## Phase 6 — Close out

- Jira: comment with destroy summary + transition to Resolved (custom field `Resources Changed = Cloud resources reduced` required)
- Jira: worklog 8h
- Slack: notify operations lead (wiki page cleanup if you lack access)
- Memory: keep state backup at `/tmp/fv<stage>_state_backup/` for ~1 week

## Related memories

- [[s3_versioned_bucket_purge]] — the jq precedence bug + working script
- [[fv_terraform_setup]] — profile config (fvfv01, pnthub, no Atlantis)
- [[tf_state_cross_backend]] — state rm + import vs state mv
- [[jira_eisgroup_api]] — Bearer auth + required custom fields
