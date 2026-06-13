---
name: ai-news-briefing
description: "Generate daily AI news briefings (morning/evening editions) from web sources — covering models, infrastructure, policy, funding, and real-world AI applications."
version: 0.1.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [AI, News, Monitoring, Briefing, Cron]
    schedule: "Daily (morning + evening editions)"
    output_dir: "~/.hermes/cron/output/ai-news-briefing/"
---

# AI News Briefing

Generate structured daily AI news briefings (Morning and Evening editions) from web sources. Covers major AI companies, model releases, infrastructure, regulations, funding, and real-world applications.

## Workflow

### 1. Pre-flight: Check for Morning Edition

Before researching, check whether today's morning briefing already exists:

```
~/.hermes/cron/output/ai-news-briefing/YYYY-MM-DD-morning.md
```

If it exists, read it first to avoid repeating the same headlines.

### 2. Source Discovery Strategy

**Do NOT rely primarily on RSS feeds.** Most major AI news sites (TechCrunch, VentureBeat, MIT Tech Review) return empty or unparseable content from their RSS feeds in this environment. Use direct HTML scraping instead.

**Primary sources (in order of reliability for scraping):**

| Source | URL | Notes |
|--------|-----|-------|
| TechCrunch | `https://techcrunch.com/2026/05/{today}/` | Good for AI company news, funding, launches. Extract via `og:title`, `og:description`, `<p>` paragraphs. |
| Ars Technica AI | `https://arstechnica.com/ai/` | Excellent for policy, copyright, data center stories. Has clear `<h2>/<h3>` headlines. |
| Wired AI | `https://www.wired.com/tag/artificial-intelligence/` | Good for executive interviews, company strategy, culture. |
| The Verge AI | `https://www.theverge.com/ai-artificial-intelligence` | Often loads the same page regardless of date in URL; extract `<a>` links with `/2026/` paths. |
| Hacker News (Firebase API) | `https://hacker-news.firebaseio.com/v0/topstories.json` then `item/{id}.json` | Filter top 50 stories by AI keywords. Fast, reliable. Great for signal vs. noise. |
| Company blogs | OpenAI `openai.com/news/`, Anthropic `anthropic.com/news`, DeepMind `deepmind.google/discover/blog/`, Microsoft `blogs.microsoft.com/ai/` | Often don't have working RSS. Scrape directly. |

**RSS feeds (fallback only, expect failures):**
- `https://feeds.arstechnica.com/arstechnica/index` — rarely works, but the HTML page is reliable
- ArXiv: `https://arxiv.org/rss/cs.AI`, `cs.LG`, `cs.CL` — often returns tiny unparseable files

### 3. Scraping Technique

Use `execute_code` with Python — NOT `blogwatcher-cli` (that's for tracked RSS feeds, not general web scraping).

**Pattern for each article:**
```python
import subprocess, re

def fetch_article(name, url):
    r = subprocess.run(['curl', '-s', '-L',
        '--user-agent', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
        url, '--max-time', '15'], capture_output=True, text=True)
    html = r.stdout
    
    og_title = re.search(r'<meta property="og:title" content="([^"]+)"', html)
    og_desc = re.search(r'<meta property="og:description" content="([^"]+)"', html)
    date = re.search(r'<time[^>]*datetime="([^"]+)"', html)
    paras = re.findall(r'<p[^>]*>([^<]{50,500}?)</p>', html, re.DOTALL)
    
    title = og_title.group(1) if og_title else 'N/A'
    desc = og_desc.group(1)[:300] if og_desc else 'N/A'
    dt = date.group(1)[:10] if date else 'N/A'
    
    meaningful = []
    for p in paras:
        clean = re.sub(r'<[^>]+>', '', p).strip()
        clean = re.sub(r'\s+', ' ', clean)
        if len(clean) > 80 and len(clean) < 600:
            meaningful.append(clean)
    body = ' '.join(meaningful[:3])
    
    return {'title': title, 'desc': desc, 'date': dt, 'body': body}
```

**HN filtering pattern:**
```python
# Get top 50 stories, filter by AI keywords
ids = json.loads(subprocess.run(['curl', '-s', 
    'https://hacker-news.firebaseio.com/v0/topstories.json'], 
    capture_output=True).stdout)[:50]
for story_id in ids:
    story = json.loads(subprocess.run(['curl', '-s',
        f'https://hacker-news.firebaseio.com/v0/item/{story_id}.json'],
        capture_output=True).stdout)
    if any(kw in story.get('title','').lower() 
           for kw in ['ai','llm','gpt','claude','gemini','neural','model','openai','deepmind','anthropic']):
        # use story['title'], story['url'], story['score']
```

### 4. Story Selection Criteria

Prioritize **high-impact, technically grounded** developments:
- Major model releases or capability jumps
- Policy/regulation with direct engineering implications
- Infrastructure bottlenecks (power, GPU supply, networking)
- Company strategy shifts affecting developer ecosystems
- Funding/acquisitions that signal market direction
- Real-world deployment stories (healthcare, finance, robotics)

**Avoid:** opinion pieces without technical substance, price/ticker movements without strategic context, vague "AI is changing X" trend pieces.

### 5. Briefing Format

Write in this exact structure:

```markdown
### 🧠 AI News Brief – YYYY-MM-DD – [Morning|Evening] Edition

#### 1. Top Headlines (3–5 items)
- **Headline** — 2–3 sentence summary. Why it matters (technical + business impact).
  → [Source Name](URL)

#### 2. Deep Dive (1–2 key stories)
- Detailed explanation with technical context.
- Real-world implications for practitioners.

#### 3. Tools & Releases
- New tools, APIs, or platforms. Include links and short descriptions.

#### 4. Market & Trends
- Investment, partnerships, strategic moves.

#### 5. Quick Bytes
- 5–10 short bullet updates.

#### 6. Personal Insight
- Short expert analysis for engineers, DevOps, cloud architects.
- Include actionable insights.
```

### 6. Output & Saving

- Save to: `~/.hermes/cron/output/ai-news-briefing/YYYY-MM-DD-[morning|evening].md`
- Create the directory if it doesn't exist: `mkdir -p ~/.hermes/cron/output/ai-news-briefing`
- Morning edition: 6 AM local time, Evening edition: 6 PM local time

### 7. Rules

- Only include items from the last 24 hours (or within the same calendar day for evening)
- Prioritize signal over noise
- Avoid repeating morning edition items unless there's material new information
- Cite/link every tool/release and major claim
- If fewer than 3 truly important items exist, say so rather than padding
- Keep tone concise, factual, and non-hypey
- Do not repeat points within the briefing

### 8. Pitfalls

- **RSS feeds mostly fail.** Don't waste time debugging RSS parsers. Move to direct HTML scraping immediately.
- **Company blogs have sparse/no dates.** Scrape the main blog page and check for dates or sort by recency manually.
- **ArXiv papers have multi-day delays.** Most "new" papers on ArXiv were submitted 2–3 days ago. Only include if they're clearly tied to a major announcement.
- **The Verge routing.** The Verge's AI section often serves the same page regardless of date URL parameter. Extract article links from the page's hrefs with `/2026/` path segments.
- **Paragraphs are messy.** Body text often contains nav elements, ads, subscription prompts. Filter for `<p>` tags with content >80 chars and <600 chars.
- **Avoid padding.** If today was genuinely light on AI news, say "Today was a quiet day with no major AI developments" rather than inventing stories.

---

linked_files:
  - references/sources.md
  - references/briefing-template.md
