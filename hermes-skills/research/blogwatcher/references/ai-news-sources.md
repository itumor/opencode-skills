# AI News RSS/Atom Source Matrix

Curated, tested feeds for AI news briefing and monitoring. Updated May 2026.

## Primary Sources

| Source | Feed URL | Focus | Update Freq | Notes |
|---|---|---|---|---|
| Ars Technica | `https://feeds.arstechnica.com/arstechnica/index` | AI, policy, research | Hourly | Best for technical depth; has dedicated AI section |
| TechCrunch | `https://techcrunch.com/feed/` | Startups, funding, products | Several/day | Filter on-title for AI keywords |
| VentureBeat AI | `https://venturebeat.com/category/ai/feed/` | Enterprise AI, infrastructure | Daily | Good for product launches |
| MIT Tech Review | `https://www.technologyreview.com/feed/` | Research, long-form | Daily | Strong on AI safety and ML research |
| Wired AI | `https://www.wired.com/feed/tag/ai/latest/rss` | Culture, policy, business | Daily | Good for AI societal impact stories |
| The Verge AI | `https://www.theverge.com/rss/ai-artificial-intelligence/index.xml` | Products, policy | Daily | Good for Big Tech AI news |
| Reuters Tech | `https://feeds.reuters.com/reuters/technologyNews` | Policy, regulation, markets | Several/day | ⚠️ DNS failures from sandbox — use Google News AI RSS instead |
| Google News AI | `https://news.google.com/rss/search?q=AI+artificial+intelligence&when=1d&sort=date` | Aggregated, broad | Continual | Use `when:1d` for last 24h; `sort=date` for recency |

## Supplementary Sources

| Source | Feed URL | Focus | Notes |
|---|---|---|---|
| Hacker News | `https://hnrss.org/frontpage?feed=https://news.ycombinator.com/rss` | Technical, research | Filter on-title with: ai, LLM, model, GPT, Gemini, Claude, Anthropic, OpenAI, multimodal, agent |
| arXiv cs.AI | `https://export.arxiv.org/api/query?search_query=cat:cs.AI&sortBy=submittedDate&sortOrder=descending&max_results=20` | AI research papers | Combine with cs.LG, cs.CL, cs.RO |
| arXiv cs.LG | `https://export.arxiv.org/api/query?search_query=cat:cs.LG&sortBy=submittedDate&sortOrder=descending&max_results=20` | ML papers | See date extraction note below |
| AP News Tech | `https://feeds.apnews.com/apnews/technology` | General tech, AI policy | Good for global AI governance |
| Bloomberg AI | Search: `site:bloomberg.com/technology AI` | Markets, funding, IPOs | Use web search; direct RSS limited |

## Company Newsroom Feeds

| Company | Blog/RSS URL |
|---|---|
| OpenAI | `https://openai.com/news/rss` |
| Anthropic | `https://www.anthropic.com/news.rss` |
| Google DeepMind | `https://blog.google/technology/ai/rss/` |
| Meta AI | `https://ai.meta.com/blog/` (no RSS — use web or press feed) |
| Microsoft Research | `https://www.microsoft.com/en-us/research/blog/feed/` |
| AWS ML Blog | `https://aws.amazon.com/blogs/machine-learning/feed/` |
| NVIDIA AI | `https://blogs.nvidia.com/feed/` (filter for AI tag) |

## Filtering Keywords for AI News (HN, TechCrunch, general feeds)

```
ai | AI | llm | LLM | gpt | GPT | gemini | Gemini | claude | Claude |
anthropic | openai | meta.ai | deepmind | multimodal | vision language |
reasoning model | AI agent | AI safety | AI regulation | AI startup |
AI funding | AI infrastructure | AI compute | GPU cluster
```

## arXiv Date Extraction

arXiv IDs follow format `YYMMNNN.NN` (e.g. `2605.12357` = May 16, 2026).
```python
# Extract submission date from arXiv ID
def arxiv_date(aid: str) -> str:
    return f"20{aid[:2]}-{aid[2:4]}-{aid[4:6]}"

# Filter papers from specific date range
recent = [p for p in papers if '2026-05-1' in p['date']]  # May 14-19
```

**NOTE:** The arXiv API's `submittedDate:[DATE1 TO DATE2]` filter has been unreliable. Extracting from the arXiv ID is the consistent method.

## RSS Parsing Template

```python
import xml.etree.ElementTree as ET, urllib.request, re

def fetch_rss_items(url: str, ai_filter: bool = True) -> list[dict]:
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    resp = urllib.request.urlopen(req, timeout=15)
    raw = resp.read()
    if isinstance(raw, bytes):
        raw = raw.decode('utf-8', errors='replace')
    root = ET.fromstring(raw)
    ns = {'atom': 'http://www.w3.org/2005/Atom'}
    items = []
    for item in root.iter('item'):
        title = item.find('title')
        if title is None:
            continue
        title_text = title.text.strip() if title.text else ''
        pub = item.find('pubDate')
        link = item.find('link')
        desc_el = item.find('description')
        desc_text = re.sub(r'<[^>]+>', '', desc_el.text or '')[:300] if desc_el is not None else ''
        items.append({
            'source': url.split('/')[2],
            'title': title_text,
            'link': link.text if link is not None and link.text else '',
            'pub_date': pub.text[:16] if pub is not None and pub.text else '',
            'description': desc_text,
        })
    return items
```

## Known Issues

- **Reuters feeds return DNS failures** from sandbox environments (`nodename nor servname provided`). Do not rely on `feeds.reuters.com` for programmatic fetching — Google News AI RSS (`https://news.google.com/rss/search?q=AI+artificial+intelligence&when=1d&sort=date&hl=en-US`) is a reliable substitute that surfaces Reuters-sourced articles through its aggregated index.
- **TechCrunch/VentureBeat article URLs** sometimes return 404 when fetched directly — always use the `<link>` from the RSS feed.
- **VentureBeat** has sparse AI posts in May 2026; supplement with TechCrunch and Ars Technica for consistent coverage.
- **Google News RSS** returns a mix of old and new articles; always parse `pubDate` (RFC 822) to `datetime` via `email.utils.parsedate_to_datetime()` before filtering.
- **arXiv API** times out on multi-category or high `max_results` queries. Query per-category with `max_results=15` and 20s timeout. See arXiv section above for date-extraction-from-ID pattern.
