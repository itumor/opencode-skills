---
name: eis-account-vending
description: Vend a new AWS account for an EIS client/POC environment using solutions/account-vending (copier questionnaire + one idempotent vend.py since COINT-21667; legacy Vending.py + StackSet_Management.py) — the "step 0" before scaffolding a Terraform project. Use when the user asks to "vend an account", "create a new AWS account", "onboard a new customer/POC", "account vending", or needs the 12-digit account ID that the generate-new-project / client copier template requires. Also use for "run the account vending e2e tests", "--rename", "wrong prefix/OU after bootstrap", "SSO access pairs". Covers the EIS Org topology, the management-account-only CreateAccount gotcha, account.env setup, the venv requirement, IdC access grant, and the hand-off when you lack management-account creds.
---

# EIS AWS Account Vending

Vending a dedicated AWS account is **step 0** of standing up a new EIS client/POC environment. Its
only output that matters downstream is the **12-digit `account_id_default`** that feeds the
`generate-new-project` skill / client copier template. Tool: `iac/solutions/account-vending`
(`Vending.py` creates+places the account; `StackSet_Management.py` deploys the bootstrap baseline).

Reference run: **EISSAASDEV-302** (AXA Japan POC, `axajp`, 2026-06-17). See memory
`account-vending-org-topology` for the canonical Org facts.

## NEW FLOW (COINT-21667, MR !2 `feat/COINT-21667-single-idempotent-vend`; master after merge) — use this first

Repo root `iac/solutions/account-vending`. User doc = `USER_GUIDE.md`; engineer doc = `RUNBOOK.md`.

**One shot since COINT-21712 (MR !8, merged to master 2026-11-17).** `./vend` no longer stops after the account. For a Lower account one run does: step 0 prerequisites (`python3`, `aws` hard; `git glab pre-commit terraform tflint checkov jq` + VPN named if missing) -> questions + account -> `provision.py` (GitLab project, client template, Atlantis webhook, merge request; asks `Create it now?`) -> `rollout.py accounts/<folder>/account.env --apply` (plan + apply per layer, asks before each).
- Gates stay: apply needs the merge request approved by a non-author; not approved = `Paused, not failed`, rerun `./vend accounts/<folder>` to carry on. `./vend --yes` covers the account only and prints the two follow-up commands. The tools never merge.
- `rollout.py` exit codes: 0 done, 3 waiting for approval, 4 merge request already merged, 1 problem.
- Jira issue question is under advanced settings (default `NOJIRA-0`).
- Claude never answers `y` to an `Apply <layer>?` prompt and never runs `rollout.py --apply` (it posts apply comments): that run is the user's, in their Terminal tab. Cost approval in Jira is not checked by the tool.
- Docs: `PROVISION_GUIDE.md`, `ROLLOUT_GUIDE.md`. Wiki: public Step 1-3 pages unchanged; additive drafts under personal page 932185059 (manual text verbatim + "Automated way" section).
- Not proven live: the chain into the layer apply (stand-in tools only). eis-pnt can only plan/apply `lower-infra-bootstrap` (no hub TGW / DNS zone).
```bash
git clone ssh://git@sfo-cvdevopsgit01.eqxdev.exigengroup.com:2224/iac/solutions/account-vending.git
cd account-vending
./vend                          # new account: questions -> preview (dry-run) -> y/N -> create/update -> prints id
./vend accounts/<prefix>-<env>  # rerun same account, no questions (idempotent: update only)
./vend ... --yes                # no confirm (used by e2e E24)
```
- `./vend` builds `.venv` itself (requirements.txt: boto3 + copier), runs `copier copy` into `accounts/.new-<ts>`,
  renames to `accounts/<prefix>-<env>` (refuses if exists), logs in (`aws sso login --profile` if sts fails).
- Questions (manager calls 2026-10-30): customer (max 44), project prefix (`^[a-z0-9]{3,5}$`), environment
  Lower/Upper, AWS profile (default AdministratorAccess-455655288646), region (default us-west-2), advanced? = no.
  Generated: account name `<customer> <env>`, email `eis-pnt-aws+<prefix>-<env>@eisgroup.com` (AWS max 64,
  slug max 39), OU `SaaS/<env>`, IdC us-east-1.
