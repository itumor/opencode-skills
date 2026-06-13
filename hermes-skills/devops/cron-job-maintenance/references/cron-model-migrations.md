# Cron Model/Provider Migration Notes

This note captures a recent migration/verification pattern for Hermes cron jobs.

## Observed failure pattern
When cron jobs were configured with:
- provider: `openai-codex`
- model: `minimax-m2.5-free`

multiple jobs failed with:
- `RuntimeError: Error code: 401 - {'type': 'error', 'error': {'type': 'ModelError', 'message': 'Model minimax-m2.5-free is not supported for format openai'}}`

A related message also appeared in earlier runs:
- `Free promotion has ended for MiniMax M2.5 Free. You can continue using the model by subscribing to OpenCode Go - https://opencode.ai/go`

## Compatibility notes
- `openai-codex` + `minimax-m2.5-free` was rejected.
- `openai-codex` + `gpt-4.5-mini` was also not accepted for this cron setup on this account.
- `openai-codex` + `gpt-5.4-mini` was the last known good pairing in this session.

## Recommended migration sequence
1. List all jobs and capture the current provider/model values.
2. Inspect recent output files under `~/.hermes/cron/output/<job_id>/` for the exact error text.
3. Update the entire fleet to a single known-good provider/model pair.
4. Rerun the affected jobs after the change.
5. Read at least one fresh output artifact to confirm the old error is gone.

## Output inspection path
Cron outputs were read from paths like:
- `~/.hermes/cron/output/<job_id>/<timestamp>.md`

## Preservation rule
Keep schedules, prompts, and delivery targets unchanged while debugging provider/model compatibility unless the user explicitly asks for broader changes.