---
name: linkedin-automation
description: Automated LinkedIn posting via linkedin_postbot.py using the CNCF tracker workbook. Covers setup, state management, image workflows, and troubleshooting for daily scheduled posting.
version: 2026-05
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [linkedin, automation, social-media, cron, cncf, posting]
---

# LinkedIn Automation

Automated LinkedIn posting for CNCF/cloud-native content using the `linkedin_postbot.py` script with a topic tracker workbook.

## Operational sequence

For reliable daily runs, use this order:

1. Validate the tracker workbook with `check_tracker.py`.
2. Run `linkedin_postbot.py` against the explicit workbook path.
3. Keep `--skip-if-posted-today` enabled so the state file remains the duplicate-prevention source of truth.
4. When debugging or isolating caption/publish issues, pass an explicit `--image-path` so image generation is not part of the variable set.

See `references/publish-flow-notes.md` for a concise runbook and example invocation.

## Quick start

```bash
# Run with OpenAI text generation and image generation
python3 ~/.hermes/scripts/linkedin_postbot.py \
  --workbook /Users/eramadan/GitRepo/cncf_linkdin/cncf_linkedin_codex_kit/output/cncf_linkedin_tracker_tools_first.xlsx \
  --next-unposted \
  --text-provider openai \
  --text-model gpt-5.4-mini \
  --publish
```

## Required environment variables

| Variable | Purpose |
|----------|---------|
| `OPENAI_API_KEY` | Required for `--text-provider openai` (text generation) |
| `LINKEDIN_ACCESS_TOKEN` | LinkedIn OAuth access token for publishing |
| `LINKEDIN_AUTHOR_URN` | LinkedIn author URN (e.g., `urn:li:person:...`) |
| `LINKEDIN_CLIENT_ID` | LinkedIn OAuth client ID |
| `LINKEDIN_CLIENT_SECRET` | LinkedIn OAuth client secret |

Store in `~/.hermes/.env` (auto-loaded by linkedin_postbot.py).

## Tracker workbook path

**Do NOT use** the `data/` subdirectory path. The actual tracker file is:

```
/Users/eramadan/GitRepo/cncf_linkdin/cncf_linkedin_codex_kit/output/cncf_linkedin_tracker_tools_first.xlsx
```

The script's internal `resolve_default_workbook()` fallback paths do NOT include this location — always pass `--workbook` explicitly.

## State management

| File | Purpose |
|------|---------|
| `~/.hermes/cache/linkedin-postbot-state.json` | Tracks posted topics, never-repost list, history |
| `~/.hermes/cache/linkedin-postbot.lock` | Single-run lock file (flock) |

Key behaviors:
- `--skip-if-posted-today` no-ops safely if any post is recorded for today
- `posted_today()` checks history entries against current date
- `mark_posted()` appends to history and both block lists on publish
- `acquire_single_run_lock()` uses `fcntl.flock(LOCK_EX | LOCK_NB)` — returns None if already locked

## Image workflow

Default: OpenAI image generation via `--image-provider openai`

| Flag | Default | Notes |
|------|---------|-------|
| `--image-provider` | `openai` | Also supports `pillow`, `canva-prompt`, `canva-export` |
| `--image-model` | `gpt-image-1.5` | OpenAI image model |
| `--image-size` | `1024x1536` | Portrait/4:5 for LinkedIn feed |
| `--image-quality` | `high` | |
| `--image-format` | `png` | |

Images saved to `~/.hermes/cache/linkedin-images/`.

## Troubleshooting

### "OPENAI_API_KEY is required"

The `OPENAI_API_KEY` env var is not set. Add it:
```bash
echo "OPENAI_API_KEY=sk-..." >> ~/.hermes/.env
```

If you are only trying to isolate the posting flow, provide `--image-path` so image generation is not part of the failure surface.

### Tracker file not found

Use the correct path with `--workbook`:
```bash
--workbook /Users/eramadan/GitRepo/cncf_linkdin/cncf_linkedin_codex_kit/output/cncf_linkedin_tracker_tools_first.xlsx
```

### Already posted today (skipped)

Normal behavior when `--skip-if-posted-today` is used. The state file already has a post entry for today.

### Lock file blocking

