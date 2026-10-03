---
name: eis-br42-deck
description: Use when building or editing a slide deck in the EIS "Big Reveal" (BR42) template with pptxgenjs, or whenever a deck must render correctly in LibreOffice Impress (fonts, QA renders, PDF fallback). Covers the template tokens, layout helpers, the headless-LibreOffice font trap, the visual QA loop, and the rules for talks that are filmed (no client names, recounted numbers).
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
- plugins: count the entries whose value is `true`, not the keys: `jq '[.enabledPlugins|to_entries[]|select(.value==true)]|length' ~/.claude/settings.json` (24 keys, 23 enabled)
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

## Filmed-talk rules
- Counts and mechanisms only. Never a client name, account ID, cluster name or hostname on a slide or in notes.
- Every number comes from a recount, not from an old deck (they drift in days: ask-a-human rules went 37 to 76 in two weeks). Keep a `recount.sh` that prints each number with its slide, and put the recount date in a footnote.
- Never claim the guard "parses" commands: it normalizes then pattern-matches. Say so, and say it is not a sandbox.
- Deliverables go to `~/Documents/presentations/`, never only to `/private/tmp` (wiped between sessions). Send them with SendUserFile.
