# LinkedIn publish flow notes

This note captures the current operational sequence for the CNCF tracker-driven LinkedIn automation.

## Recommended preflight

1. Validate the workbook before posting:
   ```bash
   python3 ~/.hermes/skills/social-media/linkedin-automation/scripts/check_tracker.py
   ```
2. Run the postbot with the explicit workbook path.
3. Keep `--skip-if-posted-today` enabled so the state file remains the duplicate-prevention source of truth.
4. When debugging caption/publish behavior, pass an explicit `--image-path` so image generation is not part of the variable set.

## Example publish invocation

```bash
python3 ~/.hermes/scripts/linkedin_postbot.py \
  --workbook /Users/eramadan/GitRepo/cncf_linkdin/cncf_linkedin_codex_kit/output/cncf_linkedin_tracker_tools_first.xlsx \
  --next-unposted \
  --text-provider openai \
  --text-model gpt-5.4-mini \
  --skip-if-posted-today \
  --publish \
  --image-path /Users/eramadan/.hermes/cache/helm-linkedin-card.png
```

## Post-publish verification

- The state file should record the posted topic and returned LinkedIn URN.
- The run should remain idempotent when re-run the same day with `--skip-if-posted-today`.
- If the script exits early for locking or duplicate protection, treat that as a safe no-op rather than an error.
