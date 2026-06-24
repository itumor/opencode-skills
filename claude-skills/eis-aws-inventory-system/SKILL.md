---
name: eis-aws-inventory-system
description: Build, deploy, extend, or debug the GENESIS-427822 org-wide AWS Inventory system on eis-iac (account 182399717428, us-west-2) — the Lambda/Step-Functions collector pipeline → S3 snapshot → Athena history → FastAPI/DuckDB dashboard (Executive + 10 views, Cognito-gated) → Prometheus exporter + Grafana. Use when asked to add a collector/plugin, add a dashboard view or KPI, onboard another AWS account (multi-account), wire Grafana panels, change the Bedrock NL-query, bump/deploy the lambda/dashboard/exporter images, or when a daily inventory run failed. Covers the build→deploy→SFN→verify loop, the multi-account AssumeRole activation, the Grafana dashboard-as-code pattern, and the recurring SSO/VPN/wiki/snapshot-cache gotchas.
---

# EIS AWS Inventory system (GENESIS-427822)

## What it is
Org-wide read-only AWS inventory. Pipeline: **Lambda** (container image, 40+ collector plugins) driven by **Step Functions** (`discover` → Map(`collect` per account) → `publish`), daily via EventBridge → **S3 snapshot** `s3://aws0iac-inventory-snapshots` (`latest/` + `runs/` + `athena/`) → **Athena** history (Glue db `aws0iac_inventory`) → **FastAPI+DuckDB dashboard** (Executive + Overview/Ask/Resources/Accounts/Drift/Health/Compliance/Recommendations/Topology/Teams, Cognito-gated) + **Prometheus exporter** (`eis_inventory_*` gauges) → Grafana. All Helm/ArgoCD on `aws0iacdeveks01`.

## Repos
- **Source (personal):** `/Users/eramadan/gitwork/confluence-project-inventory-personal`, branch `feat/terraform-iac`. `lambda_function.py` (modes discover/collect/publish; `write_snapshot` writes `latest/{inventory,summary,plugin_stats,manager_facts}.json`), `plugins/*.py` (each `list_resources(config, regions, secrets, cache)->(resources, template)`, per-region try/except, **never raises**), `dashboard/{app.py,static/index.html}` (vanilla-JS SPA, `h()` hyperscript), `exporter/app.py`, `terraform/` (local backend, `null_resource` docker build, `locals.tf inventory_actions` IAM, `files/inventory-config.yaml` SSM config).
- **Chart:** `/Users/eramadan/gitwork/iac/argocd/argocd/components/aws-inventory`, branch `feat/aws-inventory-chart`. ArgoCD Application `aws-inventory` (ns `inventory`, auto-sync), values.yaml image tags.

## Deploy loop (do this every change)
1. **`aws sso login --profile iac`** must be fresh. (See gotchas.)
2. **Lambda change** (plugins / lambda_function.py / IAM / SSM config): bump `terraform/terraform.tfvars` `image_tag` + the `VERSION` constant → `cd terraform && AWS_PROFILE=iac terraform apply -auto-approve` (rebuilds+pushes image via null_resource, updates fn + IAM policy + SSM param in one apply).
3. **Dashboard/exporter change:** `docker buildx build --platform linux/amd64 --provenance=false -t <ecr>/aws0iac-inventory-dashboard:<v> -f dashboard/Dockerfile dashboard --push` (ECR login: `aws ecr get-login-password --region us-west-2 | docker login ...`), then bump the tag in chart `values.yaml`, commit chart, `kubectl -n argocd annotate application aws-inventory argocd.argoproj.io/refresh=hard --overwrite`.
4. **Run the pipeline:** `aws stepfunctions start-execution --state-machine-arn arn:aws:states:us-west-2:182399717428:stateMachine:project-resources-inventory --name <uniq>`; poll `describe-execution`; **0-failures gate** = collect Payload `failures:0`.
5. **Load the fresh snapshot now:** dashboard/exporter cache it (`REFRESH_SECONDS=3600`) → `kubectl -n inventory rollout restart deploy/inventory-dashboard deploy/inventory-exporter`.
6. **E2E:** Cognito login (script: GET `/`, submit the hosted-UI form with user `eramadan@eisgroup.com`, hit `/api/*`); exporter gauges via `kubectl exec <exporter-pod> -- python3 -c "import urllib.request;print(urllib.request.urlopen('http://localhost:9090/metrics')...)"`. CTX = `arn:aws:eks:us-west-2:182399717428:cluster/aws0iacdeveks01`.

