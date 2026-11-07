---
name: jira-draft
description: Use when Ebrahim asks for a Jira comment draft - "/jira-draft KEY", "draft a reply on COEXT-123", "jira draft for X", "answer [~user] on KEY", "close-out comment", "status update on KEY", "ask X for Y in Jira", EISHELP access requests. Reads the ticket, then writes a paste-ready Jira wiki comment in his own voice (skill eramadan-voice). Never posts.
---

# Jira draft

Args: `KEY [intent]` - e.g. `COEXT-112121 status update`, `EISHELP-114645 chase iakimov`, `GENESIS-371697 close`.
No KEY -> ask for it. No intent -> infer from last comments (reply to last person who asked us something, else status).

## Steps
1. Read ticket (GET only):
   ```bash
   python3 -I ~/.claude/scripts/jira-read.py KEY
   ```
   302 to pingidentity = VPN down, say so and stop.
2. Find: who spoke last, what they asked, what is still open, who the draft is to.
   **Stale-intent check first** (2026-11-07: 3/3 requests were stale): ticket Resolved/Closed or the ask already answered -> don't write the requested draft blindly. Say so in one line, then draft the real next action instead: "chase" on a done ticket -> thank-you + the follow-up it implies (e.g. revert/restore request); "close" on a Closed ticket with own close comment -> no draft; "status" on a Resolved ticket -> only the one open item, `<TODO>` if unknown.
3. Get facts for the body from live/session sources, never from memory alone: today's `.remember`, memory notes for KEY, MR state (`glab api`), live read-only checks if a claim needs proof. Fact not verified -> leave `<TODO: ...>` placeholder, never invent.
4. Write in voice from skill `eramadan-voice` (read it). Its rules win over generic caveman draft rules.
5. Pick shape by intent:
   - **Reply / ask** -> `hey [~user] ,` + ask on line 1 + needed inputs as numbered list.
   - **Status** -> `hey [~user]  I wanted to provide a quick update on ...:` + ` * ` bullets + next step.
   - **Done / close** -> `Done.` or result sentence + bullets (versions `a -> b`, IDs, backups, downtime) + `The task can now be closed.` + `CC:` if useful.
   - **Access request (EISHELP)** -> `[~agent]  Can you ...?` + group names in `{{ }}` + members + why, short.
   - **Chase** -> bare `[~user]` + one-line nudge, polite.
6. Self-check before output:
   - First line = ask or status.
   - Mentions `[~username]` exist in ticket (take from comment authors / assignee), not guessed.
   - No "per Ebrahim", no em-dash chains, no `h3.` / big tables to a person, no filler.
   - IDs, hosts, versions, ticket keys exact. Secrets/keys never in body ("send via DM/Vault").
   - Under ~10 lines unless evidence table was asked for.

## Output
One line: who it's to + intent. Then the draft as ONE fenced code block, Jira wiki markup, nothing else in the block.
Then `TODO`s left (if any). Ebrahim posts it himself - never call Jira POST, `jira-comment-once.sh`, or superagent_post_draft.
