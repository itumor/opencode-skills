---
name: eis-onesuite-phase2-terraform-scaffold
description: >-
  Phase 2 of EIS OneSuite platform provisioning — scaffold a new per-client Terraform
  project from the iac/terraform/template/client Copier template (custom [[ ]] delimiters,
  --vcs-ref v2.0.0), then onboard it to GitLab + the IaC Atlantis webhook. Covers the full
  copier answer set (global_project_code / global_project_name → repo path, lower_region,
  global_domain_name, lower_account_id, the /23 Shared-VPC subnet trap requiring
  lower_infra_auto_calculate=false, the dev /23 lower stage, and the cognito metadata_url
  placeholder), the GitLab subgroup+project creation under iac/projects/aws (group 1724),
  git init+push, atlantis.yaml regeneration via ci/generate-atlantis-projects.sh, and adding
  the GitLab webhook pointing at IaC Atlantis. Use when the user says "scaffold the terraform
  project for <client>", "generate the client IaC repo", "Phase 2 of <ticket>", "create the
  terraform repo and wire Atlantis", "onboard the new client terraform to GitLab/Atlantis", or
  after Phase 1 account vending hands you a 12-digit account ID and you need the repo stood up.
  Complements the template-scoped generate-new-project skill (this is the OneSuite-master-flow
  variant with the locked answer conventions baked in). Sits between eis-account-vending (P1)
  and eis-onesuite-phase3-infra-provision (P3); the master flow is eis-onesuite-platform-provision.
---

# Phase 2 — Terraform client project scaffold + GitLab/Atlantis onboarding

Scaffold a new client Terraform repo from the `client` Copier template, push it to GitLab under
`iac/projects/aws/<client>/terraform`, regenerate the dynamic `atlantis.yaml`, and wire the
IaC-Atlantis webhook so MRs autoplan. This is the OneSuite master-flow Phase 2; it complements the
template-repo skill `generate-new-project` (which is the generic version) by hard-coding the EIS
OneSuite answer conventions and the IaC-Atlantis webhook step.

**Prereqs (from earlier phases):**
- Phase 1 (`eis-account-vending`) done → you have the 12-digit `lower_account_id` and the
  StackSet baseline has created the `aws0iacdeveks01-atlantis-{plan,apply}-Role` so shared IaC
  Atlantis can assume into the new account.
- Phase 0 (`eis-onesuite-phase0-prereqs`) settled: CIDR block allocated, root DNS zone in place,
  IdC SAML metadata URL received (or a placeholder you will fill in before infra/services apply).

**Environment:**
```bash
export GITLAB_HOST=sfo-cvdevopsgit01.eqxdev.exigengroup.com   # internal host; glab targets it
# GITLAB_TOKEN must be set (PAT). copier + glab + git on PATH.
TPL=/Users/eramadan/gitwork/iac/terraform/template/client      # local clone of the template
```

---

## Step 1 — Pin down the answer set

`global_project_name` drives the **repo path** (`| lower | replace(' ', '-')`). Choose it so the path
is what you want: `AXA Japan` → `axa-japan`. `global_project_code` (3–5 lowercase alphanumerics, validated
`^[a-z0-9]{3,5}$`) drives resource names (`aws0<code>deveks01`, `aws0<code>tfstate`, etc.).

> **Preferred path:** don't hand-write the answers — fill the kit's `intake/onesuite.yaml` once and run
> `intake/render-answers.py` (emits the v2 answer file) or `intake/render-and-copy.sh` (renders all 3
> templates). The table below is the manual/verification view of the same keys.

