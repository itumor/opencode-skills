---
name: eis-build-host-provision
description: Use when provisioning a dedicated build/deploy/CI EC2 host into an EIS client account and granting it deploy access to an EKS cluster — "provision the build host for <client> <stage/UAT>", "deploy the same build node config to UAT", "add a build/deploy/jenkins/runner EC2", "give the build host kubectl access to the cluster", or wiring an EC2 instance role into an eis-eks access_mapping. Covers the infra/services ec2-map pattern, UAT/stage-scoped IAM, the eis-eks ec2_group substring-matcher collision trap, ordered apply (host before access entry), and the SSM headless E2E proof. Reference: COEXT-105506 (aws0caaudep01 dedicated CAA UAT deploy host).
---

# EIS build/deploy host provisioning + EKS access

## What it is
EIS client accounts put **all build/CI/deploy EC2 hosts in the shared `infra` stage** (`projects/aws/<client>/terraform/lower/infra/services/`), NOT in the target stage's VPC. `lower/<stage>/services` has eks/rds/msk/s3 but **no ec2 module**. A "build host for UAT/<stage>" therefore = a new instance in `infra/services`, reaching the target cluster over the existing TGW path. Hosts are SSM-managed RHEL; deploy tooling typically runs in pipeline containers, so the host itself usually needs only base RHEL + SSM + (maybe docker) + an EKS access entry — confirm scope with the requester (infra/access vs full ansible config).

Reference impl (live 2026-06-15, COEXT-105506, CAA MR !76): dedicated UAT deploy host `aws0caaudep01` cloned from the shared `bld01` config, UAT-scoped IAM, cluster-admin on `aws0caatesteks01`.

## Workflow
1. **Check if a shared host already serves the target.** The existing `bld01`/`jnk01` group IAM often already covers all clusters (`<prefix>eks*`/`deveks*`/`testeks*`) and the cluster's `access_mapping` may already map `ec2_group=bld`. Verify live: `aws ec2 describe-instances --filters Name=tag:Name,Values=<prefix>bld01`, `aws eks list-access-entries --cluster-name <cluster>`. If a **dedicated** host is still wanted (manager's call), continue.

2. **Pick a collision-safe acronym** (see Gotcha 1). NOT `ubld`/`uatbld` (contains `bld`). Use e.g. `udep` (UAT deploy). Instance key `<acronym>01` → `<prefix><acronym>01`, role `<prefix><acronym>01-Role`, group policy `<prefix><acronym>-Policy`.

3. **Terraform `lower/infra/services/`** (mirror the CyberArk/CUSTOM-marker convention — `ec2_settings` is a template-owned var, edit inline with `# BEGIN/END CUSTOM <id> | <JIRA>` blocks):
   - `variables.tf` `ec2_settings.<acronym>` — clone `bld` (enable_policy, m6a.xlarge, `root_block_device {volume_size=300, volume_type="gp3", encrypted=true}`, `custom_rules=["30000-30010/tcp"]`, `additional_prefix_lists=["workspaces-dev"]`, Backup tag). **`encrypted=true` is safe on a fresh host** (no existing volume to flip false→true → no replacement).
   - `terraform.tfvars` `ec2` map: `<acronym>01 = {}` (all behaviour merges from settings).
   - NEW `files/iam/ec2/<acronym>.json` — **stage-scoped** least-privilege: EKS + Secrets limited to `<prefix><stage>eks*` (e.g. `testeks*`) only (drop the all-clusters breadth of `bld.json`), ECR push/pull, S3 `<prefix>*portal-*`. Rendered via templatefile vars `project_prefix/account_id/region`.

4. **Terraform `lower/<stage>/services/terraform.tfvars`** — add a NEW key to `eks["01"].access_mapping` (non-destructive; leave existing `ci`/`ci-etcs` alone):
   ```hcl
   "ci-uat" = { ec2_group = "<acronym>", policy = { arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy", scope = "cluster" } }
   ```