- Advanced (testing only): org eis|eis-pnt, Jira issue, account name, email slug, IdC region, OU, parent id,
  SSO on/off + pairs `GROUP:name=PermissionSet,...`, role_default.
- EIS default pairs (Markuss 2026-10-27): oc-team=AdministratorAccess, oc-team=ReadOnlyAccess,
  cloud-platform_adm=AdministratorAccess. (devops-support CICDAccess dropped 2026-11-05, 823039a: the
  permission set uses customer-managed policy AWSEKSClusterConsoleReadOnly, created only by client bootstrap TF,
  so on a fresh account it 404s "Not supported policy arn".) Unknown group/set -> warning, skipped.
- EIS org group names END IN `@exigengroup.com` (`GROUP:oc-team@exigengroup.com=...`); plain `oc-team` only
  exists in eis-pnt. Symptom: `Principal 'GROUP:oc-team' not found in Identity Center` -> account vended with NO
  SSO grants (first EIS vend 2026-11-04, fixed fa9903b). Check a name live before using it:
  `aws identitystore list-groups --profile Audit --region us-east-1 --identity-store-id d-90676df1bc
  --filters AttributePath=DisplayName,AttributeValue=<name>` (exact match; `[]` = wrong name).
  Audit cannot list permission sets; read `AWSReservedSSO_<PermSet>_*` IAM role names in a member account instead.
- Fix grants on an already-vended account: `./vend accounts/<folder>` reuses that folder's `account.env`, so edit
  its `IDENTITY_CENTER_ASSIGNMENTS` line first (a changed template default does not reach it), then re-run.
