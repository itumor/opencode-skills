---
name: eis-agentcore-gateway
description: Use when a ticket asks for an Amazon Bedrock AgentCore gateway (MCP, inbound AWS IAM / SigV4) with a built-in connector such as web-search in an EIS GenAI account - "AgentCore web-search gateway", "web-search gateway for <app>", "same setup as COEXT-110620", "bedrock-agentcore:InvokeGateway for <users>", "post the gateway URL" - or when a plan fails with an unknown `connector` block on aws_bedrockagentcore_gateway_target. Reference run COEXT-113326 (Rate Assistant, EIS GenAi Development 358594315652, 2026-11-24).
---

# AgentCore gateway via eis-bedrock

One consumer MR. The module already has the feature: `eis-bedrock` >= **v2.1.1**, input `agentcore_gateways`. Do NOT use v2.1.0: it creates the gateway, then `CreateGatewayTarget` fails with `ValidationException: Connector configurations must not be empty` (apply-proven 2026-11-24). v2.1.1 sends `parameter_values = "{}"` on each connector configuration and `credential_provider_configuration { gateway_iam_role {} }`; with both, apply succeeded (which of the two the API needs was not isolated).

Unknown API shape? Read a working target first: `aws bedrock-agentcore-control get-gateway-target --gateway-identifier <id> --target-id <id> --region us-east-1 --profile EIS-GenAi` (old account 615299750085, gateway `rate-assistant-web-search-5aoe8mb3ks`, read-only). Mocked `terraform test` and `validate` cannot catch API validation.

## Facts (checked 2026-11-24)
- Module: `git::https://sfo-devopsgit01.eqxdev.exigengroup.com/iac/terraform/modules/aws/eis-bedrock.git?ref=v2.1.1`. Creates gateway (MCP, `AWS_IAM`), execution role `AgentCoreGateway-<name>-ExecutionRole` (trust `bedrock-agentcore.amazonaws.com` + `aws:SourceAccount`), one target per `connectors` entry. Output `agentcore_gateways[key] = {arn,id,url,role_arn,role_name}`.
- Provider: `hashicorp/aws` >= 6.69. 6.62.0 has the gateway resources but NO `target_configuration.mcp.connector` block (schema dumped for 6.62.0 and 6.69.1; versions between untested).
- Region: set `region = "us-east-1"` on the gateway entry. Provider v6 per-resource region; no provider alias (project CLAUDE.md forbids a new provider).
- `connector_version` is required, `major.minor.patch`; its major picks the tool ARN `arn:aws:bedrock-agentcore:<region>:aws:tool/<connector_id>.v<major>`.
- Caller access is NOT in the module. Grant `bedrock-agentcore:InvokeGateway` on the gateway ARN in the consumer.
- Cost: no fixed charge; web search $7 per 1,000 calls (figure from COEXT-110620, not from the Pricing API). Still needs Jira cost approval: Monthly 0, Variable = estimate.

## Consumer pattern (eis-genai-development/terraform, `lower/dev/services`)
```hcl
# terraform.tfvars
bedrock_agentcore_gateways = {
  rate-assistant-web-search = {
    description = "Web search for the Rate Assistant - SigV4 inbound"
    region      = "us-east-1"
    connectors  = { web-search-tool = { connector_id = "web-search", connector_version = "1.2.0", tool_name = "WebSearch" } }
    tags        = { Issue = "COEXT-N", Team = "...", Contact = "...", UseCase = "..." }
  }
}
# in an existing iam_policies entry: one more statement
{ sid = "Invoke<App>WebSearchGateway", actions = ["bedrock-agentcore:InvokeGateway"], agentcore_gateway_keys = ["rate-assistant-web-search"] }
```
`iam.tf` resolves `agentcore_gateway_keys` to `module.bedrock.agentcore_gateways[key].arn` (same way as `inference_profile_keys`). Gateway URL: output `bedrock.agentcore_gateways` after apply.

Expected plan for one gateway + one connector + one policy statement: `4 to add, 1 to change, 0 to destroy`.

## Steps
1. Read the ticket + the reference ticket; list callers (IAM users, SSO group).
2. Find the callers in `terraform.tfvars` (`iam_users`, `iam_policies`). SSO permission sets (`aws_pnt_*`) are NOT in the project repo: ask the Identity Center owner (Aurimas Kerpauskas) which permission set to extend; do not guess.
3. Edit tfvars as above. Check provider pin >= 6.69 and module ref >= v2.1.0; re-lock with the four hook platforms.
4. `pre-commit run --from-ref origin/main --to-ref HEAD`, `diff-risk.py`, push, MR. This Atlantis does not plan Draft MRs: open ready with no reviewer (skill `mr-human-review-gate`).
5. Plan read, `Disruption: NONE` (new resources + in-place policy update), cost approval (skill `cloud-cost-change-approval`), then apply handoff.
6. After apply: gateway URL from the Atlantis apply output (`bedrock.agentcore_gateways[...].url`). E2E: `python3 ~/.claude/scripts/agentcore-gateway-e2e.py --url <gateway url> --profile <profile> [--search "query"]` (SigV4 `tools/list`, optional one billed `tools/call`; `--selftest` offline). Needs a profile whose role may `InvokeGateway` (AdministratorAccess works, ReadOnlyAccess does not). An admin run proves gateway + target + execution role, NOT the service users' or the SSO group's own grant: the requester tests those.
7. SSO group access (`aws_pnt_<team>`): the permission set lives in Identity Center, edited by Markuss Zivarts from the EIS SaaS side (each admin visit there is audited, so ask once with the exact statement). The OpenL set is shared by GenAI dev + PTO tooling, so keep account generic and do not paste account-specific profile ARNs into it. Statement used (2026-11-24): action `bedrock-agentcore:InvokeGateway`, resource `arn:aws:bedrock-agentcore:*:*:gateway/rate-assistant-web-search*`. An ARN with EMPTY region/account segments (`arn:aws:bedrock-agentcore:::gateway/...`) does not match; Slack strips bare `*`, so send ARNs in a code block.

