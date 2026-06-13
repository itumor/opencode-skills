# AI news verification notes (May 2026)

Compact field notes for using blogwatcher in AI-news briefing workflows.

## Reliable verification patterns
- **OpenAI pages:** `curl` often returns short/template HTML on `/index/*` and some newsroom pages. Prefer `browser_navigate` + `browser_snapshot` to confirm the rendered title, date, and visible article text.
- **OpenAI cross-check:** use `https://openai.com/news/` and `https://openai.com/sitemap.xml` together. The news page is good for rendered titles/dates; the sitemap is good for recency and URL discovery.
- **Google News RSS:** useful for discovery, but treat RSS entries as leads. Verify the underlying article or publisher page before including an item in a briefing.
- **TechCrunch / The Verge:** direct `curl` usually works for title/date/snippets, but browser verification is still preferable when the page has dynamic/templated content.

## Date handling
- Normalize all feed/article timestamps to timezone-aware UTC before comparing against a 24h cutoff.
- Avoid naive-aware datetime comparisons; convert parsed feed dates with timezone info or attach UTC explicitly before filtering.

## Practical filters
- Prefer official/company sources first, then trusted tech media, then aggregator results.
- Exclude items where only a headline is visible and no publication date can be verified.
- If a source page renders as template HTML, do not trust the raw HTML alone; verify with browser snapshot or a richer extraction path.

## Example signal checks
- OpenAI: rendered title + visible post date + sitemap recency.
- Reuters via Google News RSS: verify headline/date via RSS, then confirm the publisher story if possible.
- AI hardware/policy: prioritize Reuters, official company blogs, or major trade press over secondary commentary.
