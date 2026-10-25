#!/usr/bin/env python3
"""Run ONE skills arm on sandbox 1630 MRs (CI-job reviewer). Flips REVIEW_TOOLS only around each wave's
pipeline creation (rules are evaluated at creation), then restores the value it READ. Refuses to run unless
REVIEW_TOOLS holds the known baseline. Waits for the wave to finish, records job durations.

usage: arm_run.py --arm S0|S1|S2 --label S0a --mrs mr-iids.json [--wave 5] [--dry-run]
       mr-iids.json = {"m01": 75, "m02": 76, ...}  (iids in project 1630)
Writes arm-<label>.json next to this script."""
import argparse, json, os, subprocess, sys, time, datetime

PID = int(os.environ.get("ARMS_PID", "1630"))
BASELINE = os.environ.get("ARMS_BASELINE", "pr-agent-tuned-coder")
JOBS = {"S0": "pr-agent-tuned", "S1": "pr-agent-tuned-skills-org", "S2": "pr-agent-tuned-skills-org-argocd",
        "S3": "pr-agent-tuned-skills-org-argocd", "S4": "pr-agent-tuned",
        "V1": "pr-agent-tuned-skills-v1-all", "V2": "pr-agent-tuned-skills-v2-all",
        "V2R": "pr-agent-tuned-skills-v2-relaxed",
        "EV": "pr-agent-evidence"}   # V2 + tools-first evidence block (2026-10-20)   # skills v1 vs v2 (2026-10-20)   # S3/S4 run with the rules blanked by temp project vars
HERE = os.environ.get("ARMS_DIR", os.getcwd())
ENV = {**os.environ, "GITLAB_HOST": "sfo-cvdevopsgit01.eqxdev.exigengroup.com"}
ENV.pop("GITLAB_TOKEN", None)


def glab(*args, method=None, fields=None):
    cmd = ["glab", "api", *args]
    if method:
        cmd += ["--method", method]
    for k, v in (fields or {}).items():
        cmd += ["-f", f"{k}={v}"]
    tries = 6 if method in (None, "PUT", "DELETE") else 1   # never retry POST: a lost response may hide a created pipeline
    for n in range(tries):
        r = subprocess.run(cmd, capture_output=True, text=True, env=ENV)
        if not r.returncode:
            break
        time.sleep(10)
    if r.returncode:
        raise RuntimeError(f"glab {' '.join(args)} failed: {r.stdout[:200]} {r.stderr[:200]}")
    return json.loads(r.stdout) if r.stdout.strip() else {}


def now():
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True, choices=sorted(JOBS))
    ap.add_argument("--label", required=True)
    ap.add_argument("--mrs", required=True)
    ap.add_argument("--wave", type=int, default=5)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--restore-cfg", help="last wave: PUT this ci_config_path back once every arm job has started")
    a = ap.parse_args()
    job = JOBS[a.arm]
    mrs = json.load(open(a.mrs))
    ids = sorted(mrs)
    waves = [ids[i:i + a.wave] for i in range(0, len(ids), a.wave)]
    cur = glab(f"projects/{PID}/variables/REVIEW_TOOLS")["value"]
    print(f"{now()} arm {a.arm} job {job} label {a.label} | REVIEW_TOOLS reads {cur!r} | {len(ids)} MRs in {len(waves)} waves")
    if cur != BASELINE:
        sys.exit(f"REFUSE: REVIEW_TOOLS is {cur!r}, not the baseline {BASELINE!r} (another session may be mid-flip)")
    if a.dry_run:
        print("dry-run: would set REVIEW_TOOLS=", job, "per wave, POST pipelines for", waves, "and restore", cur)
        return
    out = {"arm": a.arm, "job": job, "label": a.label, "start": now(), "restore_to": cur, "waves": []}
    for w in waves:
        created = []
        try:
            glab(f"projects/{PID}/variables/REVIEW_TOOLS", method="PUT", fields={"value": job})
            time.sleep(2)
            for mid in w:
                p = glab(f"projects/{PID}/merge_requests/{mrs[mid]}/pipelines", method="POST")
                created.append({"mr": mid, "iid": mrs[mid], "pipeline": p["id"], "created_at": p["created_at"]})
            time.sleep(8)  # rules are fixed at creation; job list shows up within seconds
        finally:
            glab(f"projects/{PID}/variables/REVIEW_TOOLS", method="PUT", fields={"value": cur})
        print(f"{now()} wave {w}: pipelines {[c['pipeline'] for c in created]} created, REVIEW_TOOLS restored to {cur!r}")
        for c in created:
            jobs = glab(f"projects/{PID}/pipelines/{c['pipeline']}/jobs?per_page=50")
            c["jobs_at_creation"] = sorted(j["name"] for j in jobs)
            if job not in c["jobs_at_creation"]:
                print(f"  WARN pipeline {c['pipeline']} (MR {c['mr']}) has jobs {c['jobs_at_creation']}, not {job}")
        deadline = time.time() + 25 * 60
        last = w is waves[-1]
        while a.restore_cfg and last and time.time() < deadline:   # temp ci_config_path window (cfgwin pattern)
            js = [j for c in created for j in glab(f"projects/{PID}/pipelines/{c['pipeline']}/jobs?per_page=50") if j["name"] == job]
            if all(j["status"] not in ("created", "pending", "waiting_for_resource") for j in js):
                glab(f"projects/{PID}", method="PUT", fields={"ci_config_path": a.restore_cfg})
                out["cfg_restored"] = now()
                print(f"{now()} last arm jobs started; ci_config_path restored, GET = {glab(f'projects/{PID}')['ci_config_path']!r}")
                break
            time.sleep(15)
        while time.time() < deadline:
            states = []
            for c in created:
                p = glab(f"projects/{PID}/pipelines/{c['pipeline']}")
                c["status"] = p["status"]; c["started_at"] = p.get("started_at"); c["finished_at"] = p.get("finished_at")
                states.append(p["status"])
            if all(s in ("success", "failed", "canceled", "skipped") for s in states):
                break
            time.sleep(20)
        for c in created:
            jobs = glab(f"projects/{PID}/pipelines/{c['pipeline']}/jobs?per_page=50")
            c["jobs"] = [{"name": j["name"], "status": j["status"], "duration": j.get("duration"), "id": j["id"]} for j in jobs]
        out["waves"].append({"mrs": w, "pipelines": created})
        print(f"{now()} wave done: {[ (c['mr'], c['status']) for c in created]}")
    out["end"] = now()
    path = os.path.join(HERE, f"arm-{a.label}.json")
    json.dump(out, open(path, "w"), indent=1)
    print("wrote", path)


if __name__ == "__main__":
    main()
