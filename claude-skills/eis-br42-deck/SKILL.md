---
name: eis-br42-deck
description: Use when building or editing a slide deck in the EIS "Big Reveal" (BR42) template with pptxgenjs, or whenever a deck must render correctly in LibreOffice Impress (fonts, QA renders, PDF fallback). Covers the template tokens, layout helpers, the headless-LibreOffice font trap, the visual QA loop, and the rules for talks that are filmed (no client names, recounted numbers). Also use when asked to review a deck, cut it to a time slot ("we have 35 min"), or "watch the videos" linked or embedded in it. Also use to edit an existing .pptx in place (add a panel to slides N-M, update stale counts), to build a one-slide deck, or to make one real-example slide per harness block.
---

# EIS Big Reveal (BR42) decks

Reference builds in `~/Documents/presentations/big-reveal-42/build/`: `build-deck.js` (40-min talk), `build-history.js` (concept/history deck, 11 slides), `build-topics.js` (13-block reference deck, 17 slides). Copy the helper block at the top of any of them (`chrome`, `kicker`, `title`, `lede`, `foot`, `box`, `txt`, `dot`, `terminal`). Assets are in `build/assets/` (`eis-logo.png`, `watermark.png`). `pptxgenjs@3` is installed in `build/`.

## Turning a generic (ShareGPT-style) deck into a BR42 deck
Users hand over decks in someone else's design and ask for "our own design". Don't recolor them: extract the text with `markitdown`, then rebuild.
1. **Group before you lay out.** 13 flat topics became 5 groups (Guide / Enforce / Scale / Connect / Prove) with one accent color each, shown on an overview "map" slide and in each slide's kicker (`> BLOCK 03 OF 13 · ENFORCE`).
2. **One strong template per repeated topic**, not 13 different layouts: left column WHAT / WHY / WHO (mono label + 11 pt text), right column a vertical FLOW card (4 pill nodes on a line, last one filled), an EXAMPLE strip bottom-left, an "AT EIS" card bottom-right. Vary only the group color.
3. **Add a synthesis slide** ("one request passes through all N blocks") and a one-line takeaway slide. Both must use the same group assignment and colors as the map: a block filed under "Ask" on one slide and "Enforce" on another was caught only on review.
4. **History/concept decks**: a timeline infographic (year, name, tag, one line per node, plus a clearly-labelled illustrative bar strip), then a what-it-adds / risks / needs grid, then what / why / how, a worked example, and a conclusion. Verify every date against a primary source; show only the year when the source can't be fetched.