5. **Ordered apply** (Gotcha 2): `atlantis apply -p lower-infra-services` → re-`atlantis plan -p lower-<stage>-services` (now shows `+ aws_eks_access_entry` + `_policy_association` for the new role) → `atlantis apply -p lower-<stage>-services` → merge. A plain ordered `atlantis apply` works because exec-order puts infra (13) before stage (33); a targeted stage-first apply silently skips the access entry.

6. **Ansible host-config** (`projects/aws/<client>/ansible`) — group_vars/`<acronym>`.yaml + add acronym to `playbooks/linux_joindomain.yaml` `hosts:`. `environment`/`docker_install`/`vault_agent` are `hosts: all` so `-l <host>` picks the new host up. **Often deferred / SSM-only** — confirm whether the host needs domain-join + docker, or if pipeline-container tooling suffices.

## Gotchas
1. **eis-eks `ec2_group` is a SUBSTRING matcher.** `eis-eks/data.tf`: `data.aws_iam_roles.ec2_group` uses `name_regex = ".*${ec2_group}.*"`. So an acronym containing an existing `ec2_group` value (`bld`, `jnk`) double-binds: e.g. `ci={ec2_group:"bld"}` would resolve BOTH `bld01-Role` and `ubld01-Role` → EKS rejects two access entries for one principal → **apply fails**. Grep the chosen acronym vs every existing `ec2_group` both ways before committing.
2. **Empty-lookup ordering trap.** The `access_mapping` `ec2_group` lookup runs at PLAN time. If `lower/<stage>/services` plans before `<acronym>01-Role` exists, the access entry is **silently not created** (no error) — you'd need a second apply. Always create the host (infra) first, then re-plan the stage.
3. **CI pipeline red with green pre-commit** = the GitLab pipeline's `external` stage carries Atlantis commit statuses (invisible to the REST jobs API). See atlantis-debug skill / Gotcha in that skill.

## E2E verification (SSM, no ansible needed)
Prove the host authenticates to the cluster as the access entry grants. SSM `AWS-RunShellScript` on the instance:
- Install tools: `dnf install -y unzip`; aws-cli v2 (`awscli.amazonaws.com/awscli-exe-linux-x86_64.zip` → `./aws/install --update`); kubectl (`dl.k8s.io/release/v<clusterver>.0/bin/linux/amd64/kubectl`). Egress for both is usually open via TGW (`eks.<region>` 403 = reachable).
- **Trap: SSM root shell `$HOME` ≠ `/root`** → kubectl hits `localhost:8080`. Export `KUBECONFIG=/root/.kube/config` (and `HOME=/root`) explicitly after `aws eks update-kubeconfig --kubeconfig /root/.kube/config`.
- Proof commands: `aws sts get-caller-identity` (= `<acronym>01-Role`); `kubectl auth can-i '*' '*'` → yes; `kubectl get ns` (target ns Active); `kubectl get nodes`; `kubectl auth can-i create deployment -n <target-ns>` → yes; `kubectl create configmap x --from-literal=a=b -n <target-ns> --dry-run=server -o name` (real write authz, not persisted); `kubectl auth whoami` → `Extra.sessionName = <instance-id>` (cluster sees the host).
- **Cleanup after test** (if ansible/host-config is deferred): `rm -rf /root/.kube /usr/local/aws-cli /usr/local/bin/aws /usr/local/bin/aws_completer /usr/local/bin/kubectl` to leave the host pristine for the team's own config.
- No-host network-only proof: `curl -sk <api-endpoint>/version` from the host → HTTP 401 = TLS + reachable via TGW + control-plane SG (which admits the `local` prefix, 10/8 ⊇ infra subnets).

## Gates / closeout
- Module/customer MRs gated by Markuss Zivarts (mzivarts) — relayed Slack approval OK. Prod apply/merge is human-gated.
- Jira (jira.eisgroup.com) via REST + JIRA_TOKEN (see eis-jira-rest-ops). Ticket "Provision and Configure" = provisioning done here; the "Configure" (ansible) half may be a dev-team decision — ask before resolving.
