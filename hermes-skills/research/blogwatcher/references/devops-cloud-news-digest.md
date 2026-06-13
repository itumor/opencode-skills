# DevOps / cloud news digest workflow

This note captures the working pattern used for a strict last-24h digest focused on DevOps, AWS, Kubernetes, CNCF, and platform engineering.

## Curated source strategy
- Prefer official RSS/Atom feeds and vendor newsroom pages first.
- Use Google News RSS only as a fallback discovery source.
- Verify candidates against the direct source page whenever possible.
- Deduplicate cross-source repeats; keep the best technical source.

## Time filtering rules
- Treat the runtime cutoff as UTC and filter aggressively to the last 24 hours only.
- Prefer feed item `published` / `updated` timestamps or article-page metadata over blogwatcher DB dates.
- When parsing RSS dates directly, use `email.utils.parsedate_to_datetime()` so RFC 822 timestamps preserve timezone and sub-day precision.
- Avoid relying on blogwatcher’s date-only SQLite fields for recency windows; they can widen/narrow the window by hours.

## Deduplication state
- Maintain a compact JSON state file for scheduled digests.
- Deduplicate by `title + url` hash; also keep lowercased truncated titles for near-duplicate detection.
- Persist `last_run` in UTC ISO format.

Example shape:
```json
{
  "last_run": "2026-05-25T06:34:05.875894+00:00",
  "article_hashes": ["..."],
  "article_titles": ["..."]
}
```

## Content selection
- Favor items with concrete technical changes: releases, deprecations, governance, APIs, observability, scaling, or architecture updates.
- Exclude opinion-only or marketing-heavy items unless they contain actionable operational details.
- If the same story appears in multiple places, choose the most authoritative source rather than listing duplicates.

## Practical extraction notes
- Some feed descriptions are only teasers; fetch the article page for the substantive summary when needed.
- Keep summaries short and technical: what changed, how it works, and why operators should care.
- Report all times in UTC in the final digest.
