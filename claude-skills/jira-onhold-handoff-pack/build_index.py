"""build_index.py <pack-dir> KEY [KEY...] -> <pack-dir>/README.md master table from results/<KEY>.json.
Row order = argv order. Links <KEY>.md and <KEY>-diagram.png when present."""
import json, sys, pathlib
d = pathlib.Path(sys.argv[1]); order = sys.argv[2:]
rows = [json.load(open(d / "results" / f"{k}.json")) for k in order]
cell = lambda s: str(s).replace("|", "/").replace("\n", " ")
J = "https://jira.eisgroup.com/browse/"
out = [f"# Task status + on-hold handoff - {d.name}", "",
       "One doc per ticket (`<KEY>.md`), paste-ready Jira comment draft (NOT posted), diagram PNG. Raw rows: `results/*.json`.", "",
       "| Ticket | Jira | State | % | Done | Blocker | Next | Lucid | Doc |", "|---|---|---|---|---|---|---|---|---|"]
for r in rows:
    k = r["key"]
    lucid = " ".join(f"[L{i+1}]({u})" for i, u in enumerate(r["lucid"]))
    doc = f"[doc]({k}.md)" if (d / f"{k}.md").exists() else "-"
    png = f" [png]({k}-diagram.png)" if (d / f"{k}-diagram.png").exists() else ""
    out.append(f"| [{k}]({J}{k}) {cell(r['title'])} | {cell(r['jira_status'])} | {r['state']} | {cell(r['pct_done'])} | {cell(r['summary'])} | {cell(r['blockers'])} | {cell(r['next_step'])} | {lucid} | {doc}{png} |")
out += ["", "## Open MRs", ""] + [f"- {r['key']}: {u}" for r in rows for u in r["open_mrs"]]
out += ["", "## Agent notes (gaps, live leftovers)", ""] + [f"- {r['key']}: {cell(r['notes'])}" for r in rows]
(d / "README.md").write_text("\n".join(out) + "\n")
print(len(rows), "rows")
