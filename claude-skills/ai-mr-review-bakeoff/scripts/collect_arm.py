#!/usr/bin/env python3
"""Collect the CI-bot notes of one arm: notes created in [arm start, arm end + 90 s] by the CI-job bot on each MR.
usage: collect_arm.py arm-<label>.json mr-iids.json   -> arm-notes-<label>.json"""
import json, os, re, subprocess, sys, datetime

PID = int(os.environ.get("ARMS_PID", "1630"))
CI_BOT_PREFIX = os.environ.get("ARMS_CI_BOT", "project_1630_bot_bf0327")      # CI-job reviewer bot (webhook bot is 36cf...)
ENV = {**os.environ, "GITLAB_HOST": "sfo-cvdevopsgit01.eqxdev.exigengroup.com"}
ENV.pop("GITLAB_TOKEN", None)
arm = json.load(open(sys.argv[1])); mrs = json.load(open(sys.argv[2]))
if len(sys.argv) > 3:
    CI_BOT_PREFIX = sys.argv[3]   # e.g. project_1630_bot_36cf for the webhook bot
start = arm["start"]
end = (datetime.datetime.strptime(arm["end"], "%Y-%m-%dT%H:%M:%SZ") + datetime.timedelta(seconds=90)).strftime("%Y-%m-%dT%H:%M:%SZ")
out = {"label": arm["label"], "arm": arm["arm"], "window": [start, end], "mrs": {}}
for mid, iid in sorted(mrs.items()):
    page, notes = 1, []
    while True:
        r = subprocess.run(["glab", "api", f"projects/{PID}/merge_requests/{iid}/notes?per_page=100&page={page}&sort=asc&order_by=created_at"],
                           capture_output=True, text=True, env=ENV)
        chunk = json.loads(r.stdout)
        notes += chunk
        if len(chunk) < 100:
            break
        page += 1
    rows = []
    for n in notes:
        if n.get("system") or not n["author"]["username"].startswith(CI_BOT_PREFIX):
            continue
        ts = n["created_at"][:19] + "Z"
        if not (start <= ts <= end):
            continue
        b = n["body"]
        kind = "review" if "Reviewer Guide" in b else "improve" if "Code Suggestions" in b else "other"
        m = re.search(r"Tokens: ([\d,]+) in / ([\d,]+) out", b); t = re.search(r"Time cost: ([\d.]+)s", b)
        rows.append({"note": n["id"], "created_at": ts, "kind": kind, "tokens_in": int(m.group(1).replace(",", "")) if m else None,
                     "tokens_out": int(m.group(2).replace(",", "")) if m else None, "secs": float(t.group(1)) if t else None, "body": b})
    out["mrs"][mid] = rows
    print(mid, iid, [(r["kind"], r["tokens_in"]) for r in rows])
path = os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), f"arm-notes-{arm['label']}.json")
json.dump(out, open(path, "w"), indent=1)
print("wrote", path)