## "At EIS" grounding (only verified facts)
Never invent an EIS-named artifact to make a generic example feel local (a source deck's "EIS Platform Plugin" became "a platform plugin ships…"). Pull each "At EIS" line from disk the same day:
- counts: `demo/recount.sh` (skills, memory notes, deny/ask, hooks, sessions, score)
- agents: `ls ~/.claude/harness/iac/agents` and check each agent's tool list (no Edit/Write tool = "none has an edit or write tool")
- workflows: `ls ~/.claude/harness/iac/workflows`; MCP guard: header of `hooks/guard-mcp.sh`
- plugins: count the entries whose value is `true`, not the keys: `jq '[.enabledPlugins|to_entries[]|select(.value==true)]|length' ~/.claude/settings.json` (it drifts fast: 23 enabled on 09-30, 67 enabled / 73 keys on 10-06)
- eval: `HARNESS-EVALUATION.md` (state the corpus is our own)

## Template tokens
- Canvas: `pres.layout = "LAYOUT_16x9"` = **10 x 5.625 in** (not 13.33 x 7.5; `LAYOUT_WIDE` is the big one).
- Colors: NAVY `0F0F46` (background), PANEL `1A1A5C`, INK `0B0B33`, LINE `34346E`, ORANGE `F45D01`, MINT `3ACEA9`, LAV `D0D0E8`, MUTED `9A9ABA`, RED `FF6B6B`, AMBER `F4B93C`. Orange = the old/capability/concept side, mint = control/EIS side.
- Fonts: **Spline Sans** (titles, body) + **Courier New** (kickers, labels, code). Spline Sans has **no italic**: never set `italic`, it falls back to a different serif.
- Chrome: logo x.54 y.44 w.75 h.24; "THE BIG REVEAL" mono 7 pt right-aligned at x7.75 y.46; orange "42" at x9.29; white rule at y5.04 (w 9.18); optional watermark x6.77 y2.89 w3.96 h3.36 `transparency: 93` (title, closing and demo slides only; it fights text elsewhere).
- Type: kicker `> LABEL` mono 9 mint; title 22-24 bold orange at y1.10; lede 13 lavender at y1.62; body 10.5-14; footnote mono 8 at y4.66. Aim for <= ~100 words a slide, one idea each.

## pptxgenjs traps (all hit in practice)
- Fresh option objects per call (it mutates them). `margin: 0` + `isTextBox: true` on every text box. No `#` in colors. No gradients.
- Text boxes do not auto-shrink: a label that wraps will collide with the text under it. Give two-line room or shorten the label, then look at the render.
- Non-breaking space (` `) keeps `terraform apply` on one line.
- Speaker notes (`s.addNotes`) carry the spoken script and a timestamp range per slide.

## Rendering in LibreOffice (the font trap)
Headless LibreOffice only sees fonts placed in its profile's `user/fonts/`. The skill wrapper `soffice.py` (svp backend, temp profile) and a bare fresh profile both silently substitute Liberation/Linux Libertine for Spline Sans AND Courier New, so previews lie about widths. Use a persistent profile with the fonts copied in:

```bash
PROF=$SCRATCH/lo_profile; mkdir -p "$PROF/user/fonts"
cp ~/Library/Fonts/SplineSans-*.ttf "$PROF/user/fonts/"
cp "/System/Library/Fonts/Supplemental/"{"Courier New","Courier New Bold","Courier New Italic",Arial,"Arial Bold","Arial Italic"}.ttf "$PROF/user/fonts/"
soffice -env:UserInstallation=file://$PROF --headless --convert-to pdf deck.pptx
pdffonts deck.pdf   # must list SplineSans-Regular/Bold and CourierNewPS*, not Liberation*
```
Spline Sans comes from google/fonts `ofl/splinesans/SplineSans[wght].ttf` (variable, OFL). Cut static weights with fontTools (`pip install fonttools` in a venv): `instancer.instantiateVariableFont(font, {"wght": 400|500|600|700}, updateFontNames=True)`. Regular and Bold keep family "Spline Sans" (Bold links via style), which is what the slides reference. Install to `~/Library/Fonts`; quit and reopen LibreOffice once.

## QA loop (do it, the first render always has defects)
1. `python3 <pptx-skill>/scripts/office/validate.py deck.pptx` must pass.
2. Render PDF as above, `pdftoppm -jpeg -r 110`, tile 4 slides per sheet with PIL (2x2), and look at every sheet. Re-render only changed slides after fixes.
3. The Read tool's large-file hook miscounts JPEG bytes as lines: pass `limit: 300` when reading images.
4. `markitdown deck.pptx`: every slide has notes, no placeholder text, and grep for client names, 12-digit account IDs, `aws0*` cluster names, internal hostnames.
5. Export a PDF next to the .pptx as the on-stage fallback.

## Reviewing a deck and its videos for a time slot
Used 2026-10-06 when a 45-slide merged deck had to fit a 35-min slot.
1. Text + notes: `markitdown deck.pptx > deck.md`; read it in 340-line chunks (the Read hook blocks files over 350 lines).
2. Hidden slides: `grep -l 'show="0"' unpacked/ppt/slides/slide*.xml`. Hidden slides still ship in the file: grep them for client names too.
3. Time math: add up the `[N minutes]` tags in the notes for visible slides, plus video durations (`ffprobe -show_entries format=duration`). Budget = slot minus Q&A, then plan about 20% under it for clicks and video starts.
4. Videos: a Google Slides export turns an embedded Drive video into a poster picture plus a `drive.google.com` hyperlink (`grep drive.google.com ppt/slides/_rels/*.rels`). The poster is the first frame, often black. On stage that link opens a browser, so play the local MP4 instead. Match the Drive link to the local file by the poster image and the resolution.
5. Watching a video: `ffmpeg -i v.mp4 -vf "fps=1/10,scale=960:-1,tile=3x3" grid-%02d.jpg` for narrated clips; for terminal recordings use `fps=1/6` and 2x2 tiles so the text stays legible. Transcribe with `ffmpeg -i v.mp4 -ar 16000 -ac 1 a.wav`, then `whisper-cli -m "$HOME/Library/Application Support/LocalFlow/models/ggml-large-v3-turbo-q5_0.bin" -f a.wav -l en -otxt -of t` (about 1 min for 4.5 min of audio; run it in the background). Animated counters lie mid-frame: sample at 1 fps around a suspicious number before flagging it (a ring read 33% but ended at the correct 46%).
6. Cross-check every number across the video, the slides and today's `recount.sh`. A video cut a week earlier will disagree (90/265/84 against 107/296/85): fix the slide, or say one line on stage.
7. Cut order: generic history and concept slides first; then definition slides whose "real example" twin already carries a WHAT IT IS line; then the lower-value examples. Keep **one** taxonomy: 7 layers, 5 layers in the video and 13 blocks in the deck confused the story.
8. Move backup slides to the end and retag any "BACKUP" slide that is actually main content.

## Editing a finished deck in place (user hands over a .pptx and says "add X to slides N-M")
Do NOT rebuild with pptxgenjs: unzip, edit `ppt/slides/slideN.xml`, re-zip. Worked 2026-10-05 on slides 16-28 of "the one.pptx" (file number == slide position there; assert it from the title text).
1. `markitdown` the deck, find the shared geometry (the 13 block slides are identical: WHAT/WHY/WHO rows, EXAMPLE box, FLOW pills, AT EIS card; free space is only y 4.6-5.0).
2. Move shapes with a regex over `<p:sp>`/`<p:cxnSp>` keyed on original (x, y) inches, tolerance 0.015, and `assert moved == 21` per slide so a layout drift fails loudly. Squeeze rows (pitch 0.66 -> 0.48, FLOW pills 0.33 -> 0.25) and free a full-width strip at y 4.2-4.94 above the rule at y 5.04.
3. Append new shapes before `</p:spTree>` with unique ids (9001+). A "REAL DATA" strip = INK roundRect with an ORANGE border + mono 8 pt lines (<= ~104 chars at 7.4 in wide; 4 lines max) + a mono label/source column. Slide text stays Spline Sans, panel text Courier New.
4. Never `rm -rf` the unpack dir (guard R11 text-scans it, even in the scratchpad): unpack into a fresh dir name each time.
5. Pack with `zip -Xqr` from INSIDE the dir, run `validate.py out.pptx --original deck.pptx`, render, look. Save as a NEW file (`... - real examples.pptx`), never overwrite the user's original.
6. **Stale numbers**: after `demo/recount.sh`, replace the exact phrases in `ppt/slides/*.xml` AND `ppt/notesSlides/*.xml` (the same sentence lives in both), print per-file hit counts, then `markitdown | grep` for every old value. Counts also hide on the B2 backup slide ("97 skills, 265 memory notes") and in footnotes ("Counts as of 30 Sept"), not only on the block slides.

## One real example per block (13 slides, uniform layout)
`build/build-block-examples.js` builds `EIS-Harness-Block-Examples-BR42.pptx` (+ .pdf): kicker `> BLOCK NN OF 13 · GROUP · REAL EXAMPLE`, title 22 pt, lede 11 pt, left 3 cards (WHAT IT IS / IN THIS EXAMPLE / TAKE-AWAY, x .54 w 3.3, h .92, last card has the group-color border), right INK terminal (x 4.02, y 1.9, h 3.04) with a `SNAPSHOT <path>` header. Snapshot markup: `m|` muted line, `g|` mint bold line, `[[x]]` orange inline, `[...]` = text omitted from the original. Mono font is picked as the largest of 9.5..7 that fits (`maxLen*f*0.6/72 <= width` and `lines*f*1.2/72 <= height`); ~20 lines x ~85 chars is the ceiling at 7.5 pt. Reuse its helper block (`snapRuns`, `build(b)`) for any new snapshot-style deck.
Chosen examples (all read from disk the same day, all free of client names): Rules `rules/terraform.md` · Skills `iac-apply-disruption-check` (body lines only, its frontmatter cites a client) · Hooks `guard-bash.sh` header + deny JSON + `harness.log` line + selftest · Workflows `iac-mr-review.js` meta + 8 lens keys · Agents `tf-plan-auditor.md` (tools line) · Evaluation `HARNESS-EVALUATION.md` + `eval-suite.sh` header · Settings `permissions.deny/ask` · Memory `s3_versioned_bucket_purge.md` + its index line · Plans the generic disk-cleanup plan (the other saved plans name clients) · Plugins `jq` count + `ls .claude` · Scripts `verify-changes.sh` header · MCP `guard-mcp.sh` header + a DENY-MCP line · Observability `harness.log` counts + 4 lines (cut branch names that carry a ticket slug).
Scrub rule: before shipping run `markitdown deck.pptx | grep -ciE 'aws0|caa|axa|nnl|bedrock|cash|[0-9]{12}|eqxdev|eis-iac/'` and expect 0; also drop `projects/aws/eis-iac/terraform` from rule excerpts.

## Single-slide builders (user asks "one slide about X")
Copy the helper block, one `pres.addSlide()`, `node build/build-<x>-slide.js`. Existing: `build-infra-slide.js` (3 swimlanes: ArgoCD / Terraform+Atlantis / Ansible, last box of each lane is the target, AWS lane has up/down arrows "creates the EKS clusters / EC2 hosts"), `build-terraform-rule-slide.js`, `build-hooks-slide.js`. Lane geometry that fits: lanes y 1.9, h .66, gap .22; 5 boxes w 1.28 flush to x 9.72; take-away strip y 4.44-4.94. Hyphenated words ("self-heal") break mid-word in boxes: reword rather than shrink. Each slide gets speaker notes and a PDF next to it.

## Environment traps hit building these
- macOS `sed -i` needs `sed -i ''`; an `&&` chain silently stops at the failure.
- zsh: a bare `=====` in `echo` is `=cmd` expansion and aborts the call: quote it.
- LibreOffice: the real binary is `/Applications/LibreOffice.app/Contents/MacOS/soffice` (also `/opt/homebrew/bin/soffice`); with `-env:UserInstallation=file://$SCRATCH/lo_profile` and fonts copied in, `pdffonts` shows SplineSans + CourierNewPS. The pptx-skill `soffice.py` wrapper is fine for quick shape checks but not for font-true widths.
- `build/` is NOT in git (and `~/Documents/presentations` is outside the claude-config backup): copy new build scripts into `~/.claude` or a repo if they must survive.

## Filmed-talk rules
- Counts and mechanisms only. Never a client name, account ID, cluster name or hostname on a slide or in notes.
- Every number comes from a recount, not from an old deck (they drift in days: ask-a-human rules went 37 to 76 in two weeks). Keep a `recount.sh` that prints each number with its slide, and put the recount date in a footnote.
- Never claim the guard "parses" commands: it normalizes then pattern-matches. Say so, and say it is not a sandbox.
- Deliverables go to `~/Documents/presentations/`, never only to `/private/tmp` (wiped between sessions). Send them with SendUserFile.
