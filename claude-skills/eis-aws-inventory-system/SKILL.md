---
name: eis-aws-inventory-system
description: Build, deploy, extend, or debug the GENESIS-427822 org-wide multi-account AWS Inventory system — the submodule-based collector (iac/projects/aws/eis-iac/aws-inventory, moving to iac/solutions/aws-inventory) + its hub Terraform stack (iac/projects/aws/eis-iac/terraform/lower/dev/aws-inventory) on eis-iac (182399717428, us-west-2). Use when asked to onboard another AWS account, bump the upstream collector submodule, fix a Confluence-publish bug, change the coverage gate, add/fix a collector plugin, or deploy an image. Covers the build→deploy→SFN→verify loop, the AssumeRole cross-account design, the Confluence self-healing publish model, and the recurring bugs found getting the first live account working.
---

# EIS AWS Inventory system (GENESIS-427822)

## Three systems exist — do not conflate them
1. **`cv-devops/aws-lambda/confluence-project-inventory`** — other team's (smaslov), feeds MAM's 3 CoreVelocity pages daily. Upstream; consumed as a pinned git submodule by #3, never edited directly. Freeze/archive of this repo is explicitly **deferred**, not done.
2. **Legacy predecessor** — `project-resources-inventory` in eis-iac, hand-deployed 2026-06-17, dashboard+exporter+Athena+Grafana+Cognito, single laptop-local Terraform state (`dev/inventory.tfstate`, never in `dev/inventory.tfstate` on the real backend — confirmed 404). Being retired; its EventBridge schedule is still enabled and it was **silently broken for ~15 days** (see Gotchas). See the bottom section for what's still true about it.
3. **THIS is the live system, built 2026-09-10.** Collector code lives entirely in the `upstream` git submodule (pinned tag, bump with `git -C upstream fetch --tags && git -C upstream checkout vX`); the app repo adds only the multi-account orchestration layer (~800 lines: `handler.py`, `accounts.py`, `wiki.py`, `aws_session.py`, a 3-file plugin overlay). No dashboard, no Athena, no Grafana, no Cognito — deliberately lean, publishes straight to Confluence.

"Collector" and "Publisher" are never two separate Lambdas — one Lambda, mode-dispatched (`discover`/`collect`/`publish` via Step Functions), same as the legacy system.

## Repos (system #3)
- **App code + CI:** `iac/projects/aws/eis-iac/aws-inventory` (GitLab project 1613) — **moving to `iac/solutions/aws-inventory`**, blocked on GitLab project transfer needing **Owner** (only `akerpauskas`/`dzvenyhorodskyi` have it on group `iac`; Maintainer is not enough, confirmed via 403 on `PUT /projects/:id/transfer`). `gitlab_ci_project_path` in the hub's `gitlab_ci.tf` already points at the target path, so nothing else needs to change once the transfer lands.
- **Hub Terraform:** `iac/projects/aws/eis-iac/terraform/lower/dev/aws-inventory/` — moved here from inside the app repo on 2026-09-10 to match every sibling stage (`lower/dev/argocd`, `lower/dev/core`). Backend key `dev/aws-inventory.tfstate` in `aws0iacdevtfstate` (migrated from the ad-hoc `dev/inventory.tfstate` via `terraform init -force-copy`; old key left as a safety net, not deleted). `profile = "iac"` — **eis-iac has no Atlantis**, applies are local: `terraform plan -out=tfplan` then `terraform apply tfplan` (never `-auto-approve` — a hook denies it).
- **Modules used:** `eis-lambda`, `eis-step-functions`, `eis-eventbridge` (all new, v1.0.0, created this session — `iac/terraform/modules/aws/<name>`), `eis-inventory-readonly` (v1.1.0 — the spoke-role module and single source of truth for the IAM action list; 37 actions total, rebuilt from real boto3 calls, not the old hand-copied 134). `eis-s3`/`eis-env-common-utility` reused; `eis-ecr` deliberately NOT used (defaults `enhanced_scanning=true`, account-wide Inspector2 side effect).
- **Spoke role:** `eis-inventory-readonly` in each member account, via the shared module. pto-reference (`468381823127`) is live: MR `iac/.../pto-reference/terraform!42`, plan `0 add / 2 change / 0 destroy` (a `moved` block state-migration onto the module, not a replace).

## Architecture
`discover` (Lambda) → **Step Functions Map** (`collect` per account, `MaxConcurrency=10`, `ToleratedFailurePercentage=100`) → `publish` → **CoverageGate** (Choice state) → `Succeed` or `Fail`. S3 bucket `aws0iacdevinventory-snapshots` is the Map→Publish data channel (`raw/<run_id>/<account_id>.json`), not just a snapshot. No dashboard/exporter/Athena — publish writes straight to Confluence, one page per account.

