#!/usr/bin/env python3
"""Score report accuracy vs console truth.

Computes v1 claims directly from the raw REST payloads in each run dir (union node count,
spot in instance_types, unscheduled-pods rows, last-10-window success ⇒ "healthy", REST last
savings) and reads v2 claims from accuracy.json. Scores both against truth-round2.json
(console). Writes all.json + accuracy-table.md and prints the table.

Usage: score_accuracy.py --base BASE --manifest accuracy/runs.json \
        --truth console/truth-round2.json --out accuracy [--only RANK]
"""
import argparse, json, os
from datetime import datetime, timezone

def pdt(s):
    if not s:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d %I:%M %p", "%Y-%m-%d %H:%M"):
        try:
            return datetime.strptime(str(s), fmt).replace(tzinfo=timezone.utc)
        except (ValueError, TypeError):
            continue
    return None

def load(rd, name, default=None):
    try:
        with open(os.path.join(rd, name)) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return default if default is not None else {}

def v1_claims(rd, cluster_id):
    """What v1's report claimed, derived from raw payloads only."""
    ws = load(rd, "workloads.json", {"workloads": []}).get("workloads", [])
    nodes, itypes = set(), set()
    for w in ws:
        for n in (w.get("nodes") or []):
            nodes.add(n.get("name")); itypes.update(n.get("instance_types") or [])
    unsched = len(load(rd, "unscheduled-pods.json", {"items": []}).get("items") or [])
    ex = load(rd, "rb-plans-executed.json")
    plans = ex.get("plans") or ex.get("items") or []
    ok = [p for p in plans if p.get("status") == "finished"]
    ok.sort(key=lambda p: p.get("finishedAt") or "", reverse=True)
    gen = load(rd, "rb-plans-generated.json")
    gplans = gen.get("plans") or gen.get("items") or []
    scheds = [s for s in (load(rd, "rb-schedules.json", {"schedules": []}).get("schedules") or [])
              if any(j.get("clusterId") == cluster_id for j in (s.get("jobs") or []))]
    events = ok + gplans
    now = datetime.now(timezone.utc)
    last_dt = pdt((ok[0] if ok else {}).get("finishedAt"))
    # v1 displayed "healthy" when the visible 10-event window had successes
    healthy = bool(ok and scheds) or bool(ok and len(events) <= 10)
    sav = None
    if ok:
        b, a = ok[0].get("costBeforeNodes") or ok[0].get("totalCostBefore"), ok[0].get("costAfterNodes") or ok[0].get("totalCostAfter")
        if b is not None and a is not None:
            sav = (b - a) * 730
    return {"nodes": len(nodes), "spot": sum(1 for i in itypes if i == "spot"),
            "unsched": unsched, "rebal_healthy": healthy, "last_reb_savings": sav,
            "last_reb_dt": last_dt, "oom_flag": False,
            "age_days": ((now - last_dt).days if last_dt else None)}

def close(a, b, rel=0.10, abs_=1):
    if a is None or b is None:
        return None
    try:
        a, b = float(a), float(b)
    except (TypeError, ValueError):
        return None
    return abs(a - b) <= max(abs_, abs(b) * rel)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--truth", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", type=int, default=0)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    manifest = json.load(open(os.path.join(args.base, args.manifest)))
    truth = {t["rank"]: t for t in json.load(open(os.path.join(args.base, args.truth)))}

    rows, tot = [], {"v1": [], "v2": []}
    for m in sorted(manifest, key=lambda x: x["rank"]):
        if args.only and m["rank"] != args.only:
            continue
        rd = os.path.join(args.base, m["dir"])
        t = truth[m["rank"]]
        v1 = v1_claims(rd, m["cluster_id"])
        v2p = os.path.join(rd, "accuracy.json")
        v2 = json.load(open(v2p)) if os.path.exists(v2p) else None
        t_age = ((datetime.now(timezone.utc) - pdt(t.get("lastWhen"))).days if pdt(t.get("lastWhen")) else None)
        t_healthy = bool(not t.get("never") and t_age is not None and t_age <= 3)

        def grade(claims):
            s = {}
            s["nodes"] = close(claims.get("nodes"), t.get("nodes")) if claims.get("nodes") is not None else 0
            s["spot"] = close(claims.get("spot"), t.get("spot"), 0.10, 1) if claims.get("spot") is not None else 0
            s["unsched"] = close(claims.get("unsched"), t.get("unsched"), 0.0, 1) if claims.get("unsched") is not None else 0
            s["rebal_healthy"] = 1 if claims.get("rebal_healthy") == t_healthy else 0
            sv, tv = claims.get("last_reb_savings"), t.get("cobra_monthly", t.get("lastSave"))
            if t.get("never") or (sv is None and tv is None):
                s["last_reb_savings"] = 1 if t.get("never") else (0 if tv else 1)
            else:
                r = close(sv, tv, 0.30, 1)
                s["last_reb_savings"] = 1 if r else (0.5 if close(sv, tv, 0.60, 1) else 0)
            s["oom_flag"] = 1 if bool(claims.get("oom_flag")) == bool((t.get("oom") or 0) > 0) else 0
            vals = [v for v in s.values() if v is not None]
            s["__avg"] = sum(vals) / len(vals) if vals else 0
            return s

        g1, g2 = grade(v1), grade(v2) if v2 else None
        rows.append({"rank": m["rank"], "cluster": m["cluster"], "org": m["org"],
                     "truth": {"nodes": t.get("nodes"), "spot": t.get("spot"), "unsched": t.get("unsched"),
                               "healthy": t_healthy, "savings": t.get("lastSave"), "oom": t.get("oom")},
                     "v1": {"claims": v1, "score": g1},
                     "v2": {"claims": v2, "score": g2} if v2 else None})
        tot["v1"].append(g1["__avg"])
        if g2:
            tot["v2"].append(g2["__avg"])

    def pct(v):
        return f"{v * 100:.0f}%" if v is not None else "—"
    lines = ["# Accuracy score — cast-save v1 vs v2 (console = truth)",
             f"Truth source: console.eu.cast.ai UI scrape (2026-10-21, second pass)",
             "",
             "| # | Cluster | v1 accuracy | v2 accuracy | v1 misses |",
             "|---|---------|------------|------------|-----------|"]
    for r in rows:
        s1 = r["v1"]["score"]; s2 = (r["v2"] or {}).get("score")
        misses = [k for k, v in s1.items() if k != "__avg" and v not in (1, None)]
        lines.append(f"| {r['rank']} | {r['cluster']} | {pct(s1['__avg'])} | "
                     f"{pct(s2['__avg']) if s2 else '—'} | {', '.join(misses) or '—'} |")
    if tot["v1"]:
        lines.append(f"| | **AVERAGE** | **{pct(sum(tot['v1'])/len(tot['v1']))}** | "
                     f"**{pct(sum(tot['v2'])/len(tot['v2'])) if tot['v2'] else '—'}** | |")
    md = "\n".join(lines) + "\n"
    json.dump(rows, open(os.path.join(args.out, "all.json"), "w"), indent=2, default=str)
    open(os.path.join(args.out, "accuracy-table.md"), "w").write(md)
    print(md)

if __name__ == "__main__":
    main()