Another instance of the script is running. Wait for it to complete or check for stale lock files:
```bash
rm ~/.hermes/cache/linkedin-postbot.lock
```

## Verification

Run the check script to see current state:
```bash
python3 ~/.hermes/skills/social-media/linkedin-automation/scripts/check_tracker.py
```

See `references/tracker-state.md` for the current next topic and known state.

## Cron job configuration

Recommended cron entry (08:30 CET/CEST daily):
```cron
30 8 * * * cd ~/.hermes/scripts && python3 linkedin_postbot.py --workbook /Users/eramadan/GitRepo/cncf_linkdin/cncf_linkedin_codex_kit/output/cncf_linkedin_tracker_tools_first.xlsx --next-unposted --text-provider openai --text-model gpt-5.4-mini --skip-if-posted-today --publish >> ~/.hermes/logs/linkedin-postbot.log 2>&1
```

## Second Daily Post (11:00 slot — same topic, different angle)

A separate cron job at 11:00 reuses the morning topic for a follow-up post with a distinct visual and angle.

### Wrapper script

```bash
python3 ~/.hermes/scripts/linkedin_same_topic_architecture_postbot.py --publish
```

Key behaviors:
- Reads `~/.hermes/cache/linkedin-postbot-state.json` history
- Picks the **earliest** topic posted today (`pick_first_topic_today`)
- Sets `--image-provider openai --image-model gpt-image-1` (env: `LINKEDIN_SECONDARY_*`)
- Falls back to `groq` text provider (env: `LINKEDIN_SECONDARY_TEXT_PROVIDER`)
- Writes its own entry to the state history after publishing
- Fails cleanly if no morning post is recorded today (raises SystemExit)

### Angle differentiation

| Morning post (08:30) | Afternoon post (11:00) |
|----------------------|------------------------|
| "What is it" — intro/what-is | "How it works" — architecture/decision |
| Image: concept card or infographic | Image: architecture diagram/system map |
| Caption: brief, punchy, curious hook | Caption: opinionated, technical depth |

The image and caption must do different jobs. The 11:00 image should be an **architecture diagram, system map, or decision aid** — not a marketing card.

### Architecture diagram workflow

1. Generate dark-themed SVG HTML using `creative/architecture-diagram` skill
2. Save to `~/.hermes/cache/<tool>-architecture-diagram.html`
3. Capture PNG via Playwright (headless Chromium — available at `npx playwright screenshot`):
   ```bash
   cd ~/.hermes/cache && npx playwright screenshot \
     "file:///Users/eramadan/.hermes/cache/<tool>-architecture-diagram.html" \
     <tool>-architecture-diagram.png \
     --viewport-size="1200,628"
   ```
4. Upload PNG to LinkedIn via Assets API (see below)

### LinkedIn API image upload — Critical limitation

**Pitfall:** The OAuth token requires `w_member_social` scope for image uploads. Without it, the Assets API (`/v2/assets?action=registerUpload`) returns:
```
403 ACCESS_DENIED — "Field Value validation failed in ... /serviceRelationships/0/identifier"
```
The token works for text-only UGC posts (`shareMediaCategory: NONE` → 201) but fails on image registration.

**Fix:** Re-authorize the LinkedIn OAuth token with `w_member_social` added to the scope.

**Working text-only API call:**
```
POST https://api.linkedin.com/v2/ugcPosts
{
  "author": "urn:li:person:<id>",
  "lifecycleState": "PUBLISHED",
  "specificContent": {
    "com.linkedin.ugc.ShareContent": {
      "shareCommentary": {"text": "<caption>"},
      "shareMediaCategory": "NONE"
    }
  },
  "visibility": {"com.linkedin.ugc.MemberNetworkVisibility": "PUBLIC"}
}
→ 201 {"id": "urn:li:share:<id>"}
```

**Workaround (no API image):** Attach PNG manually via LinkedIn web UI using the file at `~/.hermes/cache/<tool>-architecture-diagram.png`.

## Post quality guidelines

- Marketing-only, single-message, original
- Proof-backed with verifiable facts
- Scannable (short paragraphs, 3-5 hashtags)
- Native to LinkedIn (no markdown, no link-first behavior)
- CTA: narrow, opinionated question at the end