## Traps
- `main` of the consumer moves often (several GenAI tickets share `terraform.tfvars`): fetch + rebase before asking for a plan; a plan can fail with "locked by an unapplied plan from !N".
- Another MR may move users to the module's `model_access` policies; check it does not drop the policy that holds the `InvokeGateway` statement.
- Module tests: under `mock_provider "aws"`, `data.aws_iam_policy_document.*.json` is a random string and `aws_iam_role` rejects it; add `mock_data "aws_iam_policy_document"` with valid JSON.
- Old account 615299750085 is closing and is not IaC-managed. The untracked draft `terraform/modules/aws/eis-agentcore` is superseded by eis-bedrock v2.1.0; do not publish it.
- PR-Agent on project 1647 posted only on a later push (nothing on the first two heads, 2026-11-24): absence is not a pass.
- Commit in a worktree after a module ref change: the `terraform_validate` hook wipes `.terraform` and re-downloads modules while git's commit env (`GIT_INDEX_FILE`) is set; the module clones then overwrite the worktree index ("invalid ref" for every module, `fatal: unable to read <sha>`). Run `terraform init -upgrade -backend=false` in the root BEFORE `git commit`. Repair: `git read-tree HEAD` (object store is intact; `git fsck --connectivity-only` shows 0 missing afterwards).
- A partial apply (gateway created, target failed) leaves the gateway URL in the next plan's output diff; the lock stays on the MR until the fixed plan is applied.
- Reference result: gateway `rate-assistant-web-search-u7x14hw4qr`, MRs eis-bedrock !5 !6 !7, consumer !11 (merged `b16aef8`).

## GenAI request queue (added 2026-11-25)
Where the work comes from and what the team agreed. Details: memory `genai_new_account_outstanding_tickets_sheet.md` and `devops_daily_call_genai_iam_2026_11_24.md`.
- Queue = Google Sheet "Outstanding AWS tickets (GenAI new account)", fileId `1qPAfBmJhNnX1Y65ETUJtI2mzsmmvb5ndiJCxU5M1b24`. Read it live (Drive connector) and check the Jira ticket before taking an item; sheet status text lags.
- Sort the ask first: inference profile only (batch, simple) / profile + own credential / gateway (this skill) / multi-component (AgentCore runtimes, MCP servers, EC2, RDS, ECS: plan it, not a one-MR job).
- Team direction (daily call 2026-11-24, from auto-notes): one inference profile per team per model; service users `svc-<case>[-<env>]-bedrock` (e.g. `svc-rate-assistant-dev-bedrock`), inference profiles `<team>-<model>` (e.g. `openl-claude-sonnet-v4-6`), per Lucid draft a2c5d866 (memory `genai_governance_lucid_diagram_2026_11_24.md`); renaming a live IAM user = replace = new keys, check existing names first; least-privilege inline policy, generated from variables, not copied JSON; keys in Vault; a unified IAM Terraform module is planned, so keep new code easy to move onto it; service-to-service auth = OIDC/IRSA; IAM Roles Anywhere later for on-prem.

## Bedrock profile + service user request (added 2026-11-25, COEXT-112035, MR !14)
Repo `eis-genai-development/terraform`, `lower/dev/services/terraform.tfvars`. Since !12 (COEXT-111874) one block does it all:
```hcl
iam_users = {
  svc-<case>-<env>-bedrock = {
    bedrock_models = { sonnet55 = { model_id = "anthropic.claude-sonnet-5-5", tags = { ModelName = "Claude Sonnet 5.5" } } }
    tags = { Issue = "<KEY>", Team = "<Team>", Contact = "<Name>", Env = "dev", UseCase = "<...>" }
  }
}
```
- Module generates profile `<team>-<model key>-bedrock` (team = Team tag, lower-case, hyphens) and policy `<prefix>-<user>-bedrock-Policy` (get + invoke on the profile, model invoke only via profile condition, read-only list). Do not hand-write Bedrock policies in `iam_policies`; that map is for non-model access only (gateway, Cohere direct).
- Same Team + same model key on two users = one shared profile. Set `name` to keep them apart.
- Plan noise: every other identity's generated policy shows `policy -> (known after apply)` ("N to change"). Apply reported `0 changed`. Real signal = adds and destroys.
- Stale branch trap: this repo moves fast. A branch cut before a sibling merge plans DESTROYS of the sibling's resources (saw `24 to destroy`) while the pipeline is green. Before any apply: `has_conflicts`, head contains `origin/main`, plan shows 0 destroy. Fix by merging main into the branch (no force-push), redo the change in the current structure.
- One MR holds the Atlantis lock on `lower/dev/services`; a second MR's plan fails "locked by pull !N" and the pipeline goes red through the `atlantis/plan` commit status, not through a job.
- After apply (user's steps): access key -> Vault `rnd/cicd/3.0/genai-development/iam/<user>`, record rotation date, post profile ARN in the ticket. SSO permission set for local testing is not in this repo.
