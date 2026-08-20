#!/usr/bin/env python3
"""Mechanical pre-publish verification for a batch of markdown deliverables.

Point DRAFTS at the staging dir and run. Every check below caught a real defect on the reference
run; the R-ID/reference-coverage check caught two docs that cited requirement IDs they never used.

Adapt REQUIRED_HEADER / BANNED / the reference regex to the repo's own conventions.
"""
import glob, os, re, sys

DRAFTS = sys.argv[1] if len(sys.argv) > 1 else "/path/to/scratch/drafts"
REQUIRED_HEADER = ["**Source:**"]                  # lines that must appear in the first 8 lines
DIAGRAM_HINTS = ("11-diagrams", "diagrams/drafts")  # these additionally need Status + target doc
DIAGRAM_HEADER = ["**Status:**", "Target Lucid"]
REF_RE = re.compile(r"R-[A-Z]+-\d+")               # the repo's requirement-ID shape
BANNED = ["note that", "it should be noted", "unfortunately", "no longer"]  # caveat phrasing
BANNED_NAMES = []                                   # names the user said not to mention
LINE_BAND = (60, 160)

bad = []
for f in sorted(glob.glob(os.path.join(DRAFTS, "**", "*.md"), recursive=True)):
    name = os.path.relpath(f, DRAFTS)
    t = open(f).read()
    lines = t.splitlines()
    head = "\n".join(lines[:8])
    body = t[t.find("\n---") + 1:] if "\n---" in t else t

    if not lines[0].startswith("# "):
        bad.append((name, "no H1"))
    for req in REQUIRED_HEADER:
        if req not in head:
            bad.append((name, f"header missing {req}"))
    if any(h in name for h in DIAGRAM_HINTS):
        for req in DIAGRAM_HEADER:
            if req not in head:
                bad.append((name, f"header missing {req}"))

    # every reference claimed in the header must actually be used in the body
    m = re.search(r"\*\*Satisfies:\*\*(.*)", head)
    if m:
        missing = [i for i in REF_RE.findall(m.group(1)) if i not in body]
        if missing:
            bad.append((name, f"claimed but never cited: {missing}"))

    if "```hcl" in t or re.search(r'^\s*resource "', t, re.M):
        bad.append((name, "code block the repo bans"))
    for p in BANNED:
        if p in t.lower():
            bad.append((name, f"caveat phrasing: {p!r}"))
    for w in BANNED_NAMES:
        if w.lower() in t.lower():
            bad.append((name, f"mentions {w}"))
    if "Open questions" not in t:
        bad.append((name, "no Open questions section"))
    if not LINE_BAND[0] <= len(lines) <= LINE_BAND[1]:
        bad.append((name, f"{len(lines)} lines outside band {LINE_BAND}"))

    for b in re.findall(r"```mermaid(.*?)```", t, re.S):
        sg = len(re.findall(r"^\s*subgraph ", b, re.M))
        en = len(re.findall(r"^\s*end\s*$", b, re.M))
        if sg != en:
            bad.append((name, f"mermaid subgraph/end {sg}/{en}"))
        if b.count("[") != b.count("]") or b.count('"') % 2:
            bad.append((name, "mermaid bracket/quote imbalance"))

    print("%-58s %4d lines" % (name, len(lines)))

# twin/mirror files must share their heading skeleton
seen = {}
for f in glob.glob(os.path.join(DRAFTS, "**", "*.md"), recursive=True):
    seen.setdefault(os.path.basename(f), []).append(f)
for base, fs in seen.items():
    if len(fs) == 2:
        a, b = [re.findall(r"^## .*", open(x).read(), re.M) for x in fs]
        diff = [x for x in a if x not in b] + [x for x in b if x not in a]
        if len(diff) > 2:      # one level-adapted heading per side is fine
            bad.append((base, f"twin skeletons diverge: {diff}"))

print("\nISSUES:", *(["  %s: %s" % x for x in bad] or ["  none"]), sep="\n")
sys.exit(1 if bad else 0)
