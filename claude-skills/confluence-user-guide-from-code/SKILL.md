---
name: confluence-user-guide-from-code
description: Use when asked to review, rewrite or "make customer-ready" a Confluence page (wiki.eisgroup.com) that documents a tool, and the text must match a code version - "review the docs and update them", "make sure it matches tag vX", "improve the wiki for users", "update only the automated/new section, keep the manual part", "add diagrams from Lucid to the page", "use Confluence macros". Covers the fact-check against a tagged export, rewriting one section while proving the rest is untouched, safe publish + read-back, Lucid diagrams as attachments, and what reviewers always find in documented destructive steps. Reference run COINT-21712 (4 drafts, account-vending v3.0.0, 2026-11-17).
---

# Confluence user guide checked against code

Reference run: COINT-21712, drafts 932185107/109/066/067, account-vending `v3.0.0` + client template `v3.1.0`, 2026-11-17. 58 wrong or missing items found in text that already "looked done". Memory: `coint21712_automated_way_wiki_review_2026_11_17`, `feedback_wiki_drafts_additive_keep_manual`, `confluence_wiki_token_and_search`.

## Order of work
1. **Snapshot.** `confluence-section-publish.py fetch <id> --out <dir>` per page. Keep the JSON: it is the backup and the equality baseline.
2. **Export the tag, never the checkout.** `git -C <repo> fetch --tags`, then `git archive <tag> | tar -x -C <scratch>/<name>`. The local checkout is often dirty or on another branch.
3. **Fact-check before writing.** One read-only agent per page (parallel): every claim in the page vs the export, with `file:line`. Ask for three lists: wrong, in code but missing, in the old text and still valid. Also ask what in the old text is wrong so it is not copied. Spot-check the surprising findings yourself (2-3 greps).
4. **Rewrite with a generator**, not by hand-editing storage XML: a small Python file with a mini-markup (backticks -> `<code>`, `**bold**`, `[[key|text]]` page link, `{{Colour:TITLE}}` status) and helpers for table / code / info / tip / note / warning / expand. Every later fix is then a one-line edit + rebuild.
5. **Publish** with `~/.claude/scripts/confluence-section-publish.py publish <id> --snapshot <dir>/<id>.json --new-head <file> --marker '<h1>Manual way' [--attach x.png]` (refuses when the page changed since the snapshot; asserts the kept part is identical; parses the XML first; uploads attachments). Then `verify` (exit 1 on a changed kept part, render error or link to a missing page). `fetch` + `verify` are live-proven (2026-11-25, page 932185107); the `publish` path of this file is selftest-only so far: first real use, check the version line. Plain splice with no attachments on a "Manual way" draft: `wiki-draft-swap-auto.sh <id> <version> <file>` also works.
6. **Look at every page in a browser**, not only `body.view`. Image at `ac:width="820"` fits the content column; 1000 overflows.
7. **Diagrams:** skill `lucid-aws-architecture-diagram`. Export each page PNG, attach, link the Lucid document under the image as the editable source.

## Page pattern that worked
- Numbered headings `A1. ...` + `toc` macro with `include` = `^A[0-9].*` so the kept (old) section stays out of the TOC.
- Top: one-row navigation table across the pages with a `status` lozenge on the current one; "At a glance" side-header table.
- Tables for questions, results, errors ("You see" / "Do"); `expand` for reference detail; `code` macro with a title for command groups; `warning` for anything that deletes or costs money.
- Neutral example customer, never a real one.

## What the fact-check and the reviewers found every time
Check these before the first publish; they cost 9 review rounds on the reference run.
- **Destructive recipe** (cleanup, delete, rename): which credentials does the script really use (follow the session code to the client constructor)? Derive ids from the tool's own file, never "type the account id". Add a check that proves WHICH account, say when the script deletes without asking, say when it exits 0 after a failed delete, add a check after it.
- **Flags that widen scope**: a per-run flag (`--allow-destroy`) applies to every later layer; recommend the narrow form (`--only`). `--yes` variants: say exactly which question they skip.
- **The tool's own messages** can suggest the unsafe flag: quote the message and tell the user what to do instead.
- **Exit codes and last lines** of the wrapper differ from the inner tool (wrapper exits 0 on "paused").
- **Re-run and recovery order**: what does a re-run ask again; what state is lost by "change an answer" (ids emptied), and how to get it back.
- **Exact strings**: prompts, error texts, default values, group names (full name with domain), stage order as executed, not as numbered.
- **Carried-over claims** (timings, "verified live"): label as owner statements or re-prove.

## Traps
- `jq -r '.body.storage.value' > file` adds a newline: equality with the live body then fails. Read the JSON.
- Stripping tags to read a page deletes `<placeholders>` inside CDATA: grep the raw storage before calling a placeholder missing.
- `body.view` always contains `data-unresolved-comment-count`: do not count "unresolved" as broken links; count `createlink`.
- iac harness hook R3 denies a Bash command whose TEXT contains `atlantis apply` / `atlantis unlock` (even inside a heredoc that edits a doc generator). Make that edit with the Edit tool.
- Blast Radius holds `rm -f <glob>` in the scratchpad: write to a new folder instead of clearing one.
- The scratchpad is cleared between sessions: generator, backups and evidence are gone. Copy what must survive into `~/.claude/scripts` or the ticket's docs folder before the session ends.

## Council on a docs task
Skill `council-review-evidence-pack`. Extra for docs: pack = verdict table + checks + fact-check table + the new sections read back from the live page + copies of every code file the text cites. 20 files or fewer, each under 250 lines, no images (text description of diagrams instead). Bigger packs returned "INVALID: no JSON object". Reviewers cannot run anything: scores stall around 8-9 while "not run live" stays true; say so to the user early instead of spending rounds.

## Hand-back
Page links + versions before/after, what is proven (kept part identical, render, gitleaks on the bodies), what was not run live, tool-side risks found (for the tool owner), rollback = page history versions.
