---
name: eis-ansible-project-template
description: Use when scaffolding a new per-customer EIS Ansible project (VM-level config — build hosts, Jenkins, GitLab, SonarQube, Atlantis, Selenoid, Sisense, Keycloak), when the user says "create the ansible project for <customer>", "generate a new ansible repo", "onboard a customer's ansible", "copier copy the ansible template", or when extending/maintaining the iac/ansible/template/client Copier template itself. Also use when an existing generated ansible project needs a `copier update`, or when adding/parameterizing a new customer-specific value into the template. Covers the custom-delimiter rule that keeps Ansible {{ }} intact, per-service enable_* gating, what is vs isn't templated, the GitLab push/CI gotchas, and the E2E parity-vs-CAA validation method.
---

# EIS per-customer Ansible project Copier template

## What it is
`iac/ansible/template/client` (GitLab group `iac/ansible/template`, subgroup id 1717; sibling of `terraform/template/{client,module}`). A Copier template that scaffolds a per-customer Ansible project mirroring `projects/aws/<customer>/ansible`. **Reference impl + extraction source = the Credit Agricole repo** (`projects/aws/credit-agricole/ansible`, code `caa`, us-west-2). Built + shipped **v1.0.1** 2026-06-18, CI green, E2E-validated against CAA (zero unintended drift).

Key insight that makes it small: the CAA repo is **already ~90% parameterized at Ansible runtime** via `{{ project_name }}` (Vault paths `secret2/data/{{ project_name }}/...`, S3 buckets, AD groups `jnk_{{ project_name }}_ssh`, ASG names). Copier only fills the literals Ansible **cannot** derive at runtime.

## Generate a new project
```bash
copier copy \
  "git+ssh://git@sfo-cvdevopsgit01.eqxdev.exigengroup.com:2224/iac/ansible/template/client.git" \
  ~/gitwork/iac/projects/aws/<customer>/ansible
```
Answers: `project_code` (lowercase 2-6, becomes `project_name`), `full_project_name`, `region` (→ `region_code` auto-computed, **confirm it**), `domain_name` (default `<project_code>-eis.cloud`), `aws_profile`, `vault_addr`, + 12 `enable_*` service flags (jenkins/build_node default true; rest false). Selenoid also asks subnet/SG/IAM-profile ids — leave blank, fill after the VPC exists. After generation: `ansible-galaxy install -r roles/requirements.yml`; `cp .env.example .env` + edit `VAULT_TOKEN`; macOS → `docker build -t ansible-aws:local docker/` then `./docker/run.sh shell`.

Update an existing project: `cd <project>; copier update --defaults .` (answers live in `.copier-answers.yml`, regenerated — never hand-edit).

## The one non-negotiable design rule — custom delimiters
Ansible YAML contains `{{ }}` / `{% %}` that must reach generated files **verbatim** (Ansible evaluates them at runtime). So Copier markers are `[[ ]]` / `[% %]` / `[# #]` (set in `copier.yaml` `_envops`, same as `terraform/template/{client,module}`). Result: `aws_ssm_bucket_name: "{{ aws_region_code}}{{ project_name }}ansible"` passes through untouched; only `project_name: "[[ project_code ]]"` is rendered by Copier. `_templates_suffix: ""` (scan all files), `_subdirectory: template`, `trim_blocks/lstrip_blocks: true`.

## What IS templated (literals Ansible can't derive) vs static
- **Templated:** `group_vars/all.yml` `project_name`/`aws_region`/`aws_region_code`; `inventory/aws_ec2.yml` SSM bucket + region (**dynamic inventory loads BEFORE group_vars → cannot use Ansible vars, must be a Copier literal**); `group_vars/infra.yaml` DNS zone + acme wildcard domains; Keycloak/Sisense hostnames; `host_vars` **filename** (`[[ region_code ]][[ project_code ]]keycloak01.yaml`); `.env.example` + `docker/run.sh` defaults (profile, vault addr); Selenoid subnet/SG/IAM-profile (when `enable_selenoid`).
- **Static / runtime-derived (NOT templated):** everything keyed off `{{ project_name }}` (Vault paths, buckets, AD groups, ASG names); `ansible.cfg`; base playbooks; `docker/Dockerfile`; the committed `local_kernel_patch` role.
- **Generalizations applied during extraction** (render identical values for CAA, but portable): `ta.yaml` `project_sonar`/`selenoid_asg_name` → `{{ aws_region_code }}{{ project_name }}…`; `all.yml` `selenoid_env: AWS0-…` → `{{ aws_region_code | upper }}-…`; `selenoid_ticket` blanked.