`handler.load_plugins()` loads `upstream/plugins/*.py` then `plugins/*.py` by filename, ours shadowing theirs. Overlay is 3 files (`eks.py`, `rds.py`, `ec2_instances.py`), each an MR owed to smaslov. `dashboard.py`/`thirdparty.py` excluded (MAM-specific, unreachable from a spoke).

## Deploy loop
1. `aws sso login --profile iac`.
2. Fix code in `aws-inventory` repo, add a test, `pytest -q tests/` + `ruff check .` green.
3. `docker buildx build --builder desktop-linux --platform linux/amd64 --provenance=false --sbom=false -t <ecr>:<sha> -f Dockerfile . --push` — **do not use the default `docker-container` buildx builder**, it can't see `docker login` credentials and 403s on `public.ecr.aws` even after a successful login; `desktop-linux` (the plain docker driver) works. Needs `.dockerignore` (excludes `.git`, `terraform/`, `upstream/.git` etc.) or the build context is ~800MB.
4. Bump `image_tag` in `lower/dev/aws-inventory/terraform.tfvars`, `terraform plan -out=tfplan` + `apply tfplan` in that dir.
5. `aws stepfunctions start-execution --state-machine-arn arn:aws:states:us-west-2:182399717428:stateMachine:aws-inventory --input '{}'`, poll `describe-execution`.
6. **Do not trust top-level SUCCEEDED/FAILED alone** — read the `Publish` step's output: `collected_accounts`, `missing`, `missing_count`, `publish_status`. `IncompleteInventory` (missing_count>0) and `PublishFailed` (publish_status=="failed") are both real Fail states now, not silent.

## Onboarding account N
1. In that account's own iac repo, `lower/infra/core/inventory_readonly.tf`:
   ```hcl
   module "inventory_readonly" {
     source = "git::https://sfo-devopsgit01.eqxdev.exigengroup.com/iac/terraform/modules/aws/eis-inventory-readonly.git?ref=v1.1.0"
     trusted_org_id = "o-kthbmcbbdg"
   }
   ```
   Atlantis MR, approval → **mzivarts**. Read the plan: `0 to destroy` is the acceptance bar if migrating a hand-written role via `moved` blocks.
2. Add the account under `accounts:` in the hub's `files/inventory-config.yaml`, bump nothing else — the hub's `sts:AssumeRole` grant wildcards the account and pins the role **name**.
3. Repo-wide `pre-commit run -a` in the spoke repo can fail on debt you didn't touch: a stale `.terraform.lock.hcl` in *any* stage (regen 4-platform: `terraform providers lock -platform=linux_amd64 -platform=darwin_amd64 -platform=linux_arm64 -platform=darwin_arm64`), or `terraform_validate`'s own `-upgrade` bumping provider patch versions repo-wide as a side effect (harmless, but every hook downstream flags "files were modified" — commit the bump).

