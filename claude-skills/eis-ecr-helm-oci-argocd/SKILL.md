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

## 5. Next real charts (open)
pyrra, observascope-storage, observascope-minio, metallb (all `genesis-helm` Nexus deps in `components/*`): add names to `helm_chart_ecr_repositories`, push, switch `Chart.yaml` deps to `oci://`; mirror upstream metallb. Nothing else to build. Keep coupled pieces in one MR ([[feedback-one-mr-for-coupled-changes-no-stacking]]).

## Gotchas
- Stop hook `verify-iac-changes` re-reports pre-existing eis-iac findings every turn (shared checkout on another branch); run the full lane on your branch worktree and state why each finding is acceptable.
- zsh: no `$VAR` paths for git in guarded commands; `git worktree add` first, then use the literal path.
- Terminal bash-input events can be replays of old commands: confirm live state (key count/created time, CI var id == live key id) before reacting.
