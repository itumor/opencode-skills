---
name: tf-ec2-host-decommission
description: Decommission an EC2 host that Terraform manages (ec2 map entry in an EIS iac stage) via MR and Atlantis, removing only its own resources and keeping shared ones. Use when a ticket says "decommission/remove/terminate <host>" and the host is in a lower/test or infra services stack (e.g. COEXT-110738 aws0caatestbld01). Not for hosts with no Terraform (use ec2-idle-host-decommission) or whole stacks (use fv-cluster-decommission).
---

# Terraform-managed EC2 decommission

Reference run: COEXT-110738, `aws0caatestbld01` in CAA `lower/test/services`, MR !272, merged 2026-10-28.

## 1. Find every piece the host owns
- `grep -rn "<acronym>01\|<group>" lower/<stage>/` in the stack. Check the ec2 map entry, the `ec2_settings` group (keyed by acronym), `*_custom.tf` SGs and wiring (`extra_security_group_ids`), per-instance IAM policy files `files/iam/ec2/<key>.json`, and EKS `access_mapping` entries with `ec2_group`.
- Shared things stay. A VPC endpoint or prefix list in `core` may serve other hosts. Check before removing: `grep` for the list name across all stacks. Leave shared core resources in place and note them as a follow-up.
- Watch the matcher. A group name that is a substring of another host (`bld` matches `aws0caatestbld01`) drags the wrong access entry along. Keep the removed host's `ec2_group` out of other mappings.

## 2. Make the MR (one stack, minimal)
- Delete only the host's blocks. Keep `# BEGIN/END CUSTOM` markers consistent with what you removed.
- Run `pre-commit run --files <changed>`. It regenerates `README.md` terraform-docs. Check `git status` afterwards.
- Pre-push runs pre-commit again. If its fixers leave a dirty untracked `.claude/logs/` only, that is not a real failure. Re-run the push.
- The verify fast lane (checkov/trivy) runs at directory level. Pre-existing findings in untouched files fail every edit in that dir. See [[feedback_verify_fastlane_directory_level_findings]]. Report them; do not ack them yourself.

## 3. Audit the plan before anyone applies
- Expected shape: `0 to add, 0 to change, N to destroy`. Every destroy must map to the host.
- Read the "Objects have changed outside of Terraform" section. Drift such as EFS size or EKS platform version is not a reason to change anything here, but list it.
- Grep for `aws_instance`, `replace`, and `must be replaced`. None should appear.
- Confirm the destroy list does not touch sibling access entries (`ci-infra`, `ci-etcs`, `argocd`).

## 4. Live read-only checks (before approval)
- `aws ec2 describe-instances --instance-ids <id>`: state, VPC/CIDR, and root volume `DeleteOnTermination`.
- `aws backup list-recovery-points-by-resource --resource-arn <instance arn>`: confirm a restore point exists.
- `aws eks list-access-entries --cluster-name <cluster>` before and after.
- Use the read-only profile (e.g. `CAA-Lower-ReadOnly`). Do not mint creds manually.

## 5. Gate and disruption
- Approval must be on the current head SHA. Approval on an older SHA does not count.
- Decommission = cost reduction: Jira Cost Change Approval (negative Monthly) must be Approved before apply; handoff `Cost: APPROVED <KEY> ...` (skill cloud-cost-change-approval).
- Tag disruption: `Disruption: OUTAGE — <host> only — plan N destroy — window: <yes/no>`. Confirm the consumers moved (for CI, ask the team that owns the pipeline).
- Close or discard any other open MR that holds the same stack's lock, so the apply cannot conflict. See [[atlantis-single-lock-cross-mr]].
- Apply by an Atlantis comment (`atlantis apply -p <project>`), posted by the human. Merge after apply is green.

## 6. Post-apply verification
- Instance state is `terminated`. Volumes are gone.
- The removed access entry is gone. Sibling access entries are still present.
- Run `terraform plan` again on the stack and confirm no changes are left.

## 7. Rollback
- Revert the MR commit and re-plan. Restore the host from AWS Backup. Note that the root volume is not kept after termination; restore comes from the recovery point.
- Check the sibling access entries and CI still map their hosts after any rollback.
