---
name: eis-account-vending
description: Vend a new AWS account for an EIS client/POC environment using solutions/account-vending (Vending.py + StackSet_Management.py) — the "step 0" before scaffolding a Terraform project. Use when the user asks to "vend an account", "create a new AWS account", "onboard a new customer/POC", "account vending", or needs the 12-digit account ID that the generate-new-project / client copier template requires. Covers the EIS Org topology, the management-account-only CreateAccount gotcha, account.env setup, the venv requirement, IdC access grant, and the hand-off when you lack management-account creds.
---

# EIS AWS Account Vending

Vending a dedicated AWS account is **step 0** of standing up a new EIS client/POC environment. Its
only output that matters downstream is the **12-digit `account_id_default`** that feeds the
`generate-new-project` skill / client copier template. Tool: `iac/solutions/account-vending`
(`Vending.py` creates+places the account; `StackSet_Management.py` deploys the bootstrap baseline).

Reference run: **EISSAASDEV-302** (AXA Japan POC, `axajp`, 2026-06-17). See memory
`account-vending-org-topology` for the canonical Org facts.

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
