# AI briefing workflow notes

Use this workflow when generating a short daily AI news briefing from feeds and articles:

- Use Google News RSS as a discovery layer when you need broad, fast coverage across AI-related queries.
- Tighten queries aggressively; broad searches can surface irrelevant items or noisy matches.
- Prefer primary sources for the final briefing: official company blogs/newsrooms, arXiv papers, and the linked article URL from the feed item.
- For full text, fetch the article URL directly and extract the main body from `<article>`, `<main>`, or paragraph text rather than relying on RSS snippets alone.
- Keep the briefing focused on the strongest 24-hour developments; if there are fewer than 3 truly important items, report that instead of padding.
- Avoid repeating stories already covered earlier in the day unless there is materially new information.