## Gotchas found getting the first live account working (2026-09-10)
- **`atlassian-python-api` is inconsistent between its own methods.** `create_page(space=...)` but `get_page_by_title(space_key=...)`. Wrong keyword doesn't raise "unexpected keyword" — it silently absorbs into `**kwargs` (the method forwards to a server/cloud impl chosen by URL) and reports the *required* param missing instead, 3 frames down.
- **`get_page_by_title` on Confluence Server/DC never returns a page dict.** It returns the raw content-search response `{"results": [...], "start", "limit", "size"}` — a non-empty dict **even on zero matches**. `if existing:` is therefore always true; unwrap `results` explicitly or every "not found" path silently KeyErrors on `'id'`.
- **Confluence strips `<!-- -->` HTML comments on save.** A page written with comment-delimited sentinels round-trips with the comments gone — confirmed live on a scratch page. Any idempotency design keyed on finding a comment marker will fail on the SECOND run and start stacking duplicate content forever. Use a `<div class="...">` marker instead — verified byte-for-byte durable across writes.
- **Self-heal, don't special-case shapes.** The first version of the marker-replace logic handled two cases (existing marker div; legacy single `<table>` sibling) and left permanent debris beside the marker the moment a THIRD shape appeared (our own unmarked multi-node output from before the div-marker existed). Fix: on every run, strip **everything** after the anchor `<h1>` and insert exactly one fresh div — no case-by-case matching. The guarantee narrows from "don't touch anything not explicitly ours" to "content before the anchor is a human's; everything from the anchor down is fully owned," which is what these auto-created child pages actually need.
- **`config['domain']` / `config['project_name']` are unconditional in several plugins** (`ec2_asg`, `ec2_instances`, `rds`, `eks`) — the old nested per-project config always had them; the new flat schema doesn't. Both only ever build a string (fqdn/url, k8s namespace prefix), so default them to `""` in the config-loading boundary rather than patch each plugin. A generalized AST scan (`config['<key>'] not in {known-defaulted keys}`) catches the *next* one before it ships, not after a real spoke account hits it.
- **Coverage must count rows, not documents.** A denied `AssumeRole` still writes a well-formed `raw/<run>/<account>.json` with `rows: []` — counting documents reports full coverage for a run that collected nothing.
- **Publishing nothing must fail the run.** The legacy system (#2) did `{"status":"ok","accounts":2,"rows":1845,"published":false}` for **15 consecutive days** after a Confluence password expired — every execution reported SUCCEEDED, the pages sat stale, no alarm. `publish_status` (`ok|skipped|failed`) is now tracked explicitly and a `PublishFailed` state fails the SFN execution.
- **`eis-step-functions`/`eis-eventbridge` house modules derive their IAM role name from the stage/bus name by default** — collided with the Lambda's own execution role name (`CreateRole 409` mid-apply) and would have created an account-wide policy literally called `default-sfn`. Always pass an explicit `role_name`.
- **GitLab project transfer (`PUT /projects/:id/transfer`) needs Owner, not Maintainer** — 403 even with Maintainer on the project, its parent group, and the target group.
- **Atlantis: unlocking your own stale MR doesn't retroactively fix an already-posted plan comment.** `atlantis unlock` on the locking MR works, but you must re-comment `atlantis plan` on the blocked MR afterward — the stale "Plan Failed: locked by !N" comment doesn't self-update. A bare `atlantis apply` applies **every** planned project on the MR; if an unrelated sibling project shows real drift (`terraform's own "Objects have changed outside of Terraform"` note), use `atlantis apply -p <project>` to scope it.
- **CI fetching a private `git::` module needs a job-token allowlist entry on the module repo itself**, not the consumer: `POST /projects/<module_id>/job_token_scope/allowlist -F target_project_id=<consumer_id>`. Git **submodules** over a relative URL don't need this (resolved via the consumer's own `CI_JOB_TOKEN`).
- **GitLab OIDC thumbprint = the root CA in the actual TLS chain**, verified live (`openssl s_client -showcerts` → last cert in the chain), not assumed. sfo-cvdevopsgit01's root is GoDaddy G2, not a generic default.

---

## Legacy predecessor (#2) — reference only, being retired

`project-resources-inventory` in eis-iac, hand-deployed 2026-06-17. Dashboard+exporter+Athena+Grafana+Cognito stack, `iac/argocd/argocd/components/aws-inventory` chart on `aws0iacdeveks01`. Its Terraform state (`terraform/terraform.tfstate` in `confluence-project-inventory-personal`, local backend) held ~40 resources and was **never migrated to a real remote backend** — `dev/inventory.tfstate` on `aws0iacdevtfstate` returns 404. Do not build on this system; it is superseded by #3 above.

**Known-broken:** its Confluence publish silently 401'd for at least 15 days before discovery (personal password rotation) while the SFN kept reporting SUCCEEDED — the exact failure mode #3's `publish_status` gate exists to prevent. Its EventBridge schedule (`project-resources-inventory-schedule`) is still enabled; disable it once #3 has fully proven out, per user decision.

**Old deploy loop, if you must touch it:** bump `VERSION` in `lambda_function.py`, let CI build+push, bump `image_tag` in `terraform/terraform.tfvars.json`, apply locally (`profile=iac`, no Atlantis). Dashboard/exporter: `docker buildx build --platform linux/amd64 --provenance=false -t <ecr>:<v> --push`, bump chart `values.yaml`, `kubectl -n argocd annotate application aws-inventory argocd.argoproj.io/refresh=hard --overwrite`.

**Grafana dashboard-as-code (if the chart survives a partial retirement):** ConfigMap labeled `grafana_dashboard: "1"`, folder via annotation `eisgroup.com/dashboard-folder`, template globs `grafana-dashboards/*.json`. Grafana reads **Thanos**, not Prometheus, as its default datasource — query `observascope-oss-thanos-query.monitoring.svc.cluster.local:9090` when testing exprs, and assert series *count*, not just non-emptiness (the `honorLabels:false` default renamed the exporter's own `service` label to `exported_service`, so `sum by (service)` silently returned one bogus series for weeks).

**Other old gotchas, condensed:** Lambda is a container image not a zip — `update-function-code --image-uri`, single manifest only (`--provenance=false --sbom=false`, buildx defaults to a manifest list otherwise). `rds.py`'s f-string with a backslash needs py3.12 to compile (fails under local py3.9, fine on the runtime — don't "fix" it). Bedrock NL-query used Nova Pro, not an Anthropic model (account use-case gating). Jira/Confluence/internal wiki are VPN-gated; the cloud Atlassian MCP can't reach either — REST v2 + bearer PAT only.