| Answer (v2.0.0 key) | Value (rule) |
|---|---|
| `lower_region` | `us-west-2` (EIS infra always lands in us-west-2 regardless of "Asian region" app wording) |
| `lower_region_code` | `aws0` — **auto-derived** from region; don't supply |
| `global_project_code` | e.g. `axajp` — short, lowercase, `^[a-z0-9]{3,5}$` |
| `global_project_name` | e.g. `AXA Japan` — drives repo path `axa-japan` (NOT the verbose "POC" form, which would yield `axa-japan-poc`) |
| `global_domain_name` | root zone, e.g. `axajp-eis.cloud` |
| `global_master_issue` | the Jira key, e.g. `EISSAASDEV-302` (also fills every `global_*_issue` default) |
| `lower_account_id` | 12-digit vended account ID from Phase 1 (`^[0-9]{12}$`) |
| `global_networkhub_account_id` | `729852324759` (default — keep) |
| `global_argocd_role_arn` | `arn:aws:iam::182399717428:role/-20260211102113018500000002` (default shared EIS ArgoCD — keep) |
| `lower_cognito_url` | IdC SAML metadata URL, or a placeholder like `PENDING-IdC-SAML-metadata-url` (fill before infra/services apply) |

### The `/23` Shared-VPC subnet trap (critical)

The infra-stage auto-subnet calc assumes a **`/22`**: it places TGW subnets at `base+3`. For a
**`/23` Shared VPC** that overflows the `/23` and collides with the Development range. So for a `/23`
infra CIDR you **must** set `lower_infra_auto_calculate: false` and hand-size the subnets inside the block.
The **dev** lower stage `/23` auto-calc is fine (the lower-stage generator is `/23`-aware).

Reference `/23` hand-sizing inside `10.34.128.0/23` (v2.0.0 keys):
```yaml
lower_infra_cidr: 10.34.128.0/23
lower_infra_auto_calculate: false
lower_infra_private_subnets:    # EC2 toolchain fleet, 2 AZs (/25 each = 128 IPs)
  - 10.34.128.0/25              # us-west-2a
  - 10.34.128.128/25            # us-west-2b
lower_infra_tgw_subnets:        # TGW attachment, 2 AZs
  - 10.34.129.208/28            # us-west-2a
  - 10.34.129.224/28            # us-west-2b
lower_stages:                   # copier REPLACES this map wholesale — every stage needs the FULL shape
  dev:
    stage_full: Development
    cidr: 10.34.130.0/23        # /23 auto-calc stays inside this range
    az_count: 2
    pod_cidr: 100.64.48.0/20    # CGNAT, VPC-local, not TGW-routed → safe to reuse across clients
    pod_subnets: [100.64.48.0/21, 100.64.56.0/21]
# eks_service_cidr is GLOBAL in v2 (global_eks_service_cidr, default 10.202.0.0/16) — leave to default
```
> Dev `/23` auto-resolves to: public `10.34.131.0/28`+`.16/28`, private `10.34.130.0/26`+`.64/26`,
> eks `10.34.130.128/26`+`.192/26`, tgw `10.34.131.208/28`+`.224/28` — all inside `10.34.130.0/23`. ✓
> `create_igw=false` is the template default in **both** stages (private model is out-of-box).

