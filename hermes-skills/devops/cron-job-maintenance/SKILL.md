---
name: cron-job-maintenance
description: "Maintain Hermes cron jobs: update schedules, migrate provider/model settings, and verify runs."
---

# Cron Job Maintenance

Use this skill for scheduled Hermes jobs: listing, updating, rerunning, and verifying cron jobs, especially when changing model/provider settings across many jobs.

## When to use
- The user asks to update or fix one or more cron jobs.
- Multiple jobs must be kept on the same provider/model pair.
- A scheduled job starts failing after a model migration.
- You need to verify that a cron configuration change actually works, not just that the metadata updated.

## Standard workflow
1. **List the jobs first.** Capture job IDs, schedules, and current provider/model values.
2. **Inspect recent failures before changing anything.** Look for provider/model mismatch errors or format incompatibilities.
3. **Change only the necessary fields.** Preserve the schedule, prompt, delivery target, and enabled state unless the user asked otherwise.
4. **Update related jobs in one consistent pass.** Avoid leaving the fleet split across multiple model/provider combinations.
5. **Run a verification pass.** Re-run the affected jobs after the update, ideally in small batches if there are many.
6. **Inspect the output artifacts.** Confirm that the new run succeeded and that the prior error is gone.

## Important pitfalls
- Do **not** assume a model that works in chat will also work for cron jobs under the same provider format.
- When a provider rejects a model, the fix is usually a **provider/model pairing** issue, not a schedule problem.
- If all jobs fail with the same message, prefer a broad consistency fix over per-job tinkering.
- Preserve the job behavior: avoid changing prompts or schedules while debugging model compatibility unless the user explicitly wants that.

## Verification checklist
- `cronjob list` shows the intended provider/model pair for every targeted job.
- A test run was executed after the update.
- At least one output artifact was checked for the absence of the previous model/provider error.
- If failures remain, record the exact error text before trying another migration.

## Reference notes
- See `references/cron-model-migrations.md` for a concise migration log, observed error patterns, and a known-good provider/model pairing from this session.