## Per-service gating
Each `enable_<svc>` flag gates a playbook + its `group_vars` + its `roles/requirements.yml` entry, via **Jinja conditional file/dir names** with the custom delimiters: `playbooks/[% if enable_gitlab %]gitlab.yaml[% endif %]`, `inventory/group_vars/[% if enable_build_node %]bld.yaml[% endif %]`, dir `playbooks/[% if enable_jenkins %]jenkins[% endif %]/`. When false the name renders empty → Copier skips the file/dir entirely. `requirements.yml` wraps each role's `- src:` block in `[% if enable_x %]…[% endif %]`; base roles (environment, docker_install, vault_agent_ssl, rhel_subscription, acme_cert_update, linux_joindomain) always present. Service→role map: jenkins→docker_compose_jenkins, build_node→temurin_openjdk+maven+ant_install+cli_tools, gitlab/sonar/opengrok/atlantis/selenoid→docker_compose_*, sisense→sisense_install. (nexus/etcs/s_hub gate the **playbook only** — no role in requirements; matches CAA source.)

## Roles are external; .env is secret
Only `roles/requirements.yml`, `roles/.gitignore`, and the committed `local_kernel_patch` role ship. Other roles install via `ansible-galaxy install -r roles/requirements.yml` (the `roles/.gitignore` = `/*` ignores them). `.env` is gitignored in the source → the template ships `.env.example` (no token).

## Maintaining / extending the template
- Edit under `template/` using `[[ ]]`/`[% %]`. Add a new var to `copier.yaml`; reuse the `region_code` dict-default idiom (copied verbatim from `argocd/template/clusters`) and `validate: "^regex$"` string idiom (from `terraform/template/client`).
- **Validate locally**: `bash ci/mock-test.sh` — renders `ci/mock-answers.yml`, greps for leaked `[[`/`[%`/`[#` markers, parses all YAML. Needs the dir to be a git repo (uses `--vcs-ref HEAD`) → commit first.
- Bump a tag for every release (`v1.0.x`); consumers pin `--vcs-ref`. Don't move a published tag.
- Reviewer routing: **ansible → `--reviewer eramadan`** (see [[feedback_mr_reviewer_routing]]).

## GitLab push / CI gotchas (hit on first ship, 2026-06-18)
1. **`glab repo create iac/ansible/template/foo` 404s** ("Could not find group ansible") — glab mis-parses the nested path, AND `iac/ansible/template` already exists as a **subgroup**, not a project. Create the project via the API with an explicit namespace id:
   `glab api --method POST projects -f name=client -f path=client -F namespace_id=1717 -f visibility=private`
   then add the remote manually: `ssh://git@sfo-cvdevopsgit01.eqxdev.exigengroup.com:2224/iac/ansible/template/client.git`.
2. **Pipeline stuck `pending` forever** — every group runner is `run_untagged:false` (`glab api runners/<id>` → check `run_untagged`/`tag_list`). An untagged job NEVER runs. Add `tags: [terraform]` to the CI job (runners 16/32 are the `terraform`-tagged k8s-executor runners in the `iac` namespace and run arbitrary docker images, e.g. `python:3.12-slim`). Sibling templates pin the same tag.
3. **Generated-project pre-commit** ships end-of-file-fixer + trailing-whitespace + yamllint (ansible-lint commented until galaxy roles installed). The CAA source had error-level yamllint hits (no-newline-at-EOF, trailing spaces) → fix them in the template source (`perl -i -pe 's/[ \t]+$//'` + `perl -i -0777 -pe 's/\s*\z/\n/'`) so generated projects pass their own pre-commit on first run. Cosmetic indentation/blank-line **warnings** are non-failing (yamllint exits 0 on warnings) — leave them; they match upstream.