- Testing helpers: `import Vending` runs module-level code that needs `account.env` (exits "account.env not
  found"); import `utils` only, or copy `parse_assignments` (rpartition on `=`).
- Runner auto-granted ONLY in eis-pnt; EIS org = must be in a granted group. CALL_AS=AUTO.
- Guards (exit 1): prefix/BucketSuffix change after bootstrap (unless `--rename` and both buckets EMPTY),
  RoleDefault change, OU move after bootstrap (auto-deployment would delete the stack), taken bucket name.
- Lower-level: `python3 vend.py accounts/<slug>/account.env [--dry-run|--rename]`; old hand-written account.env works.
- Recovery of a broken bootstrap: `CleanupStackSet.py --yes`, `DirectCleanup.py --yes` with a profile INSIDE the
  account, then `vend.py`. Cleanup refuses blank ACCOUNT_ID (blank after `copier recopy`; run vend.py first).
- Fix answers: `.venv/bin/copier recopy --trust -d k=v accounts/<slug>`; advanced answers need `-d advanced=true` too.
- Prove a branch's copier default with `copier copy --trust --defaults --vcs-ref=HEAD -d customer=.. -d project_prefix=.. -d environment=.. <abs path> <out>`; without it copier uses the latest tag (old template, no account.env).
- Releases: default branch is `master`; `v1.0.0` (2026-11-05) sits on pre-!2 master `ef7d35c` (stale); `v2.0.0` = master `6b7927d` (!2 merged, current). Tag a new version after each merge (ask user for the number), never move a pushed tag. Agent cannot push tags (deploy-guard denies it): create the tag locally with literal `git -C <path>`, hand the user the push line.
- Cosmetic: copier prints "No git tags found" + DirtyLocalWarning at start (local untagged template). Harmless.
- Tests: `python3 vend.py --selftest` (stubbed); real E2E `tests/e2e.py` ONLY in eis-pnt (24 cases, ~12 min,
  report accounts/e2e/report.md) — login + command in memory `eis_pnt_org_vending_testbed`.
- First real EIS-org vend: Markuss or Aurimas (mgmt 455655288646 admin), `--dry-run` first.
- Selling it: manager wants "clone, one command, answer questions, done" — no copier/python knowledge in user doc.

### Read-only E2E of the flow or its docs (no account created) — proven 2026-11-06/09 (COINT-21710)
1. Fresh clone into scratch (never the shared checkout); `git describe --tags` = the documented tag.
2. `python3 vend.py --selftest` (system python3 works; it uses .venv).
3. Answers from a file (avoids flaky TTY prompts, see memory `expect_driving_copier_prompt_toolkit`):
   `copier copy --trust --defaults --quiet --data-file a.yml "$PWD" accounts/<folder>`; check `account.env` (name, email, OU, `@exigengroup.com` pairs, SSO_REGION).
4. Preview + confirm path: `echo n | ./vend accounts/<folder>` -> "Nothing changed". Never send `y`.
   - EIS org without mgmt creds: `aws_profile: Audit` -> `DELEGATED_ADMIN` preview (create would fail).
   - eis-pnt as mgmt (`SELF`): `advanced: true` + `org: eis-pnt` + `aws_profile: pnt-mgmt` with scratch `AWS_CONFIG_FILE` (`[sso-session eis-pnt]` https://eis-pnt.awsapps.com/start us-west-2 + profile 317401331042/AdministratorAccess); user approves `aws sso login --sso-session eis-pnt`.
   - Re-run proof: data file for existing test account `vendtest-coint21667` (prefix vtst) -> `Account exists`, `already in the target OU`, `Already assigned`, StackSet `exists -> update`.
5. The create step (Step 5) needs a real account: EIS = mgmt admin only (Markuss/Aurimas); eis-pnt = ask the user (account must later be closed by hand).
Wiki drafts + publish workflow: memory `coint21710_account_vending_wiki_drafts_2026_11`, `feedback_wiki_docs_personal_draft_first`. Re-sync the "Automated way" part of a draft to current `origin/master` code (manual part untouched): `~/.claude/scripts/wiki-draft-swap-auto.sh <pageId> <expectedVersion> <auto.html> [--dry]`; recipe in memory `feedback_wiki_drafts_additive_keep_manual`. Drafts: overview 932185107, Step 1 932185109, Step 2 932185066, Step 3 932185067. Check claims against code, not the repo guides (cost approval is only a printed reminder; MR approval is checked before the first plan; the tool calls the layer rollout "step 4", the wiki calls it Step 3).

Sections 0-7 below = legacy two-script flow (still works with old env files).

## 0. The one gotcha that blocks everyone — read first

`organizations:CreateAccount` is **management-account-only** (`455655288646`). It is **NOT**
delegatable:

- The `Audit` profile (`582420404993`) is the Org **delegated-admin** — it CAN read the org
  (`list-roots`, list OUs/accounts) but `CreateAccount` returns **`AccessDeniedException`**.
- A normal engineer's SSO has **no AdministratorAccess on `455655288646`**
  (`GetRoleCredentials → ForbiddenException: No access`).

So **you (likely) cannot create the account yourself.** Two real paths:
1. Run the whole flow from a **management-account (`455655288646`) admin profile** (`CALL_AS=SELF`).
2. **Hand off**: stage everything (below), then Slack/ask whoever holds mgmt-account admin to run the
   two commands with your `account.env`. They reply with the new `ACCOUNT_ID`; you resume at
   `generate-new-project`.

Do the read-only discovery + staging as the `Audit` delegated-admin regardless — only the final
`Vending.py` create needs mgmt creds.

## 1. Discover the target OU (read-only, via `Audit`)

EIS Org `o-kthbmcbbdg`, root `r-mgtl`. New lower-env client accounts go in **`SaaS / Lower`**.

```bash
aws organizations list-organizational-units-for-parent --parent-id r-mgtl --profile Audit \
  --query 'OrganizationalUnits[].{Name:Name,Id:Id}' --output table          # → SaaS = ou-mgtl-qjjf0akp
aws organizations list-organizational-units-for-parent --parent-id ou-mgtl-qjjf0akp --profile Audit \
  --query 'OrganizationalUnits[].{Name:Name,Id:Id}' --output table          # → Lower = ou-mgtl-10u4x9xu
aws organizations list-accounts-for-parent --parent-id ou-mgtl-10u4x9xu --profile Audit \
  --query 'Accounts[].Name' --output text                                   # confirm no name clash
```
`Vending.py` **verifies** the OU exists (it will NOT create it). Set `OU_NAME=Lower` +
`PARENT_ID=<SaaS ou id>` so the Lower search is scoped under SaaS.

## 2. Pick account name + root email

- **Name**: human-readable, e.g. `AXA Japan` (the account display name; spaces OK).
- **Email**: PERMANENT + globally unique. Convention `eis-pnt-aws+<slug>@eisgroup.com`
  (e.g. Credit Agricole = `+credit-agricole`); some customer accounts use `aws-saas-<slug>@eisgroup.com`.
  Plus-addressing routes to the shared `eis-pnt-aws` mailbox. Confirm the slug with the user — it is
  irreversible.

## 3. Build the venv (mandatory)

System boto3 is ancient (`1.7.84`) and lacks the modern Organizations/sso-admin APIs. Always:
```bash
cd solutions/account-vending
python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt   # boto3>=1.26
```

## 4. Write `account.env`

`account.env` is **gitignored** since **COEXT-105822** (it holds per-run account id/email/profile —
never commit). Scaffold from the tracked template: `cp account.env.example account.env`. A stale
local one may still exist — back it up first (`cp account.env account.env.bak.$(date +%s)`). Then:

```ini
AWS_PROFILE=Audit              # discovery/staging; for the create, swap to a mgmt-account profile
CALL_AS=DELEGATED_ADMIN        # SELF when run from the management account
AWS_REGION=us-west-2
SSO_REGION=us-east-1           # IdC instance region (skips slow autodiscovery)
STACKSET_NAME=eis-terraform-bootstrap
TEMPLATE_FILE=bootstrap-baseline.yaml
PROJECT_PREFIX=<code>          # e.g. axajp → state bucket aws0<code>tfstate
BUCKET_SUFFIX=tfstate          # state bucket = aws<regioncode><prefix>tfstate (regioncode from §4a map)
ACCOUNT_NAME=<Display Name>
ACCOUNT_EMAIL=eis-pnt-aws+<slug>@eisgroup.com
OU_NAME=Lower
PARENT_ID=ou-mgtl-qjjf0akp     # SaaS OU
ROLE_DEFAULT=aws0iacdeveks01-atlantis
ATLANTIS_ROLE_ARN=arn:aws:iam::182399717428:role/aws0iacdeveks01-atlantis-Role
ENABLE_TAGGING=false
ISSUE=<JIRA>
ACCOUNT_ID=                    # filled by Vending.py
ENABLE_IDENTITY_CENTER_ASSIGNMENT=true
IDENTITY_CENTER_PRINCIPALS=GROUP:oc-team,USER:<you>@eisgroup.com
IDENTITY_CENTER_PERMISSION_SETS=AdministratorAccess
```
IdC assignment is **best-effort** (failures are logged, don't block vending) and needs the runner to
also be an IdC admin — it's how `oc-team`/you get AdministratorAccess on the new account for the
Terraform bootstrap. If it doesn't take, grant access separately.

## 4a. Region-code map — non-`us-west-2` accounts (COEXT-105822)

The state-bucket region prefix (`aws<regioncode>...`) comes from **two in-repo copies** that **MUST
match `eis-env-common-utility`'s `aws_region_codes`** (authoritative naming source, all fleet TF
backends derive from it):
- `config.py` → `region_code_map`
- `bootstrap-baseline.yaml` → `Mappings.RegionCodes`

If `AWS_REGION` is missing from these maps (or its code ≠ the module's), the bootstrap StackSet fails
`Unable to get mapping for RegionCodes::<region>::code` **and** the state bucket is misnamed →
doesn't match the Terraform backend. Current authoritative set (module **v2.1.1**, 12 regions):

```
us-west-2=0  eu-west-1=01  us-east-1=02  us-west-1=03  ca-central-1=04  ap-south-1=05
ap-northeast-1=06  eu-west-2=07  us-east-2=08  eu-central-1=09  ap-northeast-3=10  eu-west-3=11
```
(`us-west-2=0` is single-char by legacy convention; rest zero-padded 2-char — mirror exactly.)

**Adding a region not yet in the map**: add it to `eis-env-common-utility` **first** (gets the
authoritative code, cut a module tag), then mirror the *same* entry into both files above. Never
invent sequential codes here — that recreates the bucket-name drift this fix removed. Don't bulk-add
"all AWS regions"; only mirror what the module defines.

## 5. Run (needs mgmt-account creds)

```bash
./.venv/bin/python Vending.py            # create-or-find account, verify OU, move into it, save ACCOUNT_ID
./.venv/bin/python StackSet_Management.py # bootstrap baseline: state bucket aws0<prefix>tfstate + atlantis roles
```
`Vending.py` is non-interactive. `StackSet_Management.py` is **destructive** (deletes+recreates the
StackSet) and prompts for confirmation — pass `--yes` for non-interactive.

## 6. Hand-off template (when you lack mgmt creds)

Slack the mgmt-account holder the staged `account.env` (it's non-sensitive — no keys, auth is via
profile) + the step-3/5 commands, telling them to set `AWS_PROFILE` to their mgmt profile and
`CALL_AS=SELF`. Ask them to reply with the new `ACCOUNT_ID`. EISSAASDEV-302 precedent: handed to
Markuss Zivarts (`mzivarts`).

## 7. Verify + next step

```bash
aws organizations list-accounts-for-parent --parent-id ou-mgtl-10u4x9xu --profile Audit \
  --query "Accounts[?Name=='<Display Name>']" --output table   # account present in SaaS/Lower
```
Then proceed to **`generate-new-project`** with the new `account_id_default`. Note the client
template's `global.tfvars` bootstraps with `role_default=aws0iacdeveks01-atlantis` (the shared IaC
Atlantis role), switching to `aws0<code>atlantis01` only after the toolchain Atlantis host exists.

## Pitfalls
- `CreateAccount` AccessDenied → you're not on the mgmt account (see §0). Not fixable by retry.
- `account.env` not gitignored + a stale one usually present → back it up; don't clobber blindly.
- OU must pre-exist; `Vending.py` won't create it.
- `ACCOUNT_EMAIL` must be globally unique across all AWS; reusing one fails `CreateAccount`.
- System boto3 too old → always venv.
- Non-`us-west-2` region + region absent from the two region-code maps → StackSet
  `Unable to get mapping for RegionCodes::<region>::code` + misnamed state bucket (see §4a).

## Wiki docs for Step 1 (checked 2026-11-09)
Live pages: draft 928030111 (COINT-21710, personal space), old "Step 1: Account Vending" 853151167 (legacy two-script flow, wrong now), Workflow 851742375, Step 2 853151174. Publish = replace 853151167 in place. Before publishing check: (1) Step 2 `role_default` must equal vending `ROLE_DEFAULT` (default `aws0iacdeveks01-atlantis`, a later change is blocked by the guard); (2) Lower and Upper accounts need different project codes (global bucket name `aws{region}{code}tfstate`, dry-run to prove); (3) Workflow page: only the management account can run Step 1, `eu-west-1` = `aws01`; (4) latest tag/date from `git ls-remote --tags origin`; (5) `find_existing_account` matches by name only. Read collapsed wiki sections via `plugins/viewstorage/viewpagestorage.action?pageId=<id>`. Details: memory `vending-wiki-step1-doc-review-2026-11-09`.

## Steps 2+3 after `./vend` and the questions now (COINT-21712, account-vending !8 reworked 2026-11-16, not merged)
- Questionnaire for a **Lower** account: customer, prefix, environment, mgmt AWS profile, region, **Jira issue (default `NOJIRA-0`)**, **/21 CIDR** (aligned or blank), **IdC SAML URL** (blank = placeholder), advanced? Upper: same minus CIDR and URL. New account.env keys: `LOWER_CIDR`, `COGNITO_URL`.
- `./vend` then runs `provision.py <account.env> --confirm --watch` (shows the plan, asks once, creates GitLab project + webhook + first MR, watches checks). `--yes` only prints the command. By hand: `python3 provision.py accounts/<f>/account.env --confirm --watch`; preview: `--dry-run`.
- Defaults/derived: group `iac/projects/aws`; repo name from customer; AWS profile for the webhook value = the profile for account 182399717428 found in `~/.aws/config` (several match -> asked; the user's laptop has 3). Blank CIDR is asked; no terminal -> stops and names it.
- Gaps: provision.py does not run `aws sso login` for that profile (log in first, else it fails at S5 after the pre-commit gates; rerun resumes); Upper refused; after step 3 only `lower-infra-bootstrap` plans on a fresh account, then `rollout.py` layer by layer.
- `./vend` runs copier on the repo's newest TAG: new questions appear only after a new tag on master. Test uncommitted copier.yml changes via an untagged scratch git copy (memory `copier_recopy_answers_gotchas`).
