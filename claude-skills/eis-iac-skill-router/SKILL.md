---
name: eis-iac-skill-router
description: WHEN any EIS/IaC task and the matching skill is unknown — read this first, then load exactly one domain skill from the trigger list. Pointers only; no procedures.
---

# EIS IaC skill router

Pick **one** skill below from the trigger. Then open that skill’s `SKILL.md` and follow it. Do not invent steps from this file.

| Trigger | Skill |
|---------|-------|
| About to claim done / commit / MR after `.tf`/Argo/Ansible/Dockerfile edits | `verify-iac-changes` |
| Stale clones, missing repos, dirty trees, “refresh workspace” | `iac-workspace-refresh` |
| Atlantis lock stuck / orphaned / “No lock found” / unlock fails | `atlantis-lock-troubleshooting` |
| Atlantis plan segfault / “Text file busy” / broken terraform binary | `atlantis-iac-binary-recovery` |
| CI `git::` module 403 job-token / “Failed to download module” | `unblocking-job-token-module-fetch` |
| Fix `eis-*` module + bump consumer pin / forced replacement after bump | `eis-module-fix-release-consume` |
| Same small change across many GitLab repos / fleet MR batch | `gitlab-fleet-mr-propagation` |
| Park many review-ready MRs without merging / dirty-tree MR series | `parked-mr-series` |
| WAF on public ALB or NLB→internal-ALB isolation rollout | `waf-staged-public-alb-isolation` |
| `eis-waf` module / WAF POC on eis-iac dev | `eis-waf-dev-integration` |
| Full new OneSuite/client env end-to-end (conductor) | `eis-onesuite-platform-provision` |
| OneSuite Phase 0 prereqs / coordination gates before vending | `eis-onesuite-phase0-prereqs` |
| Pre-file external-team deps at OneSuite start | `eis-onesuite-external-deps` |
| Vend AWS account / create account for client POC | `eis-account-vending` |
| Scaffold client Terraform from Copier template | `eis-onesuite-phase2-terraform-scaffold` |
| Provision Shared/infra stage (network + toolchain) | `eis-onesuite-phase3-infra-provision` |
| Provision Dev stage via Atlantis (core→services) | `eis-onesuite-phase4-dev-provision` |
| App handoff of live EKS + delivery toolchain | `eis-onesuite-phase7-app-handoff` |
| E2E health check of freshly provisioned OneSuite env | `eis-onesuite-e2e-verify` |
| OneSuite KT workshop / change-team walkthrough | `eis-onesuite-kt-workshop` |
| Scaffold per-customer Ansible project | `eis-ansible-project-template` |
| Cut client Terraform off shared Atlantis → EC2 Atlantis | `eis-client-atlantis-cutover` |
| Onboard EKS into multi-cluster Argo CD hub | `argocd-cluster-onboarding` |
| Argo CD app stuck Failed / CRD race / hand-sync forever | `argocd-crd-race-and-stuck-apps` |
| Red/slow `argocd` GitLab CI (render/pluto/checkov) | `argocd-ci-pipeline-diagnosis` |
| Change Argo CD clusters Copier template | `argocd-clusters-template-change` |
| Argo CD hub SSO/RBAC who-can-login | `eks-managed-argocd-sso-and-rbac` |
| EKS nodegroup upgrade stuck PodEvictionFailure | `eks-nodegroup-upgrade-unblock` |
| Decommission feature-validation (fv) stage | `fv-cluster-decommission` |
| Velero missing / restore / parity on EKS | `eis-velero-backups` |
| EC2 outbound lockdown / egress restrict | `ec2-egress-lockdown` |
| AWS Backup vault lock / WORM retention | `eis-backup-vault-lock` |
| Vault Agent SSL onboarding / expired host TLS | `vault-agent-ssl-onboarding` |
| Dedicated build/CI EC2 + EKS deploy access | `eis-build-host-provision` |
| Back from leave / catch-up report across GitLab/Jira/Slack | `eis-absence-catchup-report` |
