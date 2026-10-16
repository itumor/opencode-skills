#!/usr/bin/env python3
"""Arms S4 (no rules, no skills) and S3 (no rules + org,argocd skills) on the 10 MRs. The tuned job's .review_rules are
blanked by TEMPORARY project variables (project vars override job YAML vars); they are deleted in a finally block.
usage: ARMS_DIR=<dir> run_norules.py
EDIT the (arm, label, mrs) tuple in the `try:` block to the arms you need; the variable cleanup in `finally` is the point of this script.
Keep the machine awake: `caffeinate -i python3 -I run_norules.py` (a sleep once stranded the temp vars for 45 min)."""
import json, os, subprocess, sys, time

R = os.environ.get("ARMS_DIR", os.getcwd())
PID = int(os.environ.get("ARMS_PID", "1630"))
KEYS = ["pr_reviewer__extra_instructions", "pr_code_suggestions__extra_instructions"]
ENV = {**os.environ, "GITLAB_HOST": "sfo-cvdevopsgit01.eqxdev.exigengroup.com"}
ENV.pop("GITLAB_TOKEN", None)


def glab(*a, method=None, fields=None, check=True):
    cmd = ["glab", "api", *a]
    if method:
        cmd += ["--method", method]
    for k, v in (fields or {}).items():
        cmd += ["-f", f"{k}={v}"]
    tries = 6 if method in (None, "PUT", "DELETE") else 1
    for n in range(tries):
        r = subprocess.run(cmd, capture_output=True, text=True, env=ENV)
        if not r.returncode:
            break
        time.sleep(10)
    if check and r.returncode:
        raise SystemExit(f"glab {' '.join(a)} failed: {r.stdout[:300]} {r.stderr[:300]}")
    return r


def py(*a):
    r = subprocess.run([sys.executable, "-I", *a], cwd=R, env=ENV)
    if r.returncode:
        raise SystemExit(f"{a[0]} failed rc={r.returncode}")


busy = sum(len(json.loads(glab(f"projects/{PID}/pipelines?status={s}&per_page=20").stdout)) for s in ("running", "pending", "created"))
have = [v["key"] for v in json.loads(glab(f"projects/{PID}/variables").stdout)]
cur = json.loads(glab(f"projects/{PID}/variables/REVIEW_TOOLS").stdout)["value"]
print(f"preconditions: active={busy} REVIEW_TOOLS={cur!r} vars={have}")
if busy or cur != "pr-agent-tuned-coder" or any(k in have for k in KEYS):
    sys.exit("REFUSE: not quiet / not baseline / rule-blanking vars already exist")
created = []
try:
    for k in KEYS:
        r = glab(f"projects/{PID}/variables", method="POST", fields={"key": k, "value": "", "masked": "false", "protected": "false"}, check=False)
        if r.returncode:   # blank value refused: use a single space (PR-Agent treats it as no instructions)
            glab(f"projects/{PID}/variables", method="POST", fields={"key": k, "value": " ", "masked": "false", "protected": "false"})
            print("  blank refused, used a single space for", k)
        created.append(k)
    print("temp vars set:", created)
    for arm, lab, mrs in (("S3", "S3a", "mr-iids.json"), ("S4", "S4r", "m03-only.json")):   # S4a already ran (rebuilt); S4r = retry of its failed m03
        py("arm_run.py", "--arm", arm, "--label", lab, "--mrs", mrs, "--wave", "5")
        py("collect_arm.py", f"arm-{lab}.json", mrs)
finally:
    for k in created:
        glab(f"projects/{PID}/variables/{k}", method="DELETE", check=False)
    left = [v["key"] for v in json.loads(glab(f"projects/{PID}/variables").stdout)]
    print("temp vars deleted; project vars now:", left)
