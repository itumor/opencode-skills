---
name: ascender-local-demo
description: Use when asked to run CIQ Ascender (AWX fork) or AWX locally for a demo or POC - "run Ascender on kind/docker", "Ansible controller demo", "Tower alternative demo", "give me a URL to show", "run our playbook from Ascender against a real EC2 over SSM", "test ascender-mcp end to end", or when an Ascender/AWX job over aws_ssm fails with "Failed to create temporary directory", "Destination ... not writable", or sudo/become not applied.
---

# Ascender local demo (kind) + real SSM host + ascender-mcp

Built and verified 2026-11-24 (Ascender 25.6.3, operator 25.6.3, ascender-mcp 0.0.3, kind v0.33, Docker Desktop arm64).
Memory: `ansible-controller-eval-lucid-2026-11-24`, `ansible-controller-pod-root-needs-ansible-user-ssm-user`.
Tooling in `files/`. **Copy `files/` into a work dir first (e.g. `<repo>/docs/<topic>/local-demo/`) and run from there**: `seed.sh` writes `demo-credentials.env` next to itself, and that must never land in `~/.claude` (tracked, gitleaks).

## 1. Cluster + Ascender (about 6 min)
1. Docker Desktop running (`open -a Docker` after a reboot).
2. `kind create cluster --config kind.config --kubeconfig ~/.kube/kind-ascender-demo.config` : separate kubeconfig, the user's context stays untouched; NodePort 32000 bound to 127.0.0.1.
3. EVERY kubectl call: `--kubeconfig ~/.kube/kind-ascender-demo.config --context kind-ascender-demo` (prod-guard blocks without `--context`).
4. `kubectl ... create namespace awx`, `kubectl ... apply -k .` (kustomization pins operator tag + image), wait `rollout status deploy/awx-operator-controller-manager`, then `kubectl ... apply -f ascender-cr.yaml`.
   - At tag 25.6.3 the CR is still `awx.ansible.com/v1beta1` kind `AWX`; the `devel` branch moved to kind `Ascender`. Read the tag, not the default branch.
5. Wait for `GET http://127.0.0.1:32000/api/v2/ping/` = 200 AND `rollout status deploy/ascender-demo-task`. Before the migration job ends the UI shows "Server Error" and the API 500s ("django_migrations does not exist", "No task instances are READY"): not a bug, wait.
6. `bash seed.sh` : org, 3 fake hosts (local connection), project, job template with survey, approval workflow, disabled schedule, run-only team + user. Idempotent.
7. Admin password: secret `ascender-demo-admin-password` (key `password`). Do not print it in chat: write it to `demo-credentials.env` (600) and point the user at the file.

## 2. Real hosts over SSM
- Stock `ascender-ee` lacks `session-manager-plugin` and `hvac`: `docker build -t eis-ascender-ee:demo1 ee/`, `kind load docker-image eis-ascender-ee:demo1 --name ascender-demo`, register EE with `pull: never`.
- Settings: `AWX_ROLES_ENABLED=false`, `AWX_COLLECTIONS_ENABLED=false` when the repo's `roles/requirements.yml` uses git+ssh (project sync fails otherwise).
- Pods reach VPN GitLab (HTTPS cert verifies, SSH 2224) and AWS through Docker Desktop.
- Credentials: pre-create EMPTY "Source Control" and "Amazon Web Services" credentials, then the USER runs `fill-credentials.sh` (AWS SSO temp keys + new read-only deploy token, nothing printed). I never type real keys. Edit the constants at the top for another account/repo.
- Project: `scm_branch` = demo branch; inventory source `source: scm`, `source_path: inventory` (the whole dir, so `all.yml` connection vars load), AWS credential attached.
- Job template extra var **`ansible_user: ssm-user`**. Without it: "Failed to create temporary directory" (/root) and sudo silently skipped. Never raise verbosity to 4 with aws_ssm (session tokens + presigned URLs in the log).
- No safe small playbook in client repos: `ascender_demo.yaml` (asserts one host, read-only report, optional one MOTD file). Push on a demo-only branch from a worktree off fresh `origin/main`, pre-commit + `verify-iac-changes` first, no MR.
- Proof pattern for a write: check run (changed=1) -> real run (changed=1) -> check run (changed=0). State `Disruption:` before the real run and get the user's go.

