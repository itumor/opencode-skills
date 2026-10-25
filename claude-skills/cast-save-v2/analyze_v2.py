#!/usr/bin/env python3
"""cast-save v2 analyzer: v1 REST analysis + console-verified overlay + accuracy.json.

Usage:
  analyze_v2.py --dir RUN_DIR --cluster NAME --cluster-id ID --org ORG --reviewer WHO \
                [--console console-scrape.json] [--rank N] [--truth console/truth.json]

Runs the v1 core (analyze_v1_core.py) against raw payloads in RUN_DIR, then applies the
console overlay (live nodes, spot truth, STALLED detection, OOM note) and emits both
cast_optimise_data.json and accuracy.json (numeric claims for scoring).
"""
import argparse, json, os, runpy, sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
V1 = os.path.join(HERE, "analyze_v1_core.py")

def pdt(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--cluster", required=True)
    ap.add_argument("--cluster-id", required=True)
    ap.add_argument("--org", required=True)
    ap.add_argument("--reviewer", required=True)
    ap.add_argument("--console", help="console-scrape.json (list) or single row")
    ap.add_argument("--rank", type=int, default=0)
    args = ap.parse_args()

    # 1) v1 core analysis over raw payloads
    os.environ["CAST_SAVE_CLUSTER_ID"] = args.cluster_id
    os.environ["CAST_SAVE_CLUSTER_NAME"] = args.cluster
    sys.argv = ["analyze_v1_core.py", args.dir]
    runpy.run_path(V1, run_name="__main__")
    p = os.path.join(args.dir, "cast_optimise_data.json")
    data = json.load(open(p))

    # 2) post-fix identity fields (v1 core has hardcoded cluster)
    data["cluster_name"] = args.cluster
    data["cluster_id"] = args.cluster_id
    data["organization"] = args.org
    data["reviewer"] = args.reviewer

    # restore schedule names for this cluster from raw payloads + remap event names
    try:
        scheds = json.load(open(os.path.join(args.dir, "rb-schedules.json"))).get("schedules") or []
        mine = [s for s in scheds if any(j.get("clusterId") == args.cluster_id for j in (s.get("jobs") or []))]
        rb = data.get("rebalancing", {})
        rb["schedules"] = [{"name": s.get("name"), "id": s.get("id")} for s in mine]
        name_by_id = {s.get("id"): s.get("name") for s in mine}
        for e in rb.get("events", []):
            e["schedule_name"] = name_by_id.get(e.get("schedule_id"), e.get("schedule_name") or "-")
    except (OSError, json.JSONDecodeError):
        pass

    # degraded-cluster handling (read-only / Cloud-Connect): workloads endpoints 404
    try:
        ws_items = json.load(open(os.path.join(args.dir, "workloads.json"))).get("workloads")
    except (OSError, json.JSONDecodeError):
        ws_items = None
    if ws_items is None:
        data["data_coverage"] = {"status": "DEGRADED",
            "detail": ("Workload/pod/node inventory endpoints returned 404 (read-only / Cloud Connect scope, "
                       "or agent degraded). Sections 1–5 reflect no data — do not read as healthy."),
            "affected_endpoints": ["/v1/kubernetes/clusters/{clusterId}/workloads",
                                   "problematic-workloads", "problematic-nodes"]}
        es = data.setdefault("exec_summary", {"critical": [], "high": [], "medium": []})
        if not any("telemetry incomplete" in m.get("finding", "").lower() for m in es["medium"]):
            es["medium"].insert(0, {"area": "Data Coverage", "finding":
                "Cluster telemetry incomplete: workload/pod/node inventory endpoints returned 404 "
                "(cluster is read-only / Cloud Connect scope, or agent degraded).",
                "action": "Verify cluster connection mode in the CAST AI console; onboard with the full agent "
                          "(Read/Write mode) for complete analysis. WOOP + rebalancing sections use available data."})
        findings_ph = (data.get("rebalancing_health") or {}).get("findings") or []
        if not any(f.get("type") == "READ_ONLY_SCOPE" for f in findings_ph):
            findings_ph.append({"severity": "info", "type": "READ_ONLY_SCOPE",
                "title": "Workload endpoints unreachable — read-only onboarding",
                "detail": "/v1/kubernetes/clusters/{id}/workloads and problematic-* are unreachable for this cluster — consistent with read-only (Cloud Connect) onboarding or a degraded agent. Pod health, evictor, node-template and capacity sections show no data.",
                "schedule_name": ""})
    c = None
    if args.console and os.path.exists(args.console):
        rows = json.load(open(args.console))
        rows = rows if isinstance(rows, list) else [rows]
        c = next((r for r in rows if r.get("rank") == args.rank), None) or \
            next((r for r in rows if r.get("name") in (args.cluster, args.cluster.replace(" ", "-"))), None)
    now = datetime.now(timezone.utc)
    if c:
        es = data.setdefault("exec_summary", {"critical": [], "high": [], "medium": []})
        med, high = es["medium"], es["high"]
        med[:] = [m for m in med if not (m.get("area") == "Cost" and "on-demand" in m.get("finding", ""))]
        live_nodes, spot = c.get("nodes"), c.get("spot")
        if live_nodes is not None:
            if (spot or 0) > 0:
                med.append({"area": "Cost", "finding":
                    f"Fleet includes {spot} spot node(s) of {live_nodes} total (console-verified)",
                    "action": "Review spot coverage against workload tolerance; expand where safe"})
            elif live_nodes > 0:
                med.append({"area": "Cost", "finding":
                    f"Fleet is 100% on-demand ({live_nodes} nodes, console-verified)",
                    "action": "Enable spot on the node configuration with fallback"})
            ntrp = data.get("nt_resource_profile")
            if ntrp:
                ntrp["total_nodes"] = live_nodes
                for t in ntrp.get("templates", []):
                    t["node_count"] = live_nodes
        oom = c.get("oom")
        if oom and oom >= 50 and not any("OOM kills" in m.get("finding", "") for m in med):
            med.append({"area": "Pod Health", "finding":
                f"Console shows {oom} OOM kills in the last 24h (WOOP-unmanaged workloads)",
                "action": "Route affected workloads to WOOP management; review memory requests"})
        data["console_verified"] = {"nodes": live_nodes, "spot": spot, "oom": oom,
                                    "last_rebalance_console": c.get("lastWhen"), "rank": args.rank}

    # 4) STALLED detection from events (independent of console)
    rb = data.get("rebalancing", {})
    events = rb.get("events", [])
    # re-add NO_SCHEDULE warning when this cluster has no schedule jobs
    rh = data.get("rebalancing_health") or {}
    findings = rh.get("findings") or []
    if not (data.get("rebalancing", {}).get("schedules") or []) and not any(f.get("type") == "NO_SCHEDULE" for f in findings):
        findings.append({"severity": "warning", "type": "NO_SCHEDULE",
            "title": "No rebalancing schedule configured for this cluster",
            "detail": "Without a schedule nodes are not periodically consolidated and old on-demand nodes accumulate.",
            "schedule_name": ""})
        rh["findings"] = findings
        rh["health_score"] = max(0, (rh.get("health_score") or 100) - 15)
        data["rebalancing_health"] = rh
        es0 = data.setdefault("exec_summary", {"critical": [], "high": [], "medium": []})
        if not any("No rebalancing schedule" in m.get("finding", "") for m in es0["medium"]):
            es0["medium"].append({"area": "Rebalancing", "finding": "No rebalancing schedule configured for this cluster",
                "action": "Check schedule health"})
    last_ok = next((e for e in events if e.get("is_success")), None)
    last_ok_dt = pdt((last_ok or {}).get("timestamp_iso"))
    es = data.get("exec_summary", {"critical": [], "high": [], "medium": []})
    stalled = bool(last_ok_dt and (now - last_ok_dt).days > 30)
    if stalled and not any("stalled" in h.get("finding", "").lower() for h in es["high"]):
        es["high"].append({"area": "Rebalancing", "finding":
            f"Rebalancing stalled — last completed plan {last_ok_dt.strftime('%Y-%m-%d')} "
            f"({(now - last_ok_dt).days} days ago)",
            "action": "Check schedule job health in console; review trigger threshold and last failed plan"})
    degraded = not events and not data.get("workload_inventory", {}).get("namespaces")
    rebal_active = bool(last_ok_dt and (now - last_ok_dt).days <= 3)

    json.dump(data, open(p, "w"), indent=2, default=str)

    # 5) accuracy.json — numeric claims emitted by this report
    try:
        spotsignal = json.load(open(os.path.join(args.dir, "unscheduled-pods.json"))).get("items") or []
    except (OSError, json.JSONDecodeError):
        spotsignal = []
    unsched_claim = max(len((data.get("pod_health") or {}).get("schedule_unschedulable_workloads") or []),
                        len(spotsignal))
    if c and c.get("unsched") is not None:  # console is truth for live counters
        unsched_claim = c.get("unsched")
    savings_claim = (last_ok or {}).get("cost_savings_monthly")
    savings_source = "rest"
    if c and c.get("monthlySavings") is not None:  # console = freshest completed run
        savings_claim = c.get("monthlySavings"); savings_source = "console"
    claims = {
        "cluster": args.cluster, "rank": args.rank, "version": "v2",
        "nodes": (data.get("console_verified") or {}).get("nodes")
                  if c else data.get("nt_resource_profile", {}).get("total_nodes"),
        "spot": (data.get("console_verified") or {}).get("spot") if c else None,
        "unsched": unsched_claim,
        "rebal_healthy": rebal_active,
        "rebal_never": not events,
        "last_reb_savings": savings_claim,
        "last_reb_savings_source": savings_source,
        "last_reb_date": (last_ok or {}).get("timestamp_iso"),
        "oom_flag": bool((c or {}).get("oom", 0) > 0) if c else None,
        "degraded": bool((data.get("data_coverage") or {}).get("status") == "DEGRADED"),
        "truth_source": "console" if c else None,
    }
    with open(os.path.join(args.dir, "accuracy.json"), "w") as f:
        json.dump(claims, f, indent=2)
    print(f"[v2] {args.cluster}: nodes={claims['nodes']} spot={claims['spot']} "
          f"unsched={claims['unsched']} reb_healthy={claims['rebal_healthy']} "
          f"savings={claims['last_reb_savings']} oom={claims['oom_flag']} stalled={stalled}")

if __name__ == "__main__":
    main()
