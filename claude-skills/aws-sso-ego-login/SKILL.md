---
name: aws-sso-ego-login
description: Use when an AWS CLI call fails with "The SSO session associated with this profile has expired", "Token for <session> does not exist", or "Error loading SSO Token", or when the user says "aws sso login", "refresh SSO", "log me in to AWS", "use ego lite for SSO". Logs the CLI in to IAM Identity Center by approving the request in ego lite (ego-browser) - no password typed or stored by the agent.
---

# aws-sso-ego-login

One command does the login:
```bash
~/.claude/scripts/aws-sso-ego-login.sh --sso-session eis-idc --profile PTO-Reference
```
It runs `aws sso login --sso-session <s> --no-browser`, opens the printed PKCE authorize URL in an ego-browser task space, clicks **Allow access** on the consent page, waits for `Successfully logged into Start URL`, closes the agent page, then (with `--profile`) proves it with `aws sts get-caller-identity`. Selftest: `--selftest`. `--force` runs the browser flow even when STS already works. Exit 0 = logged in.

## Hard line
- The agent never types, pastes or stores a username or password, not even when the user offers one. If ego shows a sign-in page (portal session expired), the script calls `handOff()`. The user signs in and clicks Allow in ego lite while the script waits (`--wait`, default 300 s).
- Clicking Allow grants SSO permission, so only run this on the user's ask or for a task the user started. The client name on the consent page must be `botocore-client-<session>`; anything else, stop and ask.

## Prerequisite: profile uses an sso-session
Legacy profiles (`sso_start_url` on the profile itself) get no refresh token and expire about every hour. Convert them:
```ini
[sso-session eis-idc]
sso_start_url = https://identitycenter.amazonaws.com/ssoins-7223b6f6cff32a78
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile PTO-Reference]
sso_session = eis-idc
sso_account_id = 468381823127
sso_role_name = AdministratorAccess
region = us-west-2
```
Back up `~/.aws/config` first and ask before editing it; it is persistent config. On 2026-10-19 only PTO-Reference was converted; the other legacy profiles on the same start URL are not yet.

## Page states the script reads (ego snapshot)
| State | Text on page | Action |
|---|---|---|
| consent | "Allow botocore-client-... to access your data?", button "Allow access" | click Allow (also "Confirm and continue" on the device flow) |
| done | "credentials have been shared successfully" | finish; consent already remembered, so no click |
| signin / unknown | username/password form, Ping/AD page, anything else | `handOff()`, user acts, script waits on the aws process |

## Gotchas
- ego scripts don't inherit shell env: the URL is baked into a temp `.mjs` and fed on stdin.
- After `handOff()` the agent has no control until the user gives it back. The script doesn't try to take it back; success is read from the `aws sso login` output.
- `task.finish({ keep })` needs `"all"` or an array, so the script passes `{ keep: [] }`.
- A finished space becomes **user-owned**. A fixed space name then fails the next run with `EGO_TASK_SPACE_NAME_IN_USE`, so the script uses `aws-sso-login-<session>-<timestamp>-<pid>` (fixed 2026-10-19).
- The ego portal session expires too, e.g. overnight. The page is then "Sign in to eis-saas" (`us-east-1.signin.aws`, Username + Next), and the script hands off and waits. The user signs in once in ego lite, and later runs are hands-free until that session expires.
- With `--profile`, the script first runs `aws sts get-caller-identity` and exits 0 if it already works. An `sso-session` refresh token kept the CLI valid about 11 h after one login (00:13 to 11:38 on 2026-10-19), so most runs never open the browser.
- macOS has no `timeout`; the script uses its own poll loops (bash 3.2 safe).
- Subagents' SSO can still expire mid-run if the profile is legacy; see memory `feedback_subagent_aws_sso_expires_mid_run`.

Evidence (GENESIS-447522, 2026-10-19):
- consent branch: manual run clicked Allow.
- done branch: a scripted run went straight to the success page (consent remembered), exit 0, STS `AWSReservedSSO_AdministratorAccess/eramadan@eisgroup.com`.
- signin branch: a scripted run at 11:29 found the expired portal, handed off, timed out after `--wait 120` with nobody signing in, and exited 1 (correct).
- full hands-free run at 11:40 with `--force` after the user signed in to the ego portal: page done, `aws sso login: OK`, STS ok, exit 0.
