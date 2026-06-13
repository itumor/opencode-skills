---
name: linkedin_post_online_research
description: Research technical topics online before drafting LinkedIn posts, prioritizing current primary sources, operator pain points, tradeoffs, and image implications for credible DevOps, cloud, and platform engineering content.
version: 2026-04
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [linkedin, online-research, technical-writing, devops, platform-engineering, social-media]
---

# LinkedIn Post Online Research

Use this skill before writing or improving a technical LinkedIn post when the user wants stronger factual grounding, current source context, or a sharper image concept.

## Research goals
- Verify the technical claim before drafting.
- Find one concrete operator pain point.
- Find one useful tradeoff or caveat.
- Identify one visual angle that adds value beyond the caption.

## Source priority
Use the most authoritative current sources available:
- official product docs
- release notes and changelogs
- project GitHub repositories, issues, discussions, or enhancement proposals
- CNCF or foundation pages
- cloud provider engineering blogs and docs
- respected engineering blog posts only when primary sources are thin

Avoid using generic SEO summaries as evidence unless they lead to a primary source.

## Fallback when the target page is blocked
If the user gives a source page that is Cloudflare-blocked, login-gated, or otherwise inaccessible:
- Do not stall or guess from the blocked page.
- Search for the project’s official docs, changelog, API reference, or README instead.
- Use the public page only as a topic hint, not as evidence.
- Prefer search snippets and docs text that can be verified directly.
- Note the access limitation in `citation_notes` so the drafting step knows the source is indirect.
- If the final LinkedIn post is meant to stay in the CNCF/workbook system, treat the source page as research only; let the workbook topic determine the actual post subject.
- If the page title points to a non-CNCF product but the workbook post should remain CNCF-themed, map the page to the closest workbook row instead of renaming the topic to the external product.

## Research packet
Produce a compact packet with these fields:

```text
topic:
source_urls:
verified_facts:
operator_pain_points:
tradeoffs:
fresh_angle:
image_implications:
citation_notes:
```

Keep each field short. `verified_facts`, `operator_pain_points`, and `tradeoffs` should be bullet lists with source-backed, non-hype wording.

## Drafting handoff
When handing research to LinkedIn writing skills:
- Use 1 to 3 verified facts.
- Put links in notes or a follow-up comment, not the main LinkedIn post body, unless the user asks for links in the post.
- Convert facts into operational stakes: failure modes, cost, deployment friction, incident response, security, adoption, or team ownership.
- Preserve uncertainty. If a source is ambiguous, say what is known and what is inference.

## Text-post handoff for 2026
When the final output is a marketing-only text post, pass research in a way that supports:
- one audience and one message
- a sharp first-line hook
- a proof-backed opinion
- a tradeoff or caveat
- a soft, non-spam CTA
- native LinkedIn writing with no link-first behavior

## Image handoff
For the visual brief, include one of:
- before/after technical diagram
- release or feature sneak-peek card
- decision matrix
- architecture explainer
- failure-mode or tradeoff card

The image should answer a different question than the caption. Prefer diagrams, comparisons, and decision aids over repeating post bullets.

## Quality bar
- Do not invent metrics.
- Do not imply production adoption, benchmarks, or roadmap commitments unless a source supports it.
- Prefer "this helps when..." over "this solves...".
- If sources disagree or are stale, call that out in `citation_notes`.

## Example prompt
"Research Kubernetes v1.36 changes for a LinkedIn post. Prioritize official release notes, KEPs, and operator impact. Return verified facts, tradeoffs, and a visual angle for a decision-card image."