**Dev-only lower stage:** include just the `dev` key in `lower_stages`. Add `test` later with the
`add-lower-stage` skill (don't pre-seed it). The full toolchain EC2 fleet ships by default in
`infra/services` — no extra answers needed.

Write the answers to a data file so the render is reproducible (or better: generate it with
`intake/render-answers.py` from `onesuite.yaml` — same keys, zero drift):
```bash
cat > /tmp/<code>-copier.yml <<'EOF'
lower_region: us-west-2
global_project_code: axajp
global_project_name: AXA Japan
global_domain_name: axajp-eis.cloud
global_master_issue: EISSAASDEV-302
lower_account_id: "586117079971"
global_networkhub_account_id: "729852324759"
lower_cognito_url: PENDING-IdC-SAML-metadata-url
lower_infra_cidr: 10.34.128.0/23
lower_infra_auto_calculate: false
lower_infra_private_subnets: [10.34.128.0/25, 10.34.128.128/25]
lower_infra_tgw_subnets: [10.34.129.208/28, 10.34.129.224/28]
lower_stages:
  dev:
    stage_full: Development
    cidr: 10.34.130.0/23
    az_count: 2
    pod_cidr: 100.64.48.0/20
    pod_subnets: [100.64.48.0/21, 100.64.56.0/21]
EOF
```

---

## Step 2 — `copier copy` (pin v2.0.0, custom delimiters)

The template uses Copier custom delimiters `[[ ]]` / `[% %]` (HCL-safe — set in `_envops`), so the
rendered HCL keeps its native `${}` / `{{ }}`. **Always pass `--vcs-ref v2.0.0`** (the current released
tag — the kit's intake emits v2 keys, so rendering an older tag with them silently drops every value;
`copier.yaml` has migrations keyed to versions, and an unpinned `HEAD` can drift).

> **History — never render < v1.4.0 (v1.3.0 ships a broken CI); current pin is v2.0.0.** The `.gitlab-ci.yml` commit-msg lint loop in
> v1.3.0 (and earlier) runs `git rev-list` WITHOUT `--no-merges`, so the project's `main`
> pipeline goes RED after every MR merge (the GitLab merge commit `Merge branch … into 'main'`
> fails conventional/jira lint). The template-baseline fix (`--no-merges`, COEXT-105281) first
> tagged in **v1.4.0** (commit `d9621fc`); v1.4.0 also defaults EKS to 1.35 and adds the velero
> baseline. **But on an already-rendered v1.3.0 project the preferred fix is NOT to weaken CI** —
> set `merge_method=ff` (Step 5c) so merges fast-forward and no merge commit is ever created, and
> amend the existing bad merge commit to a conventional+jira subject. axajp hit this (job 1797455);
> the `--no-merges` per-project MR (axajp !3) was **closed/rejected** per user directive ("don't
> change the ci/cd"), and main was fixed on 2026-06-25 via `merge_method merge→ff` + amending the
> merge commit (`af25a93 → e04e175`, both parents kept), pipeline 1734151 green — **no CI change**.
> Full recipe: memory `gitlab_merge_commit_lint_ff_fix`.

> **v2.0.0 IS the current released schema** (was MR !23 / COEXT-105822; now merged + tagged). It reworked
> the template to a level-generic lower/upper schema and added an `upper` (preprod) tier (`enable_upper`,
> core-only; upper services is a WIP scaffold). Every key in this skill is already the v2 name. If you're
> reading an OLD render or doc that uses v1.x keys, this is the rename map (v1 → v2):
>
> | v1.x key | v2.0.0 key |
> |---|---|
> | `project_code` | `global_project_code` |
> | `full_project_name` | `global_project_name` |
> | `domain_name` | `global_domain_name` |
> | `master_issue` | `global_master_issue` |
> | `networkhub_account_id` | `global_networkhub_account_id` |
> | `argocd_role_arn` / `*_issue` | `global_argocd_role_arn` / `global_*_issue` |
> | `region` / `region_code` | `lower_region` / `lower_region_code` |
> | `account_id_default` | `lower_account_id` |
> | `infra_cidr` | `lower_infra_cidr` |
> | `intra_auto_calculate` | `lower_infra_auto_calculate` |
> | `cognito_application_url` | `lower_cognito_url` |
> | _(new)_ | `enable_upper` + `upper_region` / `upper_account_id` / `upper_share_cidr` / `upper_stages` + `global_eks_service_cidr` |
>
> `lower_stages` is unchanged. The v2 `copier update` migration (`ci/migrations/v2_prefix_and_freeze.sh`) renames keys and freezes existing stage subnets so live VPCs are never re-subnetted. Full detail + copier-TF MR review gotchas: memory `iac-client-template-v2-review`.

```bash
DEST=/Users/eramadan/gitwork/iac/projects/aws/axa-japan/terraform
copier copy --vcs-ref v2.0.0 --data-file /tmp/axajp-copier.yml "$TPL" "$DEST"
# (interactive alt: copier copy --vcs-ref v2.0.0 "$TPL" "$DEST" and answer the prompts)
```

Verify the render:
```bash
cat "$DEST/.copier-answers.yml"          # _commit: v2.0.0; lower_region_code auto = aws0
find "$DEST/lower" -maxdepth 2 -type d   # expect: infra/{bootstrap,core,services} + dev/{core,services}
cd "$DEST" && terraform fmt -recursive -check
```

**Sanity checks on the render:**
- `lower/infra/{bootstrap,core,services}` and `lower/dev/{core,services}` exist; the `[% yield … %]`
  literal directory is gone (it expands to one real dir per `lower_stages` key).
- `infra_private_subnets` / `infra_tgw_subnets` emit verbatim in `lower/infra/core/terraform.tfvars`
  (no auto-calc), because `intra_auto_calculate: false`.
- `short_name` auto-renders uppercase (`AXAJP`); infra `stage_full` auto-renders `Shared services`.

---

## Step 3 — Fix the JIRA conventional-lint regex (GOTCHA — do BEFORE first commit)

The repo's `.pre-commit-config.yaml` has a `jira-conventional-lint` commit-msg hook whose regex only
allows a fixed set of Jira project keys. If your project key isn't in it, **every commit fails CI**:

```python
pattern = r"^(feat|fix|chore|docs|refactor|test)\(.*\): (COEXT|GENESIS|NOJIRA|EISSAASDEV)-\d+ - .+"
```

Add your project key (the prefix of `master_issue`, e.g. `EISSAASDEV`) to the alternation **in two
places**:
1. In the **generated repo**: `<DEST>/.pre-commit-config.yaml`.
2. **Upstream in the template** so future clients with this key don't hit it again:
   - `terraform/template/client/.pre-commit-config.yaml`
   - `terraform/template/client/.pre-commit-template.yaml`

```bash
# both files, both repos — add | EISSAASDEV (or your key) to the alternation:
#   (COEXT|GENESIS|NOJIRA)  →  (COEXT|GENESIS|NOJIRA|EISSAASDEV)
```
> Note: `ci` is **not** in the allowed conventional-commit type list — use `chore(ci): …` for the
> regex-update commit, not `ci(ci): …`. (Reference run: commit `chore(ci): EISSAASDEV-302 - allow
> EISSAASDEV jira project in commit-msg lint`.) The upstream template change is a separate small MR
> via skill `gitlab-fleet-mr-propagation` if you want it reviewed; for the client repo just commit it.

---

## Step 4 — Regenerate `atlantis.yaml` + run pre-commit

`atlantis.yaml` has a dynamic block rebuilt by `ci/generate-atlantis-projects.sh`. A pre-commit hook
(`validate-atlantis`) fails the commit if the block drifts, so regenerate it now:

```bash
cd "$DEST" && ./ci/generate-atlantis-projects.sh
```

Execution-order math: `(STAGE_IDX*10) + STATE_IDX`, stages `infra(1) → dev(2) → test(3)`, states
`bootstrap(1) → core(2) → services(3)`. **Lower stages render core+services only — NO bootstrap**
(the dev state bucket is created in `infra/bootstrap`). Expect exactly **5 projects**:

| Project | dir | execution_order_group |
|---|---|---|
| lower-infra-bootstrap | lower/infra/bootstrap | 11 |
| lower-infra-core | lower/infra/core | 12 |
| lower-infra-services | lower/infra/services | 13 |
| lower-dev-core | lower/dev/core | 22 |
| lower-dev-services | lower/dev/services | 23 |

Then lint (`verify-iac-changes` skill on changed files is fine too):
```bash
cd "$DEST" && pre-commit install && pre-commit run --all-files
```

---

## Step 5 — Create the GitLab subgroup + project (glab)

The parent group `iac/projects/aws` has **group id 1724**. Create the client subgroup under it, then
the `terraform` project inside the subgroup.

```bash
export GITLAB_HOST=sfo-cvdevopsgit01.eqxdev.exigengroup.com

# 5a. client subgroup under iac/projects/aws (parent 1724)
glab api -X POST groups -f name="axa-japan" -f path="axa-japan" -f parent_id=1724
# capture the new subgroup id from the response (reference run: id 1992)

# 5b. terraform project inside the subgroup
glab api -X POST projects \
  -f name="terraform" -f path="terraform" \
  -f namespace_id=<subgroup_id> \
  -f initialize_with_readme=false
# capture project id (reference run: id 1579)

# 5c. merge method = fast-forward (DO THIS NOW — prevents merge-commit CI reds)
glab api -X PUT projects/<project_id> -f merge_method=ff
```
> GOTCHA (memory `gitlab_module_repo_bootstrap`): `initialize_with_readme=false` leaves `main`
> uninitialized — that's intended; you push `main` yourself in Step 6.
>
> GOTCHA — **merge_method default is `merge`** → every MR merge mints a `Merge branch '…' into 'main'`
> commit whose first line is NOT conventional. The template CI commit-msg loop validates every commit
> in `rev-list ${CI_COMMIT_BEFORE_SHA}..${CI_COMMIT_SHA}`, so **main goes red after EVERY merge**
> (job 1797455, axa-japan MR !1). Setting `merge_method=ff` (5c) makes merges fast-forward — no merge
> commit, no recurrence — without weakening CI. **User directive: fix the commit / use `ff`, do NOT
> add `--no-merges` to the lint loop here.** See memory `gitlab_merge_commit_lint_ff_fix`.

---

## Step 6 — git init + push main

The template ships with a `.git` (the copier clone); start a clean history in the dest. Add the
**SSH** remote on port **:2224** (the internal host's git SSH port):

```bash
cd "$DEST"
rm -rf .git
git init -b main
git add -A
git commit -m "feat(terraform): EISSAASDEV-302 - initial scaffold from client template v2.0.0"
# the regex-fix commit from Step 3 if not already in:
#   git commit -m "chore(ci): EISSAASDEV-302 - allow EISSAASDEV jira project in commit-msg lint"
git remote add origin ssh://git@sfo-cvdevopsgit01.eqxdev.exigengroup.com:2224/iac/projects/aws/axa-japan/terraform.git
git push -u origin main
```
> The CI pipeline kicks off on push. MRs are reviewed by **Markuss (mzivarts)** for terraform/iac.
> Don't merge-first; Atlantis applies before merge (memory `feedback_atlantis_apply_before_merge`).

---

## Step 7 — Add the IaC-Atlantis webhook (so MRs autoplan)

Atlantis on EIS is **not an allowlist** — each repo needs a GitLab webhook pointing at the shared
IaC Atlantis endpoint. The URL is the same across all IaC-Atlantis repos; copy it from any existing
one (e.g. `network-hub`):

- **URL:** `https://atlantis-iac.dev.aws0.iac.aws.eislab.cloud/events`
- **Events:** Merge Request + Note (comment) + Push
- **SSL verification:** ON
- **Secret:** the GitLab webhook secret the IaC Atlantis validates against — pulled from **AWS
  Secrets Manager**, the secret backing the IaC Atlantis `atlantis-vcs` ExternalSecret, key
  `gitlab_secret` (path `…/atlantis/atlantis/atlantis-vcs`). Read it with creds for the eis-iac /
  ArgoCD account:

```bash
# fetch the webhook secret (gitlab_secret) from Secrets Manager
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id 'secret2/data/rnd/cicd/3.0/aws0iacdeveks01/atlantis/atlantis/atlantis-vcs' \
  --query SecretString --output text --profile <eis-iac-or-argocd-profile> | jq -r '.gitlab_secret')

export GITLAB_HOST=sfo-cvdevopsgit01.eqxdev.exigengroup.com
glab api -X POST "projects/iac%2Fprojects%2Faws%2Faxa-japan%2Fterraform/hooks" \
  -f url="https://atlantis-iac.dev.aws0.iac.aws.eislab.cloud/events" \
  -f token="$SECRET" \
  -f merge_requests_events=true \
  -f note_events=true \
  -f push_events=true \
  -f enable_ssl_verification=true
```
> If you can't read the SM secret directly, ask Markuss to create the webhook (he did it in the
> reference run). The exact `…/atlantis/atlantis/atlantis-vcs` path/key is the canonical source —
> do NOT mint a fresh secret, it must match what IaC Atlantis already validates.

Verify the hook landed:
```bash
glab api "projects/iac%2Fprojects%2Faws%2Faxa-japan%2Fterraform/hooks" \
  | jq '.[] | {id, url, merge_requests_events, note_events, push_events, enable_ssl_verification}'
# expect url = atlantis-iac.dev.aws0.iac.aws.eislab.cloud/events, all 3 events true, ssl true
```

---

## Step 8 — Follow-ups / hand-off

- Add **Markuss (mzivarts)** as default reviewer for future terraform MRs.
- Onboard **Renovate** per `iac/solutions/renovate` (auto `copier update` MRs when the template tags).
- **Before infra/services apply:** replace the cognito `metadata_url` placeholder at
  `lower/infra/services/terraform.tfvars` with the real IdC SAML metadata URL (Phase 0 item 4). In
  the reference run this was a follow-up commit:
  `chore(infra): EISSAASDEV-302 - wire IdC SAML metadata URL into infra/services cognito`.
- Hand off to **Phase 3** (`eis-onesuite-phase3-infra-provision`): apply `infra` bootstrap=11 →
  core=12 → services=13 via Atlantis (apply goes through IaC Atlantis, not local — the SSO admin
  can't assume `aws0iacdeveks01-atlantis-*-Role`).

---

## Verification checklist

1. `.copier-answers.yml` shows `_commit: v2.0.0`, `lower_region_code: aws0`, `lower_infra_auto_calculate: false`,
   and the hand-sized infra subnets.
2. `lower/` has `infra/{bootstrap,core,services}` + `dev/{core,services}` only.
3. `./ci/generate-atlantis-projects.sh && git diff --exit-code atlantis.yaml` is clean (5 projects,
   exec orders 11/12/13/22/23, no dev bootstrap).
4. `pre-commit run --all-files` passes (regex includes your project key).
5. GitLab: subgroup under group 1724 + `terraform` project exist; `main` pushed; pipeline running.
6. Webhook present on the project → IaC Atlantis `/events`, MR+note+push, SSL on.

---

## Reference run: EISSAASDEV-302 (AXA Japan / axajp)

- Rendered with `copier copy --vcs-ref v2.0.0` into
  `iac/projects/aws/axa-japan/terraform/` — `account_id_default=586117079971`, `/23` Shared with
  `intra_auto_calculate: false` + hand-sized subnets, dev `/23` auto-calc, `fmt` clean.
- `full_project_name: AXA Japan` (→ repo path `axa-japan`); `project_code: axajp`;
  `domain_name: axajp-eis.cloud`; `master_issue: EISSAASDEV-302`;
  `cognito_application_url: PENDING-IdC-SAML-metadata-url` (later wired).
- GitLab: parent group `iac/projects/aws` = **id 1724**; subgroup `axa-japan` = **id 1992**;
  project `terraform` = **id 1579**. SSH remote on `:2224`. Three commits: initial scaffold →
  ci-lint regex (`EISSAASDEV` added) → cognito metadata URL.
- `atlantis.yaml` regenerated → **5 projects** (infra bootstrap/core/services 11/12/13 + dev
  core/services 22/23; no dev bootstrap).
- Webhook **hook id 14** on the repo → `https://atlantis-iac.dev.aws0.iac.aws.eislab.cloud/events`,
  MR+note+push, SSL on, secret = SM `gitlab_secret`. Source URL copied from `network-hub` (hook 13).
- JIRA lint regex already carries `EISSAASDEV` in both the repo and upstream
  `terraform/template/client/.pre-commit-config.yaml` + `.pre-commit-template.yaml`.

Phase map: P0 `eis-onesuite-phase0-prereqs` · P1 `eis-account-vending` · **P2 (this)** · P3
`eis-onesuite-phase3-infra-provision` · P4 `eis-onesuite-phase4-dev-provision` · P5
`eis-ansible-project-template` · P6 `argocd-cluster-onboarding` · P7 `eis-onesuite-phase7-app-handoff`
· master `eis-onesuite-platform-provision`. Generic template-repo variant: `generate-new-project`.