## Add a collector plugin
New `plugins/<svc>.py` returning `(resources, template)`; each resource `{name, stage, region, ...fields, tags}`. Wrap per-region in try/except (continue on error). For **gated** services emit a status row `{status:'not_enabled'|'access_denied'|'ok', ...}` instead of empty so the UI shows the right pill. Add read perms to `terraform/locals.tf inventory_actions`. The plugin flows into rows, plugin_stats, Athena, exporter, and the cross-account fan-out for free. **Local-test before deploy:** `AWS_PROFILE=iac python -c "import plugins.<svc> as m; print(m.list_resources({'regions':['us-west-2']},['us-west-2'],{},{}))"`.

## Add another AWS account (multi-account) — the engine is ready
`_config_accounts()` reads an `accounts:` key (dict|list) from `inventory-config.yaml`; the SFN Map fans out per-account `role_arn`; `collect()` assumes it when it differs from the running account (`role_arn:""` = ambient eis-iac, no assume); **no ExternalId**. To onboard account N:
1. Create role **`eis-inventory-readonly`** in account N (read-only inline policy + trust = `arn:aws:iam::182399717428:role/project-resources-inventory`, NO ExternalId) — via an **Atlantis MR** to that account's `iac/projects/aws/<env>/terraform/lower/infra/core/` (pattern: `pto-reference/.../inventory_readonly.tf`). Apply approval → mzivarts.
2. eis-iac lambda role already has `sts:AssumeRole` on `arn:aws:iam::*:role/eis-inventory-readonly` (main.tf). 
3. Add the account to `inventory-config.yaml` `accounts:` (`{name, role_arn, regions, project, stage}`) + dashboard `ACCOUNT_REGISTRY` (app.py + index.html). Until the role exists, that account is an **isolated `assume_role_failed`** — SFN still SUCCEEDS. pto-reference = `468381823127` (cluster `aws0prefdeveks01`).

## Grafana dashboard-as-code
ConfigMap in the chart labeled `grafana_dashboard: "1"` (the kube-prometheus-stack Grafana sidecar runs `searchNamespace: ALL` → finds it in any ns); folder via annotation `eisgroup.com/dashboard-folder`. JSON in `grafana-dashboards/*.json`, `{{ .Files.Get ... | toJson }}`. Verify: `kubectl -n monitoring logs <grafana-pod> -c grafana-sc-dashboard | grep <name>` shows "Writing /tmp/dashboards/...".

## Gotchas (recurring)
- **TF provider vs SSO cache:** when the `iac` SSO token expires the AWS provider errors `SSO session expired` even if the CLI works. Fix = fresh `aws sso login --profile iac`, then plain `terraform apply` (provider + the null_resource's CLI ECR login both work). Do NOT pass `-var aws_profile=""` (breaks the null_resource's `export AWS_PROFILE=`).
- **Confluence/wiki + Jira are VPN-gated:** off-VPN the Jira PAT 302-redirects to SSO and the internal wiki 503s. `_publish_confluence` + `_publish_digest` are **best-effort** (wrapped) so a wiki outage never fails the SFN — the S3 snapshot promotes BEFORE the publish. Post Jira (REST v2, `JIRA_TOKEN` from ~/.zshrc) only when on-VPN.
- **Snapshot cache:** dashboard/exporter read `latest/` every `REFRESH_SECONDS` (3600) → `rollout restart` to see a just-finished run immediately.
- **Bedrock NL-query (`/api/ask`):** Anthropic models are account-use-case-gated → uses **Amazon Nova Pro** (`us.amazon.nova-pro-v1:0`). Backend hard-validates the generated SQL is a single read-only SELECT against table `r` before executing + one-shot auto-repair.
- **Security Hub compliance needs AWS Config ON:** with Config off, standards can't evaluate (only `Config.1` fails) → the scorecard reports `evaluable:false` "enable AWS Config", not 0%.
- **Lambda f-strings:** `lambda_function.py` uses py3.12 f-strings with backslashes (e.g. rds.py:267) — `py_compile` FAILS on local py3.9 but the lambda runtime (3.12) is fine; don't "fix" it.
- **Jira/wiki bypass:** the cloud Atlassian MCP can't reach the on-prem `jira.eisgroup.com`/`wiki.eisgroup.com` — use REST v2 + bearer PAT (see [[jira-eisgroup-datacenter-access]]).

## State / verification
Live waves A–Q. ~656 resources / 30 services / 0 failures; Executive view + 43 collectors + manager_facts + 13 PrometheusRules + Grafana dashboard; Cognito-gated. Keep GENESIS-427822 **OPEN** per the user. Full history + per-wave detail: memory [[genesis-427822-inventory-multiaccount-plan]]. Constraints: play-safe, AdministratorAccess on eis-iac only, reviewable MRs for cross-account.
