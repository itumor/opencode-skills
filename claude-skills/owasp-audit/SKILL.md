---
name: owasp-audit
description: Use when asked for a security/OWASP audit of iac repos, to scan nested repos with checkov/trivy/gitleaks/semgrep/kube-linter, or to auto-fix findings and open reviewer-gated MRs. Triggers - owasp, security audit, scan repos for vulnerabilities, fix security findings.
---

# owasp-audit

Workflow `~/.claude/workflows/owasp-audit.js` (real path `harness/iac/workflows/`). Run the session under `caffeinate -imsu`.

Pipeline: Enumerate -> Scan -> Compile (JS only) -> Fix -> Review -> Open MRs.

- **find**: scan + report. No edits, no MRs.
- **fix**: per repo+tool batch (max `maxPerMR`, default 8): agent edits a detached worktree and re-scans to prove the fix; skeptic reviews the diff and tags `Disruption: NONE|BLIP|OUTAGE`; only approved NONE batches open an MR (GitLab commits API + MR, reviewer eramadan 861). Never merges or applies.

```
Workflow({ name: 'owasp-audit', args: { repos: ['argocd/argocd'], mode: 'find' } })
Workflow({ name: 'owasp-audit', args: { repos: ['projects/aws/credit-agricole/terraform'], mode: 'fix', runStamp: 'r1', jira: 'NOJIRA-001' } })
```

Args: `scope` all|terraform|argocd|ansible|scripts, `mode`, `repos` (paths relative to iac root), `exclude`, `scratch`, `runStamp` (branch names; no Date.now), `jira`, `maxPerMR`, `concurrency`, `allowDisruptive` (default false: BLIP/OUTAGE batches are held and reported).

## Rules baked in
- Skip lists (.checkov.yaml, .kube-linter.yaml, inline skips) respected, never edited.
- Secrets never auto-fixed, always redacted in output.
- Missing/failed scanner = reported in `scan_errors`, never read as clean (`scan-status.txt`).
- Subagents cannot `git commit/push` (guard-bash R9): commits go through the API; worktrees stay behind, `cleanup` lists the removal commands.
- Return value includes `slack_draft` (caveman style): the user posts it, the workflow never posts to Slack/Jira.

## After a run
Read the Atlantis plan on each terraform MR before merge (rule 4); `0 to destroy` is not safe. Check `held` and `manual_findings` in the result.

Selftest of the scanner wrapper: `bash ~/.claude/scripts/owasp-scan-one-repo.sh --selftest`.
