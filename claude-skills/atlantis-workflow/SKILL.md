---
name: atlantis-workflow
description: Generic Terraform pull-request automation with Atlantis — atlantis.yaml project config, plan/apply comment workflow, locking, custom workflows, policy checks (Conftest/OPA), server-side repo config, and webhook setup. Use whenever the user mentions Atlantis, "atlantis plan"/"atlantis apply" PR comments, a Terraform PR stuck on a lock, custom Atlantis workflows, or is setting up Atlantis for a new repo — even if they just say "our Terraform PRs don't auto-plan" or "how do I add a custom workflow step." Not specific to any one company's Atlantis deployment; for an EIS/OneSuite-specific Atlantis instance, prefer the repo's own atlantis-* skills first.
---

# Atlantis workflow

Atlantis is a self-hosted service that runs `terraform plan`/`apply` from pull request comments, giving Terraform a GitOps review flow: the plan output posts back to the PR so reviewers see the diff before anyone applies.

## Core concepts

- **Project**: one Terraform root module directory + workspace, either auto-detected or declared in `atlantis.yaml` at the repo root.
- **Workspace**: Terraform's own workspace concept (`default` unless the project sets `workspace:`).
- **Lock**: Atlantis holds a lock per `repo/dir/workspace` while a plan is outstanding, to stop two PRs racing on the same state. A merged/closed PR does not always release its lock automatically — check `atlantis unlock` or the web UI.
- **Webhook**: Atlantis needs push + PR events from the VCS (GitHub/GitLab/Bitbucket) delivered to `/events`. No webhook, no comment reactions.

## Comment commands

| Command | Effect |
|---|---|
| `atlantis plan` | Plan every project Atlantis detects changed in this PR |
| `atlantis plan -p <project>` | Plan one named project (from `atlantis.yaml`) |
| `atlantis plan -d <dir> -w <workspace>` | Plan by directory + workspace directly |
| `atlantis apply` | Apply all successful plans on the PR |
| `atlantis apply -p <project>` | Apply one project |
| `atlantis unlock` | Release this PR's locks without applying |
| `atlantis approve_policies` | Override a failed Conftest/OPA policy check (needs permission) |

If a command silently does nothing, check: is the PR merged/closed already (Atlantis ignores commands there), does the repo config route the directory to a different project name, and did the webhook actually deliver (check Atlantis server logs / recent deliveries in the VCS webhook settings).

## atlantis.yaml (repo-level)

```yaml
version: 3
projects:
  - name: prod
    dir: envs/prod
    workspace: default
    terraform_version: v1.7.5
    autoplan:
      when_modified: ["*.tf", "*.tfvars", "../modules/**/*.tf"]
      enabled: true
    apply_requirements: [approved, mergeable]
    workflow: custom
workflows:
  custom:
    plan:
      steps:
        - init
        - plan:
            extra_args: ["-var-file=prod.tfvars"]
    apply:
      steps:
        - apply
```

- `autoplan.when_modified` must include shared module paths with `../` prefixes, or a module-only change in a PR won't trigger a plan for its consumers.
- `apply_requirements: [approved, mergeable]` is the standard guardrail — don't drop it without a reason.
- Workflow steps can be `init`, `plan`, `apply`, `run` (arbitrary shell), or `env` (set an env var for later steps) — useful for injecting a computed value before `plan`.

## Server-side repo config (admin-controlled)

Server-side `repos.yaml` can allow, restrict, or override what individual repos are permitted to put in their own `atlantis.yaml` (e.g. force a specific workflow, disallow custom `run` steps for untrusted repos). If a repo's `atlantis.yaml` seems to be ignored, check whether server config is overriding it — this is a common surprise.

## Policy checks (Conftest/OPA)

Atlantis can run OPA/Conftest policies against the plan JSON before allowing apply. A failing policy blocks `apply` until someone with the `approve_policies` permission runs `atlantis approve_policies`. Useful for cost or security gates that shouldn't be a human review bottleneck for every PR, only the ones that actually violate a rule.

## Common failure modes

- **Stuck lock after merge**: the merging PR's lock sometimes survives if the merge event didn't reach Atlantis (webhook drop, or Atlantis was down). Fix: `atlantis unlock` comment, or delete via the Atlantis UI/API `DELETE /locks?id=<key>` where key is `repo/dir/workspace`.
- **Plan doesn't trigger**: check `autoplan.when_modified` glob coverage, and confirm the PR's base branch matches what the repo config expects.
- **Apply button greyed out / apply_requirements not met**: PR needs an approval and/or must be mergeable (no failing required checks) — Atlantis enforces exactly what `apply_requirements` lists.
- **Two projects plan the same dir twice**: usually two `atlantis.yaml` entries with overlapping `when_modified` patterns, or both autoplan and an explicit project match.
