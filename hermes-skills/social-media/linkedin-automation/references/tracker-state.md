# LinkedIn Tracker State

## Current tracker file
```
/Users/eramadan/GitRepo/cncf_linkdin/cncf_linkedin_codex_kit/output/cncf_linkedin_tracker_tools_first.xlsx
```
- 71 total topics
- State file: `~/.hermes/cache/linkedin-postbot-state.json`

## Verification script
```python
#!/usr/bin/env python3
import sys
sys.path.insert(0, '/Users/eramadan/.hermes/scripts')
from linkedin_postbot import load_rows, DEFAULT_STATE_FILE, posted_today, pick_next_topic
from pathlib import Path

tracker = Path('/Users/eramadan/GitRepo/cncf_linkdin/cncf_linkedin_codex_kit/output/cncf_linkedin_tracker_tools_first.xlsx')
rows = load_rows(tracker)
print(f'Total rows: {len(rows)}')
print(f'Posted today: {posted_today(DEFAULT_STATE_FILE)}')
if not posted_today(DEFAULT_STATE_FILE):
    row = pick_next_topic(rows, DEFAULT_STATE_FILE)
    print(f'Next topic: {row.tool}')
    print(f'Category: {row.category}')
```

## Known state (as of 2026-05-16)

- **Morning post (08:30):** Dapr — published
- **Afternoon post (11:00):** Dapr — published_text_only
  - Post URN: `urn:li:share:7461370145995862016`
  - Image upload failed (token missing `w_member_social` scope)
  - PNG ready at: `~/.hermes/cache/dapr-architecture-diagram.png`
- **Next tool:** Helm (Tracker row 2, status: `needs_review`)
