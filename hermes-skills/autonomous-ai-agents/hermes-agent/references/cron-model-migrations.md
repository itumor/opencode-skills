# Cron job model migrations

Session-derived notes for bulk cron model/provider updates.

## Pattern

1. List jobs first:
   ```bash
   hermes cron list
   ```
2. Update each job individually with the cronjob tool:
   ```json
   {"action":"update","job_id":"<id>","model":{"model":"gpt-4.5-mini","provider":"openai-codex"}}
   ```
3. Re-list jobs to verify the model/provider fields changed.

## Notes

- Paused jobs can still be updated; they do *not* need to be resumed first.
- For many jobs, update them in parallel when the tool layer supports it.
- The model override lives on each cron job record; there is no bulk "set all jobs to model X" command.
- In this session, 9 jobs were migrated from `minimax-m2.5-free` to `gpt-4.5-mini` under provider `openai-codex`.
