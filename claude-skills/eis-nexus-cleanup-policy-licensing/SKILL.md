---
name: eis-nexus-cleanup-policy-licensing
description: Use when a per-customer EIS Nexus (docker_compose_nexus role) needs cleanup/retention policies and it's unclear whether that's possible without a Pro license — "add cleanup policies to proxy/staging repos", "Ansible only does cleanup for licensed nexuses", "Nexus Community Edition cleanup policy", "check if this nexus is Pro or free", or a Nexus repo growing unbounded on a POC/unlicensed instance. Covers the Sonatype Pro-only gate on the whole Cleanup Policies feature (not just advanced criteria), the no-auth edition-detection trick, the role's target-repo naming per project, and the license-vs-custom-script decision tree. Reference: Serhii Maslov Slack ask 2026-07-01, nexus_axajp vs CAA nexus.
---

# EIS Nexus cleanup-policy licensing gate

## What it is
`docker_compose_nexus` (vendored per-project, e.g. `projects/aws/axa-japan/ansible/roles/docker_compose_nexus/`) gates **every** cleanup-policy create + repo `policyNames` attach behind `licensed | bool` (`defaults/main.yml:220-256,271-513`). This isn't the role being lazy — **Sonatype's Cleanup Policies feature (the whole `/service/rest/v1/cleanup-policies` API, not just the `criteriaLastDownloaded`/`criteriaReleaseType` advanced fields) is Pro-only**, confirmed:
- help.sonatype.com/en/cleanup-policies-api.html: *"Only available in Sonatype Nexus Repository™ Pro"*
- Sonatype's Community-vs-Pro feature matrix: red X for Cleanup Policies under Community
- The role's own comment: `# Latest OSS version without limits is "3.76.1"` — versions after that ship the new restricted "Community Edition" tier

**Check which edition a live instance is running WITHOUT any auth/creds** — the login page's asset query strings carry it:
```bash
curl -sk https://<nexus-host>/ | grep -io '_v=[0-9.a-z-]*&_e=[A-Z]*' | head -1
# _e=COMMUNITY  → free tier, Cleanup Policies blocked
# _e=PRO        → licensed, Cleanup Policies work
```
Confirmed live 2026-07-01: axajp (`aws0axajpnexus01...`) = `_e=COMMUNITY` v3.92.3; CAA (`aws0caanexus01...`) = `_e=PRO` v3.91.1.

EIS already owns a **shared Nexus Pro license** in Vault: `secret2/data/cv/identities/cloud_team/software/nexus/pro_license:base64` (the role's `nexus.license` var, `defaults/main.yml:59`) — CAA presumably runs on this. Flipping an unlicensed project to `licensed: true` + copying that license + re-running the role makes cleanup fully automatic (no manual work) — it's a policy/cost decision (how many instances draw on the shared license), not a technical blocker.

## Target repos per project (role naming convention)
For project `<proj>`, cleanup policies attach to (release repos deliberately get `policyNames: []` always — never touch release):
| Format | Proxy repo (literal, upstream Genesis mirror) | Staging repo (templated) |
|---|---|---|
| npm | `gennexus-genesis-npm` | `<proj>-npm-staging` |
| maven | `gennexus-genesis-mvn` | `<proj>-maven-staging` |
| docker | `gennexus-genesis-docker` | `<proj>-docker-staging` |

Vault admin cred pattern: `secret2/data/<proj>/automation/nexus:nexus_AdminPass` (user `admin`), same pattern for `default_proxy_user`/`default_proxy_pass`.

## Decision tree when an unlicensed instance needs retention
1. **Verify edition live** (curl trick above) before assuming — don't trust the `licensed` var in group_vars alone; it can drift from reality (e.g. CAA isn't even wired to this role currently — see Gotcha 3).
2. **If it truly needs to stay unlicensed:** the Cleanup Policies feature is not reachable via UI *or* API — no manual workaround inside that feature. The only options are (a) accept unbounded growth, or (b) a bespoke script against Nexus's Search + Delete-Component APIs (`GET /service/rest/v1/search` + `DELETE /service/rest/v1/components/{id}`), which are NOT license-gated but aren't "Cleanup Policies" in Nexus's own terms — no automatic scheduling, you own the cron.
3. **If licensing is on the table:** flip `licensed: true` in the project's `inventory/group_vars/nexus.yaml`, ensure `nexus.license` Vault lookup resolves, re-run `ansible-playbook playbooks/nexus.yaml --limit <host>` (**must `--limit`**, playbook is `hosts: all`). The role then creates the 3 format policies + attaches them to all 6 target repos automatically — zero manual API calls.
4. Retention values to use: don't just trust the role's 30d/30d default — pull CAA's actual live values first (gear → Repository → Cleanup Policies, or `GET /cleanup-policies`) since that's the tuned reference, not the untouched default.

## Gotchas
1. **UI renders the Create/Edit Cleanup Policy form on Community Edition too** — form fields aren't greyed out just because you're unlicensed. The gate (if any) may only bite on Save/POST. Don't conclude "it works" from the form being visible — confirm an actual save succeeds.
2. **No scheduled Nexus Task is created by this role**, ever — it only creates policies and sets `cleanup.policyNames` on repos (`tasks/init.yml`, loop over `nexus_init`). Whether cleanup then runs automatically (newer Nexus has a background cleanup service) or needs a separate `POST /tasks` (type `repository.cleanup`) wasn't resolved as of this writing — check CAA's Admin → System → Tasks list for a cleanup-related task before assuming either way.
3. **CAA nexus is NOT currently managed by this role at all** — `projects/aws/credit-agricole/ansible/roles/requirements.yml` has no `docker_compose_nexus` entry and no vendored copy exists, despite `playbooks/nexus.yaml` referencing the role. CAA's Nexus (Pro, 3.91.1, extra `raw`-format cleanup policy beyond role defaults) predates/bypasses this automation — treat it as a live reference to copy values FROM, not a role instance to diff against.
4. **This session had no valid Vault token** (`~/.vault-token` expired, non-interactive shell has no `VAULT_TOKEN` env — same class of issue as [[jira_token_location]]) — REST/curl verification needed a human with an interactive Vault login; the UI path (login with the Nexus admin password directly, no Vault) sidesteps this entirely for read/manual-test purposes.

Related: [[onesuite_nexus_hosted_repos]] [[eissaasdev302_axajp_env_state]]
