#!/usr/bin/env python3
"""Blind the arm notes for the scorer: random cell letters, run-detail footers stripped (token counts would reveal
which arm has skills). Writes score-input/cell-<L>.json + a PRIVATE blind-map.json (never given to the scorer) and
metrics.json (tokens/time per arm from footers + job durations). usage: prep_score.py"""
import json, os, random, re, glob

R = os.environ.get("ARMS_DIR", os.getcwd())
os.makedirs(f"{R}/score-input", exist_ok=True)
labels = [os.path.basename(p)[len("arm-notes-"):-5] for p in sorted(glob.glob(f"{R}/arm-notes-*.json"))]
letters = list("ABCDEFGH")[:len(labels)]
random.Random(447327).shuffle(letters)
bmap = dict(zip(labels, letters))
json.dump(bmap, open(f"{R}/blind-map.json", "w"), indent=1)
metrics = {}
for lab in labels:
    d = json.load(open(f"{R}/arm-notes-{lab}.json"))
    cell = {"cell": bmap[lab], "mrs": {}}
    m = {"tokens_in": [], "tokens_out": [], "secs": [], "notes": 0}
    for mid, rows in d["mrs"].items():
        out = []
        for r in rows:
            body = re.split(r"\n\s*<details>\s*<summary>\s*⚙️|⚙️ Agent run details|Agent run details", r["body"])[0]
            out.append({"kind": r["kind"], "body": body.strip()})
            m["notes"] += 1
            for k, f in (("tokens_in", "tokens_in"), ("tokens_out", "tokens_out"), ("secs", "secs")):
                if r[f] is not None:
                    m[k].append(r[f])
        cell["mrs"][mid] = out
    json.dump(cell, open(f"{R}/score-input/cell-{bmap[lab]}.json", "w"), indent=1)
    metrics[lab] = {**{k: (sum(v) / len(v) if v else None) for k, v in m.items() if isinstance(v, list)}, "notes": m["notes"]}
json.dump(metrics, open(f"{R}/metrics.json", "w"), indent=1)
print("cells:", len(labels), "| blind map written (private)")
