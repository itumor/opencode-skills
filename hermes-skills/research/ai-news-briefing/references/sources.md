# AI News Briefing — Source Reference

## Primary Scraping Sources (HTML, not RSS)

### TechCrunch (`https://techcrunch.com/2026/05/{DD}/`)
- **Coverage**: AI company announcements, funding rounds, product launches, acquisitions
- **Scraping**: Fetch the date-indexed page. Extract `og:title`, `og:description`, `<p>` body paragraphs
- **Date format**: URL date `2026/05/DD` = articles from that day
- **Known issue**: Body paragraphs sometimes return empty — use meta description as fallback
- **AI keywords**: Check for OpenAI, Anthropic, Google, Microsoft, Meta, Amazon, funding, launch

### Ars Technica AI (`https://arstechnica.com/ai/`)
- **Coverage**: AI policy, copyright law, data center infrastructure, regulation, ethics
- **Scraping**: Fetch main page. Extract `<h2>/<h3>` headline + anchor pairs. For individual articles, `og:title` + `og:description` + `<p>` paragraphs work reliably
- **Strength**: Clear headlines, substantive article bodies, good for technical deep dives
- **Article URL pattern**: `https://arstechnica.com/{category}/YYYY/MM/{slug}/`

### Wired AI (`https://www.wired.com/tag/artificial-intelligence/`)
- **Coverage**: Executive interviews, company strategy, AI culture, policy debates
- **Scraping**: `og:title`, `og:description`, `time@datetime`, `<p>` paragraphs
- **Note**: Wired pages are paywalled for full article access; meta tags + first paragraph are usually accessible
- **Author tags**: Check for Will Knight, Paresh Dave, Maxwell Zeff — they cover AI regularly

### The Verge AI (`https://www.theverge.com/ai-artificial-intelligence`)
- **Coverage**: Consumer AI, product reviews, company announcements, mixed tech
- **Scraping**: The page often serves the same content regardless of date parameter. Extract `<a>` links containing `/2026/` paths. Use `og:title`/`og:description` for individual articles
- **Known issue**: Headlines are embedded in JavaScript-heavy HTML; regex on class names often fails. Fall back to meta tag extraction

### Hacker News (Firebase API)
- **Endpoint**: `https://hacker-news.firebaseio.com/v0/topstories.json` → returns array of story IDs
- **Per-story**: `https://hacker-news.firebaseio.com/v0/item/{id}.json`
- **Filter keywords**: ai, llm, gpt, claude, gemini, neural, model, openai, deepmind, anthropic, meta, mistral, llama, copilot
- **Strength**: Signal-to-noise ratio — high scores on HN indicate community interest. Great for spotting emerging tools and papers
- **Rate**: No auth required, fast. Check top 50 stories in ~10 seconds

### Company Blogs (Direct HTML)

| Company | URL | Notes |
|---------|-----|-------|
| OpenAI | `https://openai.com/news/` | Often no clear dates. Scrape and manually check |
| Anthropic | `https://www.anthropic.com/news` | Has dates. Good for model announcements |
| Google DeepMind | `https://deepmind.google/discover/blog/` | Long-format research posts |
| Microsoft AI | `https://blogs.microsoft.com/ai/` | Copilot, Azure AI, enterprise |
| Meta AI | `https://ai.meta.com/blog/` | Open research, LLaMA family |
| Mistral | `https://mistral.ai/news/` | Model releases, API updates |

## RSS Feeds (Fallback Only)

| Feed | URL | Reliability |
|------|-----|-------------|
| Ars Technica | `https://feeds.arstechnica.com/arstechnica/index` | Poor — returns full HTML, not RSS |
| ArXiv CS.AI | `https://arxiv.org/rss/cs.AI` | Poor — returns tiny file |
| ArXiv CS.LG | `https://arxiv.org/rss/cs.LG` | Poor |
| ArXiv CS.CL | `https://arxiv.org/rss/cs.CL` | Poor |
| MIT Tech Review | `https://www.technologyreview.com/feed/` | Poor |
| Wired | `https://www.wired.com/feed/tag/ai/latest/rss` | Poor |

**Conclusion**: Abandon RSS debugging quickly. All primary sources require direct HTML scraping.

## Supplemental Sources (for verification or niche coverage)

- **Reuters Technology**: `https://feeds.reuters.com/reuters/technologyNews` — usually empty via curl
- **AP News Tech**: `https://feeds.apnews.com/apnews/topnews` — usually empty via curl
- **Axios AI**: `https://www.axios.com/artificial-intelligence` — usually returns minimal content
- **Semafor AI**: `https://www.semafor.com/artificial-intelligence` — returns minimal content
- **Business Insider AI**: `https://www.businessinsider.com/artificial-intelligence` — large HTML but hard to parse

## Known Anti-Scraping Sites

- **TechCrunch**: Requires `--user-agent` flag. May require cookies for full article bodies.
- **The Verge**: Heavy JavaScript. `og:` meta tags are most reliable.
- **VentureBeat**: Consistently returns empty content. Skip.