## E2E validation (parity vs the reference customer) — the proof method
Pull the **published tag** (not the local working dir) and diff against the real customer tree, read-only:
1. `copier copy --defaults --data-file <caa-answers.yml> --vcs-ref v1.0.1 <git-url> $TMP/render` (answers = the customer's real values incl. selenoid ids + all services on).
2. Export the live customer tree **without touching it**: `git -C <caa-repo> archive HEAD | tar -x -C $TMP/caa` (read-only; never push/modify the customer repo). Add any untracked-but-real files (e.g. `sisense_cert.yaml`) for parity.
3. `diff -rq $TMP/caa $TMP/render` for structural drift; `diff -ru …` for content.
**Pass = zero files missing; only intentional additions** (`.copier-answers.yml`, `.env.example`, `.pre-commit-config.yaml`); **and every content diff is one of:** docs/cosmetic, the v1.0.1 whitespace cleanup, runtime-`{{ }}` generalizations that resolve to identical values (`{{ aws_region_code }}{{ project_name }}` with aws0/caa = `aws0caa…`), or the requirements.yml base-first reorder (same roles/versions). Confirm the Ansible `{{ }}` survived: `grep -rn '{{ project_name }}\|secret2/data' $TMP/render/inventory` should match the source byte-for-byte. The v1.0.1 E2E run confirmed all 13 content diffs benign, 0 unintended. Clean up `$TMP` after.

## Vault access + run prerequisites (axajp run — verified EISSAASDEV-302)
Before running ANY playbook, the Vault path must be **access-granted AND fully populated** — these are
THREE separate gates, not one. Diagnose by HTTP code (see below); each points at a different owner.

- **Path = `secret2/data/<project_code>`** (new-client convention, NOT `rnd/cicd/3.0/...`). Standing it
  up is **4 distinct things, distinct owners** (see Phase-0 skill §8 for the full breakdown): (1) branch
  — Denys; (2) **AD-group READ grant** — `Genesis_DevOps_CI`/`genesis-ci` policy must include
  `secret2/data/<proj>/*` (needs approver sign-off); (3) **skeleton seed** (script) — Sergii/Olha; (4)
  **FULL secret population** — the operational secrets below, several client-specific (cloud/AD team).
- **Diagnose the gate by HTTP code on a direct leaf read** (`curl -o /dev/null -w '%{http_code}'`):
  - **403 `permission denied`** → gate 2 (AD-group grant) missing. **LIST can still succeed** — never
    judge access by LIST. Escalate the grant.
  - **404 `{"errors":[]}`** → access IS granted, but **no data there** → gate 3/4 (skeleton-only or not
    populated). Escalate the seed/populate.
  - **200 + non-empty `.data.data`** → ready.
  ```bash
  VT=$(grep '^VAULT_TOKEN=' .env|cut -d= -f2-); VA=$(grep '^VAULT_ADDR=' .env|cut -d= -f2-)
  curl -sk -o /tmp/v.json -w '%{http_code}\n' -H "X-Vault-Token: $VT" \
    "$VA/v1/secret2/data/<project_code>/automation/ldap"   # 403 vs 404 vs 200 — that's the diagnosis
  ```
- **Diff against the CAA reference** to get the exact missing list: you can usually read
  `secret2/metadata/caa`. `LIST secret2/metadata/caa/automation` → ~29 keys (ldap, gitlab, jenkins,
  nexus, …); a skeleton-seeded client shows only `datadog`. Hand DevOps the precise diff.
- **EXACT leaf paths + keys the playbooks read** (from `inventory/group_vars/all.yml` — lazy Jinja
  lookups, so a playbook fails only when it references the var):
  | Vault leaf (`secret2/data/<proj>/…`) | keys | consumed by |
  |---|---|---|
  | `automation/ldap` | `adhost`,`adsearch`,`adbinddn`,`adpassword` | linux_joindomain |
  | `identities/cicd_team/cicd/default_build_user` | `build_user_helm_url`,`build_user_name`,`build_user_password` | nexus/helm |
  | `identities/cloud_team/cicd/redhat` | (whole secret) | rhel_subscription |
  | `identities/cloud_team/software/sslupdate-certificates-approle` | `role_id`,`secret_id` | vault_agent/acme |
  | `identities/cloud_team/software/ssosync_bind_user` | `username`,`password` | domain-join bind |
  | `ssl/<project_zone>/ecdsa` | (TLS cert) | keycloak/sisense host_vars |
- **Prep while you wait on Vault** — these need only SSO + Docker, NOT Vault, so stage them so the run
  is instant the moment data lands: build `ansible-aws:local` (`docker build -t ansible-aws:local docker/`);
  `ansible-galaxy install -r roles/requirements.yml` (16 roles — see keyscan bug below);
  `aws ssm describe-instance-information --profile <proj> --region <r>` (confirm all toolchain hosts
  PingStatus=Online); `./docker/run.sh exec ansible-inventory -i inventory --graph` (`exec` mode runs
  before the playbook path; still needs `VAULT_TOKEN` set for the wrapper guard, but doesn't read Vault).
  Set **`enable_selenoid=false`** if the Selenoid ASG was deferred in Phase 3.
- **`VAULT_TOKEN`** lives in `.env` (gitignored — `chmod 600 .env`; NEVER commit/echo it). Wrapper
  requires it set (`run.sh` line `: "${VAULT_TOKEN:?}"`).

## ⚠️ `docker/run.sh` ssh-keyscan bug — fresh galaxy install aborts
The wrapper pre-seeds known_hosts but **keyscans only `sfo-devopsgit01`**, while `roles/requirements.yml`
pulls `linux_joindomain`, `sisense_install` and `docker_compose_selenoid` from the **other** host
`sfo-cvdevopsgit01` (also port 2224). On a clean checkout, `ansible-galaxy install -r roles/requirements.yml`
through the wrapper dies with `Host key verification failed` on the first cvdevopsgit01 role and aborts
the rest. **Fix (one line — `ssh-keyscan` takes multiple hosts on one port):**
```sh
ssh-keyscan -p 2224 sfo-devopsgit01.eqxdev.exigengroup.com sfo-cvdevopsgit01.eqxdev.exigengroup.com >> ~/.ssh/known_hosts 2>/dev/null;
```
Fixed in the template + axajp project (MRs, reviewer eramadan, 2026-06-22). The container is `--rm` with
known_hosts rebuilt from the keyscan each run, so re-running with `--force` is a clean end-to-end verify
(all 16 roles install, zero host-key failures). See [[eissaasdev302_axajp_env_state]].

## Related
[[ansible_copier_template]] (memory), [[clusters_template_v107]] (copier conditional-dir gating tricks), [[eis-account-vending]] / generate-new-project (the terraform half of onboarding), [[ansible_docker_runner_macos]] (the docker/run.sh runner the generated project uses), [[gitlab_module_repo_bootstrap]].
