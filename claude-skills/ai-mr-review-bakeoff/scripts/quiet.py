import json
import os
import subprocess
import sys

S = os.environ.get("ARMS_DIR", os.getcwd())
env = {**os.environ, "GITLAB_HOST": "sfo-cvdevopsgit01.eqxdev.exigengroup.com"}; env.pop("GITLAB_TOKEN", None)
def g(p): return json.loads(subprocess.run(["glab","api",p],capture_output=True,text=True,env=env).stdout)
ids = json.load(open(f"{S}/mr-iids.json"))
active = sum(len(g(f"projects/1630/pipelines?status={s}&per_page=20")) for s in ("running","pending","created"))
done = 0
for mid, iid in ids.items():
    notes = g(f"projects/1630/merge_requests/{iid}/notes?per_page=100")
    wh = [n for n in notes if n["author"]["username"].startswith(os.environ.get("ARMS_WEBHOOK_BOT", "project_1630_bot_36cf"))]
    done += any("Reviewer Guide" in n["body"] for n in wh) and any("Code Suggestions" in n["body"] for n in wh)
print(f"active pipelines={active} | MRs with hub review+improve={done}/10")
sys.exit(0 if active == 0 and done == 10 else 1)
