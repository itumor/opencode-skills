---
name: atlantis-iac-binary-recovery
description: Diagnose and recover the shared EIS IaC Atlantis when terraform plans/applies fail with "Text file busy" (exit 126) and/or "signal: segmentation fault" on /atlantis-data/bin/terraform<ver> — a truncated terraform binary left by a concurrent-download race on the persistent volume. Use when an Atlantis MR plan errors on `terraform<ver> init` with Text file busy, segmentation fault, or (after a partial fix) exit status 127 "not found"; when re-plans are blocked fleet-wide for one TF version but an already-merged MR was unaffected; or when someone says "Atlantis is broken / stuck / segfaulting" on the iac GitLab group. Covers WHERE the live Atlantis actually runs (k8s pod, NOT the docker-compose VM), the runt-binary diagnosis, the rm+restart fix (why BOTH are required), and verification by isolated re-plan.
---

# Atlantis-IaC truncated terraform-binary recovery

## When to use

An Atlantis plan/apply on the EIS `iac` GitLab group (bot `pnt_terraform_build`) fails in `terraform init` with one of:

```
running '/atlantis-data/bin/terraform1.15.7 init': exit status 126
sh: /atlantis-data/bin/terraform1.15.7: Text file busy        # first race hit (held fd)
running '/atlantis-data/bin/terraform1.15.7 init': signal: segmentation fault   # corrupt binary, persists
running '/atlantis-data/bin/terraform1.15.7 init': exit status 127 ... not found # after rm-without-restart
```

Tell-tales it is THIS bug (not your TF code):
- Error is on the `terraform<ver> init` **invocation itself**, before any config/module logic.
- It hit right after a `git push` that fanned out autoplans across multiple projects (~5 on CAA) — i.e. **concurrent** first-fetch of a TF version Atlantis had never cached.
- It blocks **re-plans** but an **already-merged** MR is fine (apply ran before corruption / on a healthy version).

Mid-incident skill — the user wants the worker healthy again, not a code change.

## What's actually wrong

Atlantis (`default-tf-distribution: terraform`) downloads each terraform version on demand into the **persistent** data volume at `$ATLANTIS_DATA_DIR/bin/`. When several plans race to install the *same* not-yet-cached version, one write gets interrupted → a **truncated binary** on disk. Healthy `terraform1.x` ≈ 96–117 MB; the runt is much smaller (seen: **65 MB**). Execing the runt → `Text file busy` (while a writer fd is open) then `segmentation fault` (corrupt ELF). The runt survives pod restarts (named volume) and Atlantis will not re-fetch a version it believes is installed.

## WHERE the live Atlantis runs (non-obvious)

NOT the `ansible/roles/docker_compose_atlantis` VM. The live IaC Atlantis is a **StatefulSet pod**:

| | |
|---|---|
| Pod | `atlantis-0` |
| Namespace | `iac` |
| Cluster | `aws0iacdeveks01` |
| Account | `182399717428` (profile `iac` / `EIS-IaC`), us-west-2 |
| URL | `atlantis-iac.dev.aws0.iac.aws.eislab.cloud` → internal ALB → `aws0iacdeveks01-tg` (the EKS nodes) |

Reach it with account admin SSO (no SSM-managed instances; go through EKS):
```bash
export AWS_PROFILE=iac
aws sts get-caller-identity                         # confirm SSO valid; else: aws sso login --profile EIS-IaC
aws eks update-kubeconfig --name aws0iacdeveks01 --region us-west-2 --alias iac-atlantis
```
> macOS has no `timeout` — use `kubectl --request-timeout=25s ...` to bound private-endpoint hangs.
> The `atlantis` namespace is a decoy (empty). The pod lives in ns `iac`. Find it: `kubectl get pods -A | grep -i atlantis`.

## Phase 1 — Diagnose (read-only)

```bash
export AWS_PROFILE=iac
kubectl --request-timeout=25s -n iac exec atlantis-0 -- sh -c 'ls -la /atlantis-data/bin/'
```
Spot the runt: the failing version is **far smaller** than its neighbours and its mtime = the first-failure timestamp. Example:
```
-rwx------ 1 atlantis atlantis 117104824 Jun 11 07:46 terraform1.15.6   # healthy
-rwx------ 1 atlantis atlantis  65658880 Jun 25 10:33 terraform1.15.7   # RUNT  <-- corrupt
```

## Phase 2 — Fix (BOTH steps, in order)

```bash
BAD=terraform1.15.7   # the runt from Phase 1
kubectl --request-timeout=25s -n iac exec atlantis-0 -- rm -f /atlantis-data/bin/$BAD   # 1) delete corrupt file
kubectl --request-timeout=25s -n iac delete pod atlantis-0                              # 2) restart pod
kubectl --request-timeout=120s -n iac wait --for=condition=Ready pod/atlantis-0 --timeout=120s
```

**Why BOTH are mandatory:**
- **rm only** → next plan dies `exit status 127 ... not found`. Atlantis caches its installed-versions list in memory; the out-of-band `rm` desyncs it, so it skips re-download and execs the missing path.
- **restart only** → the fresh process re-scans the volume, finds the 65 MB runt still present, and keeps segfaulting.
- **rm + restart** → fresh process sees the version genuinely absent → downloads a complete copy on next plan.

Pod restart ≈ 1 min; persistent volume and plan locks are retained. Brief interruption to all in-flight iac Atlantis runs — fine when it's already broken; if a long apply is mid-flight, wait for it.

## Phase 3 — Verify

Trigger an **isolated** plan (read-only) on any open MR that uses the affected TF version, then poll the bot:
```bash
cd <repo using that TF version>            # e.g. projects/aws/<client>/terraform
glab mr note create <MR> --message "atlantis plan -p <project-key>"
# poll (stop when pnt_terraform_build posts a note newer than your trigger time):
PROJECT=<url-encoded repo path>            # iac%2Fprojects%2Faws%2F<client>%2Fterraform
glab api "projects/$PROJECT/merge_requests/<MR>/notes?sort=desc&per_page=5" \
  | jq -r '.[] | select(.author.username=="pnt_terraform_build") | "\(.created_at): \(.body[0:300])"'
```
Confirm:
- `kubectl -n iac exec atlantis-0 -- ls -la /atlantis-data/bin/terraform<ver>` → reappears at **full size** (~117 MB).
- Plan output shows `terraform<ver> init` **running** ("Initializing modules...") — no Text file busy / segfault / 127.

A later `Error: Failed to download module` is a **separate** module-fetch/job-token issue ([[unblocking-job-token-module-fetch]], [[tf-local-module-download-ssh-rewrite]]) — NOT this bug. The worker is fixed once `init` executes.

## Phase 4 — Durable fix (candidate, not yet done)

The runt only happens on the **first concurrent fetch of a brand-new TF version**. Options to eliminate:
- Pre-bake pinned terraform versions into the Atlantis image (no on-demand download → no race).
- Serialize first-install / reduce autoplan parallelism so two plans can't write the same new binary simultaneously.

File as a platform follow-up; not required to clear an incident.

## References

- [[atlantis-iac-truncated-tf-binary]] — incident memory (2026-06-25, axajp MR !2/!3), full timeline
- [[atlantis-caa-workflow]] — how to trigger plan/apply + poll the bot notes
- [[atlantis-iac-orphaned-lock-post-migration]] — different Atlantis incident (stranded lock)
- [[unblocking-job-token-module-fetch]] — the separate module-download failure mode
- [[aws-profiles]] — profile-to-account map