## 2b. A real change job, all in code (ref pto-reference/ansible !13 + !14, 2026-11-24)
- Template as code: a repo script (`ascender/nexus_os_patch_template.sh [branch]`) that PATCHes the project `scm_branch`, syncs project + inventory source, creates/PATCHes the job template, attaches the AWS credential, posts the survey. Looks objects up by name, token from `ASCENDER_TOKEN`, launches nothing, safe to re-run. Copy it for the next host.
- **Test a branch before merge:** run the script with the feature branch, launch the read-only run, then after merge run it again with `main`. AWX rejects a template whose playbook is not on the project's branch, so the template cannot exist before the branch is pushed.
- Local demo token: `set -a; . demo-credentials.env; set +a; ASCENDER_TOKEN="$ADMIN_MCP_TOKEN" bash <script>`. List key names with `cut -d= -f1`, never cat the file.
- **Roles written for real runs break in check mode** (`command` tasks are skipped, later `when: x.rc == 0` errors). Do not promise "check run first". Put read-only pre-flight tasks first (`check_mode: false`), then `meta: end_play` unless `-e <thing>_apply=true`; expose that flag as a survey choice with default `false`.
- **Every guessed value gets a pre-flight assert before the first change** (service URL, compose project, one host). 11-24: guessed Nexus `127.0.0.1:8081` was wrong (443 proxy); job failed at the status check with nothing stopped. A probe over VPN (`curl -sk https://<host fqdn>/...`) found the right port.
- Stateful compose host: `docker compose ls --format json` for project names, `docker compose -p <name> stop` / `start` (start, not up: nothing is recreated), role via `include_role` inside `block:` with start + health wait in `always:`. `roles:` cannot be wrapped in a block.
- MCP limits: ad hoc is restricted to `ping`/`setup`/`gather_facts`, so on-host recon = the pre-flight play. `wait_for_job` returns the whole record incl. `job_env` (large); for output use `curl .../jobs/<id>/stdout/?format=txt | tail` and `/jobs/<id>/ | jq '{status,scm_revision}'`. `list_job_events` with `task:` gives a task's stdout.
- Check the Ascender host's groups before adding a static group: `inventory/aws_ec2.yml` keyed_groups (tag `Acronym`) already gave `nexus`, and `ansible_host` = instance id (the snapshot tasks need that).

## 3. ascender-mcp
- `docker run -d --name ascender-mcp -p 127.0.0.1:8080:8080 -e ASCENDER_HOST=http://host.docker.internal:32000 ghcr.io/ctrliq/ascender-mcp:0.0.3`; `/healthz`, `/readyz`.
- Streamable HTTP, per-user bearer token (server holds no credentials; Ascender RBAC decides). Create personal tokens by API into `demo-credentials.env`.
- `set -a; . ./demo-credentials.env; set +a; python3 mcp_e2e.py` : 20 checks (401 without token, run-only user limits, launch + wait + host summary + stdout, approval needs `expected_name`). `mcp_client.py tools|call` for ad hoc use.
- Traps: empty lists come back `results: null`; job stdout lags about 1 s after status flips; 129 tools incl. delete: for real use set `ASCENDER_READ_ONLY=true` or `ASCENDER_TOOLSETS=job_runner`.
- Claude Code: `claude mcp add --transport http --scope user ascender http://127.0.0.1:8080/mcp --header 'Authorization: Bearer ${ASCENDER_TOKEN}'` (single quotes). The desktop app does not inherit shell env: start `claude` from the terminal that has the variable. User-scope entry is the user's to add.

## 4. Hand-back
- Give URL, where the passwords are, a numbered click path, and "limits to say out loud" (fake hosts / no SSO / single pod / what was not clicked through).
- Teardown commands go in a `text` block, never a runnable `bash` block (they got Run-clicked mid-build twice).

Teardown, after the demo only:
```text
kind delete cluster --name ascender-demo        # drops stored AWS keys and all demo data
docker rm -f ascender-mcp
revoke the GitLab deploy token; delete the demo branch; git worktree remove <worktree>
remove demo files from the host (e.g. /etc/motd.d/ascender-demo, /tmp/.ansible-ascender)
```
