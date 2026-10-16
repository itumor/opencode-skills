---
name: eis-ecr-helm-oci-argocd
description: Use when Helm charts must come from private Amazon ECR instead of Nexus (OCI artifacts), when the EKS-managed Argo CD capability must pull an `oci://` chart or chart dependency, or when GitLab CI helm jobs fail on an ECR dependency (`no basic auth credentials`, `helm repo add` on oci://) or GitLab OIDC to AWS returns InvalidIdentityToken. Covers repo creation, chart push, playground wrapper chart, E2E proof, CI login with a pull-only IAM user, key rotation. Reference GENESIS-429536 (iac !27/!28/!29, argocd !467).
---

# Helm charts in ECR for Argo CD capability and GitLab CI

Proven end to end 2026-10-12. Memory: `ecr-helm-charts-argocd-capability-genesis429536`. One MR per layer, playground first (skill `argocd-playground-first`).

## 1. ECR repo (IaC, `projects/aws/eis-iac/terraform/lower/dev/services`)
- Use module `eis-ecr` (`?ref=v1.1.0`) through the list var `helm_chart_ecr_repositories` in tfvars. **One repo per chart, name = chart name, root-level.** Tags are IMMUTABLE: a repeated chart version cannot be pushed, bump it.
- Capability role needs nothing new: `argocd.tf` `ECRRead` on `*` (`enable_ecr_access=true`) already covers same-account pulls. No repository policy.
- MR -> user merges -> fresh `origin/main` worktree -> `terraform plan -target=module.helm_charts_ecr -out=<plan>` must be exactly the expected adds -> hand back `terraform apply <plan>` for the user to run (R1/deploy-guard block local applies; see `harness-apply-guard-gotchas`). Full-stack plan carries unrelated EKS drift, never apply it whole.
- Verify live: `aws ecr describe-repositories` (IMMUTABLE, KMS, scanOnPush), lifecycle policy.

## 2. Push the chart (one-way, ask first)
```bash
helm lint <chart>; helm template t <chart> >/dev/null; helm package <chart> -d <scratch>
aws ecr get-login-password --region us-west-2 --profile iac | helm registry login --username AWS --password-stdin <acct>.dkr.ecr.us-west-2.amazonaws.com
helm push <scratch>/<chart>-<ver>.tgz oci://<acct>.dkr.ecr.us-west-2.amazonaws.com
helm registry logout <acct>.dkr.ecr.us-west-2.amazonaws.com
aws ecr describe-images --repository-name <chart> ...   # artifactMediaType application/vnd.cncf.helm.config.v1+json, tag = version
```
Package into the scratchpad, never the repo. Never print the token.

## 3. Argo CD side: normal playground component flow
- `components-playground/<c>/Chart.yaml` wrapper whose `dependencies:` has `repository: "oci://<acct>.dkr.ecr.us-west-2.amazonaws.com"`; `charts/`, `*.tgz`, `Chart.lock` stay uncommitted (repo convention, repo-server resolves at render). Values: `components-playground/<c>/values.yaml`, `clusters/aws0prefdeveks01/<c>/values.yaml` (subchart values under the dependency name), and `<c>: {namespace, syncWave}` in `cluster-component-config.yaml`. The `playground-components` appset generates `<c>-aws0prefdeveks01` (project `apps-allowed`).
- **No Argo Repository secret and no token refresh**: the capability authenticates to ECR through its role, including for chart *dependencies* (proven). AWS doc "Configure repository access" also lists a standalone-Application form: Helm format (no `oci://`, `chart:` field) vs OCI format (`oci://` + `path: .`). If a 401 ever appears, fallback = Argo Repository `type: helm` + `enableOCI: true` with an ESO `ECRAuthorizationToken` refresh.
- E2E after merge (contexts `iac-hub`, `pref-dev`): app `Synced`/`Healthy`, `conditions` empty, deploy+svc in the target ns. Only allowed nudge: annotate hub `app-of-apps` `argocd.argoproj.io/refresh=hard`. Poll with a script file (loops are guarded), not inline.

## 4. CI (argocd repo scripts/ci/ + .gitlab-ci.yml)
- Helm jobs (`render_manifests*`, `pluto*`, `helm_unittest*`, `checkov-helm.sh`) need the login before `helm dependency build`. Helper `scripts/ci/ecr-login.sh` (sourced, `--selftest`): exact registry allowlist, identity gate (`sts get-caller-identity` must end in the pull user), token into a local var, helm only after the token is fetched, once per job. `oci://` must be skipped in every `helm repo add` loop. Without credentials: warn and `[SKIP]`; with credentials an auth failure is an ERROR.
- Credentials = pull-only IAM user via `eis-iam` v1.0.0 (+ inline policy: `GetAuthorizationToken` `*`, pull actions on the chart repo ARNs from `repository_arns`), key minted OUT of band (never in state), masked **unprotected** project vars `ECR_PULL_AWS_ACCESS_KEY_ID` / `ECR_PULL_AWS_SECRET_ACCESS_KEY`. Rotate with `bash ~/.claude/scripts/rotate-ecr-pull-key.sh` (`--dry-run`, `--selftest`); never hand-roll create/delete loops (see `feedback-destructive-snippets-self-guard-terminal-replays`). `glab variable update` not `set` (`glab-variable-set-vs-update-and-api-returns-values`).
- **GitLab OIDC -> AWS does not work here** (`InvalidIdentityToken`, issuer internal DNS only; memory `gitlab-oidc-aws-invalid-identity-token`). An OIDC role exists (`aws0iacdevgitlab-argocd-ci-ecr-pull`) but is unusable until GitLab admins publish the issuer/JWKS. Test any future attempt with a throwaway probe MR (`id_tokens` + `assume-role-with-web-identity` + `get-caller-identity`), not by guessing.
- Prove CI with the pipeline traces (grep `[ECR]`, `[RENDER] <c>`, `Errors`), and check the merged tree equals the commit whose pipeline passed.

## 5. All chart repos + push access for another team member (iac !30, applied 2026-10-13)
- Repos for every chart in `helm_chart_ecr_repositories`: `helm-guestbook`, `metallb`, `observascope-{eis,exporters,logging,minio,oss,storage}`, `pyrra`. Ranking and what is hand-vendored: memory `argocd-chart-ecr-migration-candidates` (Tier 1 = observascope-* team charts + pyrra + observascope-storage).
- Pull for Argo CD (capability `ECRRead *`) and CI (pull user + OIDC role) follows the list. **Policy ARNs must be built from repo names** (`local.helm_chart_ecr_repository_arns`), not `module...repository_arns`, or growing the list fails plan with `Invalid count argument` (eis-iam gates its inline policy on `policy_json != null`). Keep the `check` block.
- Push for the publisher, no key from us: managed policy `aws0iacdevhelm-charts-ecr-push` (push + verify, NO delete, immutable tags) + push-only user `aws0iacdevhelm-charts-ci-ecr-push-user` (0 keys; publisher mints into masked + protected vars of their chart pipeline, rotates ~90d). Person route: OPS attaches the managed policy to their Identity Center permission set (EISHELP; no people/groups in Terraform). `aws_iam_policy` is raw with `# eis-raw-ok` (aws_iam_ gap). Hand the publisher: registry login + `helm push <chart>-<ver>.tgz oci://<acct>.dkr.ecr.us-west-2.amazonaws.com`, one push per version.
- Verify live after apply: repos IMMUTABLE/KMS/lifecycle, push policy has no delete action, push user 0 keys, pull role + user list all repo ARNs.

## 6. Keyless CI (BUILT 2026-10-13, preferred; key path kept as an option)
GitLab is an on-prem VM (not on AWS), so OIDC fails; the keyless route is IRSA on a runner inside the hub EKS.
- Pieces: eis-iac !31 (IRSA role `aws0iacdeveks01-gitlab-ci-ecr-pull-Role`, `irsa_custom` entry + `iam/eks/gitlab-ci-ecr-pull.json`), argocd !472 (SA `gitlab-ci-ecr-pull`, `ciEcrPull` values), !474 (project runner component `gitlab-runner-argocd`), !475/!476 (`ecr-login.sh` prefers web identity; jobs `tags: [eks-irsa]`).
- **Do NOT route by the `terraform` tag**: runner #16 (on-prem docker) and #32 (EKS) both carry it; jobs land on either. A project runner (#37, tag `eks-irsa`, untagged off, locked, not protected) is the fix; a Maintainer can create it, editing group-runner #32 tags needs group Owner (403 otherwise).
- This hub is **Secrets Manager-backed** (not Vault): the runner token is secret `secret2/data/rnd/cicd/3.0/aws0iacdeveks01/gitlab-runner-argocd/gitlab-runner-argocd` (keys `runner-token`, `runner-registration-token` empty), created by piping `POST user/runners` -> `aws secretsmanager create-secret --secret-string file:///dev/stdin` so the token is never printed. ESO role already reads `secret2/data/rnd/cicd/3.0/aws0iacdeveks01/*`.
- Runner pod restart keeps the same runner (`Verifying runner... is valid`); a config change rolls the Deployment and kills jobs on THAT pod (shutdown_timeout 0): merge when idle. Probe MR pipelines pushed while the MR is closed do not auto-start: `POST projects/<id>/merge_requests/<iid>/pipelines`.
- Doc: Claude Docs project 8ad17b95-02b3-4766-b52a-2aeff43c0fac ("ECR Helm charts: Argo CD and GitLab CI access") has the diagram, runbook for adding pull/push runners, key option and rotation. The static pull key + 2 CI variables still exist, unused by jobs; deleting them is a separate irreversible step that needs the user's explicit go.
- **Keyless PUSH built and tested 2026-10-13** (test project `eramadan/ecr-helm-guestbook-chart`, GitLab id 1634): eis-iac !32 (ECR repo `ecr-helm-guestbook` + role `aws0iacdeveks01-gitlab-ci-ecr-push-Role`: push ONLY on that repo, pull on the chart repos for `helm dependency build`, no delete, trust only SA `iac:gitlab-ci-ecr-push`), argocd !477 (component `gitlab-runner-ecr-push`, SA via `ciEcrPush`), project runner #38 (tag `eks-irsa-push`, locked, **protected**, token in Secrets Manager `.../gitlab-runner-ecr-push/gitlab-runner-ecr-push`). Pipeline 2500896: package + push OK, ECR `ecr-helm-guestbook:0.1.0` media type `application/vnd.cncf.helm.config.v1+json`; re-run logs `[SKIP]` (immutable). Policy simulation: PutImage allowed only on the one repo, delete denied. Order matters: merge+apply eis-iac first, then the argocd MR.
- Gotchas hit: the deploy-guard blocks `git push origin main` (user pushes the first commit of a new project; use `-o ci.skip` so the first pipeline does not run); a pipeline pushed while its MR is closed does not start (`POST projects/<id>/merge_requests/<iid>/pipelines`); after an argocd merge the SA in the `gitlab-runner` app can appear minutes after the new runner app (app refresh lag), so check `kubectl -n iac get sa` before triggering; a watcher grep for "not found" misses kubectl's `NotFound`.
- Docs: Claude Doc (above) + markdown copy `argocd/argocd` `docs/ecr-helm-charts-access.md` (MR !478; the repo `.gitignore` allowlists docs one by one, add `!/docs/<name>.md`). Keep both in sync; the user wants the old zone-style architecture diagram (memory `feedback-architecture-diagram-zone-layout`).
- Diagrams: Claude Doc diagram (zone layout) and a Lucid AWS-icon version https://lucid.app/lucidchart/5be91c12-0af1-47c4-b548-cba238bfce20/view (recipe: skill `lucid-aws-architecture-diagram`). User posts the Jira comment; hand back paste-ready text.
- Pull-key + key variables are KEPT as an option (user decision 2026-10-13); do not delete them without an explicit go.

## Gotchas
- **Vendored charts (pyrra, observascope-*):** if `components/<c>/charts/<dep>/` is committed, Argo renders the vendored copy. Switching only `repository:` to `oci://` is then a CI-only change (`helm dependency build` source), with zero render diff. To really move the chart to ECR, also delete the vendored dir in the same playground MR, then prove Argo fetched from ECR (app Synced/Healthy, render diff = 0). Check first: `git ls-tree -r --name-only origin/main components/<c>/charts | head`.
- **Source tgz from Nexus `genesis-helm`:** anonymous = 401. The user logs in themselves with `helm repo add genesis-helm https://sfoeisgennexus05.eqxdev.exigengroup.com/repository/genesis-helm --username <u> --force-update` (hidden prompt; never `--password-stdin` in the terminal pane: it echoes and waits for Ctrl-D). Curl `.../repository/genesis-helm/index.yaml` first: on 2026-10-14 the login timed out (`context deadline exceeded`). Fallback: `helm package` the vendored dir and say the digest differs from Nexus.
- Stop hook `verify-iac-changes` re-reports pre-existing eis-iac findings every turn (shared checkout on another branch); run the full lane on your branch worktree and state why each finding is acceptable.
- zsh: no `$VAR` paths for git in guarded commands; `git worktree add` first, then use the literal path.
- Terminal bash-input events can be replays of old commands: confirm live state (key count/created time, CI var id == live key id) before reacting.
- The user's default AWS credentials are a stale static key: always `--profile iac` (SSO) for ECR login; guards block reading the credentials file.
