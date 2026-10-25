# Shared brief for <PARENT> sub-task agents (<topic>)
<!-- Template from COINT-21561 (2026-10-21). Replace every <...>. Agents do NOT write to Jira (hook R12); the user publishes. -->

You own ONE problem P<n>. For it you produce: one Markdown doc + PDF, one Lucid document (one page per option + a "Recommended" page), PNG exports, and a Jira payload `create.json`. **No Jira POST/PUT of any kind**: hook R12 denies them and the user publishes with `~/.claude/scripts/jira-subtask-publish.py`. Read-only Jira GETs are fine.

Workdir: `D=<scratchpad>/<slug>`, yours = `$D/P<n>/`. Research basis: `$D/research.md`. Read it in full and stay consistent with it. If your re-verification contradicts it, say so explicitly in the doc and in your return block.

Read-only everywhere else: no repo edits, no git, no MRs, no AWS/kubectl mutations. Read-only CLI is fine. Prod-guard hook blocks reading `*/upper/prod/*`: cite memory/ADR instead and say so. Shell = zsh, fresh per call, BSD tools. Write file content with Write, not Bash heredocs (hook R15 false positives).

## 1. Doc `$D/P<n>/P<n>.md`
Title `# <PARENT> P<n> — <title>`. Sections, in order:
1. **Problem**: 2-5 sentences, including why it matters.
2. **Facts and constraints**: bullets, each with a source (doc URL, repo path, decision id, memory path, or live CLI) and a tag `PROVEN` / `UNPROVEN`.
3. **Options**: one `###` per option, covering:
   - how it works
   - diagram `![Option X](P<n>-<page>.png)`
   - pros, cons, risks
   - effort (S/M/L)
   - status PROVEN/UNPROVEN
4. **Comparison** table: rows = criteria, columns = options.
5. **Recommendation** + why + `![Recommended](P<n>-recommended.png)`.
6. **Open questions / decisions**, each with an owner.
7. **Acceptance criteria** for this sub-task, as a checkbox list.
8. **Next steps**, ordered.
9. **Sources**.

Terse, technical, no filler. Every number and name must be traceable.

PDF: `python3 -I ~/.claude/scripts/md2pdf.py $D/P<n>/P<n>.md $D/P<n>/P<n>.pdf`. Run it after the PNGs exist; images are referenced relative to the md. Check page 1: `pdftoppm -r 60 -f 1 -l 1 -png P<n>.pdf $D/P<n>/chk`, then Read the PNG with `limit: 300`.

## 2. Lucid
- **Load tools** via ToolSearch: `get_mcp_resource`, `lucid_create_diagram_from_specification`, `lucid_validate_diagram_specification`, `lucid_export_document_as_PNG`, `lucid_create_document_share_link`, `lucid_update_document`, `lucid_load_script_documentation`, `lucid_run_script` (server prefix `mcp__6c33f820-0f6a-4523-ab73-332ce464f9d1__`).
- **MANDATORY before the first create:**
  - Read `lucid://skills/readme`, `lucid://skills` and `lucid://skills/diagram-specification`.
  - Read `~/.claude/skills/lucid-aws-architecture-diagram/SKILL.md` and follow its overlap rules. Its `gen_*.py` generators are examples.
- **One document** titled `<PARENT> P<n> <title>`. Create has no folder argument: move it into folder <folder id> with `lucid_update_document(parent=)`.
- **Keep each spec ≤45 KB.** An ~87 KB spec created only the headings.
- **Pages:** one per option (title "Option <id>: <name>") plus one "Recommended".
  - Option pages show components and flows, a red risk box and a green pros box.
  - Explicit font sizes everywhere.
  - Ids must be unique across pages; prefix line ids.
  - Library shapes only; never guess class names.
- **Export** each page to `$D/P<n>/P<n>-<page>.png` (`opt-a`, `opt-b`, …, `recommended`).
  - LOOK at each PNG (Read with `limit: 300`) and fix overlaps with a basecanvasediting script.
  - If you recreate the document, rename the old one `OLD DRAFT (delete)` and report it.
- **Share link:** create a view link and report it.

## 3. Jira payload (no writes)
- **`$D/P<n>/create.json`:**
  ```json
  {"fields":{"project":{"id":"<pid>"},"issuetype":{"id":"<subtask type id>"},"parent":{"key":"<PARENT>"},
  "summary":"<exact summary from your brief>","components":[{"name":"<comp>"}],"priority":{"name":"<prio>"},
  "<required customfields copied from parent>":{"id":"<opt id>"},"assignee":{"name":"<user>"},
  "labels":["<label>"],"description":"<wiki markup>"}}
  ```
  Build it with `python3 -I` into the file (json.dump). Never hand-escape.
- **Description is Jira wiki markup, not Markdown:** `h2.` headings, `||h||h||` / `|c|c|` tables, `*bold*`, `{{code}}`, `[text|url]`, `* bullet`.
  - Content: Problem, Options (1-3 lines each), Comparison table, Recommendation, Open questions/owners, Acceptance criteria, Lucid link.
  - End with the note "Full doc: attached P<n>.pdf / P<n>.md".
- **`$D/P<n>/recommendation.txt`:** one line, used in the parent table.
- **Attachments are picked up by name:** only `P<n>.md`, `P<n>.pdf` and `P<n>-*.png`. Other helper files are ignored.

## 4. Return block (your final message, exactly this shape)
```
P<n> | key=PENDING-PUBLISH | payload=$D/P<n>/create.json
lucid=<share url> | doc_id=<id> | folder=<id yes/no> | pages=<n>
files=<P<n>.md,P<n>.pdf,P<n>-*.png ready> | description=<chars> wiki
facts: PROVEN=<count> UNPROVEN=<count>; contradictions with research.md: <none|list>
recommendation: <one line>
issues: <none|list>
```
