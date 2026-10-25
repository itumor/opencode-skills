#!/usr/bin/env python3
"""cast-save analysis for ngm-integ-eks — REST-API substitute pipeline.
Reads raw CAST AI REST responses from the run dir and produces:
  1) console digest per skill sections (degraded where snapshot/loki unavailable)
  2) cast_optimise_data.json in the skill's Step-9a schema (for the PDF generator)
"""
import json, math, os, re, sys
from collections import defaultdict
from datetime import datetime, timezone

RUN = sys.argv[1] if len(sys.argv) > 1 else "."
NOW = datetime.now(timezone.utc)
CLUSTER_ID = os.environ.get("CAST_SAVE_CLUSTER_ID", "1ad1a0bf-defe-4f51-acea-cbebb3d3fc3f")
CLUSTER_NAME = os.environ.get("CAST_SAVE_CLUSTER_NAME", "ngm-integ-eks")

def load(name, default=None):
    try:
        with open(f"{RUN}/{name}") as f:
            return json.load(f)
    except Exception as e:
        print(f"  [warn] {name}: {e}")
        return default if default is not None else {}

aws_eni_ips = {  # (max ENIs, IPv4 per ENI) per family-size — public AWS VPC CNI data
    "m6a.4xlarge": (8, 30), "m6i.4xlarge": (8, 30), "m5.4xlarge": (8, 30),
    "m6a.2xlarge": (4, 15), "m6i.2xlarge": (4, 15), "m5.2xlarge": (4, 15),
    "m6a.xlarge": (4, 15), "m5.xlarge": (3, 10), "m6i.xlarge": (4, 15),
    "c6a.4xlarge": (8, 30), "c6i.4xlarge": (8, 30), "c5.4xlarge": (8, 30),
    "r6a.4xlarge": (8, 30), "r6i.4xlarge": (8, 30), "r5.4xlarge": (8, 30),
    "m5.large": (3, 10), "m6a.large": (3, 10), "t3.xlarge": (4, 15),
    "c6a.2xlarge": (4, 15), "c6a.xlarge": (4, 15), "c6i.2xlarge": (4, 15),
    "c5a.4xlarge": (8, 30), "c5a.2xlarge": (6, 15), "c5a.xlarge": (4, 15),
    "c5.2xlarge": (6, 15), "c5.xlarge": (4, 15), "c5.large": (3, 10),
    "m7a.4xlarge": (8, 30), "m7a.2xlarge": (4, 15), "m7a.xlarge": (4, 15),
    "r6a.2xlarge": (4, 15), "r6a.xlarge": (4, 15), "r5n.4xlarge": (8, 30),
    "r5.2xlarge": (4, 15), "r5.xlarge": (4, 15),
}
def eks_max_pods(itype):
    e = aws_eni_ips.get(itype)
    return (e[0] * (e[1] - 1) + 2) if e else None

def parse_dt(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None

def iso_date(s):
    dt = parse_dt(s)
    return dt.strftime("%Y-%m-%d") if dt else ""

def fnum(x):
    try:
        f = float(x); return f if f == f else 0.0
    except (TypeError, ValueError):
        return 0.0

problematic_w  = load("problematic-workloads.json")
problematic_n  = load("problematic-nodes.json")
unscheduled    = load("unscheduled-pods.json")
workloads      = load("workloads.json", {"workloads": []}).get("workloads", [])
woop_ml        = load("workload-autoscaling-workloads.json", {"workloads": []}).get("workloads", [])
woop_policies  = load("woop-policies.json", {"items": []}).get("items", [])
node_configs   = (load("node-configurations.json", {"items": []}).get("items") or [])
node_templates = load("node-templates.json")
rb_generated   = load("rb-plans-generated.json")
rb_executed    = load("rb-plans-executed.json")
rb_last        = load("rb-plan-last.json")
rb_schedules   = load("rb-schedules.json").get("schedules") or []
audit          = load("audit-events-v2.json", {"events": []}).get("events", [])

def plans(obj):
    return (obj.get("rebalancingPlans") or obj.get("plans") or obj.get("items") or [])

gen_plans, exe_plans, last_plans = plans(rb_generated), plans(rb_executed), plans(rb_last)

# ---- node inventory from workloads[].nodes (REST snapshot of hosting) -------
node_info = {}  # name -> {instance_type, totalPods(max observed)}
for w in workloads:
    for n in (w.get("nodes") or []):
        nm = n.get("name", "")
        if not nm:
            continue
        e = node_info.setdefault(nm, {"instance_type": (n.get("specs") or {}).get("instanceType", ""),
                                      "max_pods_seen": 0})
        e["max_pods_seen"] = max(e["max_pods_seen"], n.get("status", {}).get("totalPods") or 0)
node_count = len(node_info)

# ---- Step 1-3: evictor (REST substitute) ------------------------------------
CAT = {"NotEvictable": "Not Evictable (annotation)",
       "RemovalDisabled": "Removal Disabled (annotation)",
       "PodNodeRequirements": "Not Reschedulable",
       "IsJobPod": "Other", "HasController": "Other"}
cat_order = ["StatefulSet", "Single Replica", "Not Evictable (annotation)",
             "Removal Disabled (annotation)", "Not Reschedulable", "PDB Violation", "Other"]

blocked = []
for w in workloads:
    issues = w.get("issues") or []
    if not issues:
        continue
    kinds = {i.get("kind") for i in issues}
    node_refs = [n.get("name", "") for n in (w.get("nodes") or []) if n.get("name")]
    cat = next((CAT[k] for k in ("NotEvictable", "RemovalDisabled", "PodNodeRequirements",
                                 "IsJobPod", "HasController") if k in kinds), "Other")
    blocked.append({"node": ", ".join(node_refs[:2]) if node_refs else "—",
                    "category": cat, "blocking_pod": w.get("name", ""),
                    "namespace": w.get("namespace", "")})
blocked.sort(key=lambda b: (cat_order.index(b["category"]) if b["category"] in cat_order else 99))

top = defaultdict(int)
for b in blocked:
    top[b["category"]] += 1
top_blockers = [{"category": c, "count": n} for c, n in
                sorted(top.items(), key=lambda kv: -kv[1])]

node_deletions = sum(1 for e in audit
                     if e.get("eventResourceText") == "Node" and e.get("eventActionText") == "Deleted")

# cross-matches: workloads that BOTH block a node AND cannot be rescheduled elsewhere
cross = []
for w in workloads:
    kinds = {i.get("kind") for i in (w.get("issues") or [])}
    if "PodNodeRequirements" in kinds and (kinds & {"NotEvictable", "RemovalDisabled"}):
        node_refs = [n.get("name", "") for n in (w.get("nodes") or []) if n.get("name")]
        cross.append({"pod": w["name"], "namespace": w.get("namespace", ""),
                      "node": node_refs[0] if node_refs else "—", "reason": "Not schedulable elsewhere"})

evictor = {"window_start": "n/a (REST live view — Loki not accessible)",
           "window_end": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
           "reconcile_cycles": 0, "blocked_nodes": blocked, "top_blockers": top_blockers,
           "evictions_completed": node_deletions, "cross_matches": cross}

# ---- Step 4: pod health (REST substitute) ------------------------------------
unhealthy = []
for w in workloads:
    kinds = {i.get("kind") for i in (w.get("issues") or [])}
    if "PodNodeRequirements" in kinds:
        detail = next((i.get("description", "") for i in w["issues"]
                       if i.get("kind") == "PodNodeRequirements"), "")
        m = re.search(r"clo-node-group-type=([\w-]+)", detail)
        selector = m.group(1) if m else "?"
        unhealthy.append({"name": w["name"], "namespace": w.get("namespace", ""),
                          "phase": "Unschedulable", "container": "—", "state": "pending",
                          "reason": f"No instance type matches selector clo-node-group-type={selector}",
                          "restarts": w.get("replicas", 0)})

standalone = problematic_w.get("standalonePods") or []
bare_pods = [p for p in standalone
             if any("HasController" in (pr if isinstance(pr, str) else str(pr)) for pr in p.get("problems", []))]

pod_health = {"unhealthy": unhealthy}

# ---- Step 6: max pod per node (ESTIMATED) -------------------------------------
groups = defaultdict(lambda: {"count": 0, "max_pods": None})
for nm, info in node_info.items():
    it = info["instance_type"] or "unknown"
    groups[it]["count"] += 1
    if groups[it]["max_pods"] is None:
        groups[it]["max_pods"] = eks_max_pods(it)

config_summary = [{"node_config": "ngm-integ-castai", "instance_type": it,
                   "max_pods": d["max_pods"], "node_count": d["count"]}
                  for it, d in sorted(groups.items(), key=lambda kv: -kv[1]["count"])]

at_capacity = []
for nm, info in node_info.items():
    mp = eks_max_pods(info["instance_type"])
    if not mp or info["max_pods_seen"] == 0:
        continue
    pct = round(info["max_pods_seen"] / mp * 100, 1)
    if pct >= 95.0:
        at_capacity.append({"node": nm, "instance_type": info["instance_type"],
                            "config": "ngm-integ-castai", "allocatable": mp,
                            "running": info["max_pods_seen"], "pct": pct})
at_capacity.sort(key=lambda x: -x["pct"])
max_pod = {"provider": "EKS", "config_summary": config_summary, "at_capacity": at_capacity}

# ---- Step 7: node templates ----------------------------------------------------
cfg0 = node_configs[0] if node_configs else {}
cons = cfg0.get("constraints") or {}
spot = bool(cfg0.get("spot", cfg0.get("spotInstances", False))) if cfg0 else False
itypes = sorted({i["instance_type"] for i in node_info.values() if i["instance_type"]})
nt_inventory = [{"template": cfg0.get("name", "default"),
                 "count": node_count,
                 "arch": cons.get("architectures") or ["amd64"],
                 "capacity_type": ["spot" if spot else "on-demand"],
                 "os": cons.get("os") or ["linux"],
                 "instance_types": itypes[:8] + (["…"] if len(itypes) > 8 else []),
                 "taints": [], "gpu": any("gpu" in t or t.startswith("p") or t.startswith("g5")
                                          for t in itypes)}]
node_templates_sec = {"inventory": nt_inventory, "merge_candidates": [],
                      "keep_separate": [{"template": cfg0.get("name", "default"),
                                         "reason": "Single node configuration — nothing to merge"}],
                      "misconfigured": [], "spot_templates": [] if not spot else [cfg0.get("name")]}

# ---- Step 7d: resource profile (cluster-level) --------------------------------
tot_cpu = tot_mem = ds_cpu = 0
for w in workloads:
    cpu = w.get("milliCpu") or 0
    mem = w.get("memoryMib") or 0
    tot_cpu += cpu; tot_mem += mem
    if w.get("resource") == "DaemonSet":
        ds_cpu += cpu
work_cpu = tot_cpu - ds_cpu
work_cpu_v, work_mem_gi = work_cpu / 1000.0, tot_mem / 1024.0
cpu_per_gi = work_cpu_v / work_mem_gi if work_mem_gi else 9999
pattern = ("memory-heavy" if cpu_per_gi <= 0.25 else
           "compute-heavy" if cpu_per_gi >= 0.5 else "general-purpose")
reco = {"memory-heavy": "r6i/r7g (AWS) · n2-highmem (GCP) · Epsv5 (Azure)",
        "compute-heavy": "c6i/c7g (AWS) · n2-highcpu (GCP) · Fsv2 (Azure)",
        "general-purpose": "m6i/m7g (AWS) · n2-standard (GCP) · Dsv5 (Azure)"}[pattern]
ds_pct = round(ds_cpu / tot_cpu * 100, 1) if tot_cpu else 0
nt_profile = {"templates": [{"template": "cluster-wide (per-template mapping unavailable via REST)",
                             "node_count": node_count, "cpu_vcpu": round(work_cpu_v, 1),
                             "mem_gi": round(work_mem_gi, 1),
                             "ratio_str": f"1:{round(1/cpu_per_gi,1)}" if cpu_per_gi else "1:∞",
                             "pattern": pattern, "recommendation": reco}],
              "ds_advisory": bool(node_count >= 50 and ds_pct >= 15),
              "ds_cpu_pct": ds_pct, "total_nodes": node_count}

# ---- Step 7e: rebalancing -------------------------------------------------------
sched = [s for s in rb_schedules
         if any(j.get("clusterId") == CLUSTER_ID for j in (s.get("jobs") or []))]
sched_names = {s["id"]: s.get("name", "") for s in sched}

def ts_of(p):
    return parse_dt(p.get("finishedAt") or p.get("updatedAt") or p.get("createdAt"))

merged = {}
for p in gen_plans + exe_plans:
    pid = p.get("rebalancingPlanId") or p.get("id")
    if not pid:
        continue
    t = ts_of(p)
    if not t:
        continue
    c = (p.get("configurations") or {})
    err_reasons = [e.get("reason", "") for e in (p.get("errors") or [])]
    savings_skip = (p.get("status") == "error" and err_reasons and all(
        r in ("achievedSavingsBelowThreshold", "savingsBelowThreshold") for r in err_reasons))
    status = p.get("status", "")
    is_skipped = ((status == "generated" and not p.get("triggeredAt")) or savings_skip)
    if status == "generated" and p.get("triggeredAt"):
        continue  # pending execution — excluded per skill
    ach = c.get("achievedDiff") or c.get("diff") or {}
    merged[pid] = {
        "plan_id": pid, "timestamp_iso": t.isoformat(), "date": t.strftime("%Y-%m-%d"),
        "status": status, "is_success": status == "finished", "is_partial": status == "partially_finished",
        "is_skipped": is_skipped,
        "schedule_name": sched_names.get(p.get("scheduleId"), ""),
        "error_summary": "; ".join(f"{e.get('reason','')}: {e.get('message','')}"
                                    for e in (p.get("errors") or []))[:150] if status == "error" and not savings_skip else "",
        "skip_reason": "Savings below threshold — plan generated but not executed" if is_skipped else "",
        "nodes_before": ((c.get("blue") or {}).get("totals") or {}).get("nodes"),
        "nodes_after": ((c.get("green") or {}).get("totals") or {}).get("nodes"),
        "cpu_before": ((((c.get("blue") or {}).get("totals") or {}).get("milliCpu") or 0) or 0) / 1000 or None,
        "cpu_after": ((((c.get("green") or {}).get("totals") or {}).get("milliCpu") or 0) or 0) / 1000 or None,
        "cost_savings_monthly": (round(fnum(ach["priceMonthly"])) if not is_skipped and ach.get("priceMonthly") else None),
        "cost_savings_pct": (round(fnum(ach.get("clusterSavingsPercentage", ach.get("savingsPercentage", 0))), 1)
                             if not is_skipped and ach else None)}
events = sorted(merged.values(), key=lambda e: e["timestamp_iso"], reverse=True)

# last completed rebalance
lr = {"has_rebalancing": False}
old_od = []
if last_plans:
    p = last_plans[0]
    c = p.get("configurations") or {}
    blue_t = (c.get("blue") or {}).get("totals") or {}
    green_t = (c.get("green") or {}).get("totals") or {}
    fin = parse_dt(p.get("finishedAt"))
    days = (NOW - fin).days if fin else None
    nb, na = blue_t.get("nodes"), green_t.get("nodes")
    cb = (blue_t.get("milliCpu") or 0) / 1000
    ca = (green_t.get("milliCpu") or 0) / 1000
    bh, ah = fnum(blue_t.get("priceHourly")), fnum(green_t.get("priceHourly"))
    lr = {"has_rebalancing": True, "last_rebalance_date": fin.strftime("%Y-%m-%d %H:%M UTC") if fin else "",
          "days_since": days, "nodes_before": nb, "nodes_after": na,
          "nodes_reduction_pct": round((nb - na) / nb * 100, 1) if nb else None,
          "cpu_before": round(cb, 1), "cpu_after": round(ca, 1),
          "cpu_reduction_pct": round((cb - ca) / cb * 100, 1) if cb else None,
          "cost_before_hourly": round(bh, 2), "cost_after_hourly": round(ah, 2),
          "cost_savings_monthly": round((bh - ah) * 730, 0),
          "cost_savings_pct": fnum((c.get("achievedDiff") or {}).get("clusterSavingsPercentage"))}
    # old on-demand CAST-managed nodes (age >= 30d) from plan scope
    for n in (c.get("blue") or {}).get("nodes") or []:
        if str(n.get("managedBy", "")).lower() not in ("castai", "cast.ai") or n.get("isSpot"):
            continue
        created = parse_dt(n.get("createdAt"))
        if not created:
            continue
        age = (NOW - created).days
        if age >= 30:
            old_od.append({"name": n.get("name", ""), "instance_type": n.get("instanceType", ""),
                           "age_days": age})
    old_od.sort(key=lambda x: -x["age_days"])

rebalancing = {"events": events, "last_rebalance": lr,
               "schedules": [{"id": s["id"], "name": s.get("name", "")} for s in sched],
               "old_ondemand_nodes": old_od, "old_ondemand_count": len(old_od)}

# ---- Step 7f: rebalancing health findings ---------------------------------------
findings = []
for s in sched:
    lc = s.get("launchConfiguration") or {}
    terms = (lc.get("selector") or {}).get("nodeSelectorTerms") or []
    name = s.get("name", "")
    if not terms:
        findings.append({"type": "NO_SELECTOR", "severity": "info",
                         "title": f"'{name}': no node selector — schedule targets all nodes",
                         "detail": "Schedule has no nodeSelectorTerms and applies to the whole cluster.",
                         "schedule_name": name})
    job = next((j for j in s.get("jobs", []) if j.get("clusterId") == CLUSTER_ID), {})
    lt = parse_dt(job.get("lastTriggerAt"))
    if lt and (NOW - lt).days > 7:
        findings.append({"type": "STALE_SCHEDULE", "severity": "warning",
                         "title": f"'{name}': last triggered {(NOW-lt).days} days ago",
                         "detail": "Schedule has not triggered in over 7 days — verify it is not broken or disabled.",
                         "schedule_name": name})
    tc = lc.get("triggerConditions") or {}
    sav_pct = fnum(tc.get("savingsPercentage"))
    ignore = bool(tc.get("ignoreSavings", False))
    s_events = [e for e in events if e["schedule_name"] == name]
    if s_events and s_events[0]["is_skipped"] and not ignore and sav_pct > 0:
        streak = 0
        for e in s_events:
            if e["is_skipped"]:
                streak += 1
            else:
                break
        findings.append({"type": "JOB_SKIPPED_SAVINGS_THRESHOLD", "severity": "warning",
                         "title": f"'{name}': last run skipped — savings threshold {int(sav_pct)}% not met "
                                  f"(last {streak} consecutive skipped, "
                                  f"{sum(1 for e in s_events if e['is_skipped'])}/{len(s_events)} total) "
                                  f"· last: {s_events[0]['date']}",
                         "detail": "The most recent plan was generated but not executed because projected "
                                   "savings fell below the configured threshold.",
                         "schedule_name": name})

audit_rows = []
for e in audit:
    txt = f"{e.get('eventDomainText','')} | {e.get('eventResourceText','')} | {e.get('eventActionText','')}"
    if "rebalanc" in txt.lower():
        audit_rows.append({"time": e.get("occurredAt", ""), "event_type": e.get("eventDomainText", ""),
                           "action": e.get("eventActionText", ""),
                           "message": (e.get("description") or "")[:300],
                           "initiator": (e.get("actor") or {}).get("email", "system")})
    audit_rows = audit_rows[:30]

rebalancing_health = {"audit_window_days": 14, "findings": findings, "audit_events": audit_rows}

# ---- Step 8: WOOP ---------------------------------------------------------------
pol_by_id = {p["id"]: p for p in woop_policies}
w_issues, ok = [], 0
managed = [w for w in woop_ml if w.get("scalingPolicyId")]
for w in managed:
    pol = pol_by_id.get(w["scalingPolicyId"], {})
    rec = pol.get("recommendationPolicies") or {}
    rb_ = rec.get("rolloutBehavior") or {}
    apply_type = rec.get("applyType") or "?"
    prefer_121 = rb_.get("preferOneByOne")
    readonly = rec.get("managementOption") == "READ_ONLY"
    reps = w.get("replicas") or w.get("podCount") or 0
    rollout = "ONE_BY_ONE" if prefer_121 else ("READ_ONLY" if readonly else apply_type)
    if prefer_121 or readonly:
        ok += 1
    else:
        st = "WARN: rollout not one-by-one"
        w_issues.append({"workload": w.get("name", ""), "namespace": w.get("namespace", ""),
                         "replicas": reps, "rollout_strategy": rollout,
                         "zero_downtime": None, "status": st})
woop = {"active": bool(managed), "total_checked": len(managed), "ok": ok,
        "warnings": len(w_issues), "action_needed": 0, "issues": w_issues}

# ---- exec summary ----------------------------------------------------------------
critical, high, medium = [], [], []
if cross:
    critical.append({"area": "Evictor", "finding":
        f"{len(cross)} workload(s) blocking nodes and not schedulable elsewhere",
        "action": "Fix node-group selectors (gitlab-runner / windows) so pods can move"})
pct_ne = top.get("Not Evictable (annotation)", 0) + top.get("Removal Disabled (annotation)", 0)
if pct_ne > 3:
    high.append({"area": "Evictor", "finding":
        f"{pct_ne} workloads marked not-safe-to-evict (annotation) — consolidation heavily blocked",
        "action": "Review removal-disabled / safe-to-evict=false annotations across namespaces"})
if unhealthy:
    high.append({"area": "Pod Health", "finding":
        f"{len(unhealthy)} workloads unschedulable (selector ↔ node-template mismatch) + {len(bare_pods)} bare pods",
        "action": "Add matching instance types to the node configuration or fix workload selectors"})
for f in findings:
    if f["severity"] == "critical":
        critical.append({"area": "Rebalancing", "finding": f["title"], "action": "Fix schedule node selector"})
    elif f["severity"] == "warning":
        high.append({"area": "Rebalancing", "finding": f["title"], "action": "Check schedule trigger conditions"})
if len(old_od) >= 3:
    high.append({"area": "Rebalancing", "finding": f"{len(old_od)} old (≥30d) on-demand CAST-managed nodes remain",
                 "action": "Let rebalancing schedules drain leftover on-demand nodes"})
medium.append({"area": "Cost", "finding":
    "Fleet is 100% on-demand (0 spot nodes) — despite CAST AI rebalancing being active",
    "action": "Enable spot instances on the node configuration with fallback; TAM review of suitable workloads"})
if nt_profile["ds_advisory"]:
    medium.append({"area": "Node Templates", "finding":
        f"DaemonSets consume {ds_pct}% of cluster CPU across {node_count} nodes",
        "action": "Set minCPU=4 in node configuration to reduce DS overhead dilution"})
for wi in w_issues[:5]:
    medium.append({"area": "WOOP", "finding": f"{wi['workload']} rollout not one-by-one",
                   "action": "Enable one-by-one rollout on the WOOP scaling policy"})

data = {"cluster_name": CLUSTER_NAME, "cluster_id": CLUSTER_ID,
        "generated_at": NOW.strftime("%d %B %Y %H:%M UTC"),
        "evictor": evictor, "pod_health": pod_health, "max_pod_per_node": max_pod,
        "node_templates": node_templates_sec, "nt_resource_profile": nt_profile,
        "rebalancing": rebalancing, "rebalancing_health": rebalancing_health,
        "woop_rollout": woop,
        "exec_summary": {"critical": critical, "high": high, "medium": medium}}

with open(f"{RUN}/cast_optimise_data.json", "w") as f:
    json.dump(data, f, indent=2, default=str)

# ---- console digest --------------------------------------------------------------
print(f"Cluster: {CLUSTER_NAME} ({CLUSTER_ID})   nodes(observed): {node_count}")
print(f"Evictor blockers (REST proxy): {len(blocked)} workloads with issues")
for tb in top_blockers:
    print(f"   {tb['category']}: {tb['count']}")
print(f"Cross-matches: {len(cross)} | Node deletions in audit window: {node_deletions}")
print(f"Unschedulable workloads: {len(unhealthy)} | bare pods: {len(bare_pods)} | explicit unscheduled-pods API: {len(unscheduled.get('items') or [])}")
print("Instance mix:", ", ".join(f"{c['instance_type']}×{c['node_count']}" for c in config_summary))
print(f"At/near pod capacity (est): {len(at_capacity)}")
print(f"Profile: {pattern} ({nt_profile['templates'][0]['ratio_str']}) cpu={round(work_cpu_v,1)} vCPU mem={round(work_mem_gi,1)} Gi  DS share: {ds_pct}%")
print(f"Rebalancing events: {len(events)}  schedules: {[s['name'] for s in sched]}")
succ = [e for e in events if e['is_success'] and not e['is_skipped']]
skips = [e for e in events if e['is_skipped']]
print(f"  success={len(succ)} skipped={len(skips)} failed={sum(1 for e in events if e['status']=='error' and not e['is_skipped'])}")
print(f"  last: {lr.get('last_rebalance_date','-')} nodes {lr.get('nodes_before')}→{lr.get('nodes_after')} "
      f"cost ${lr.get('cost_before_hourly')}→${lr.get('cost_after_hourly')}/hr "
      f"≈ ${lr.get('cost_savings_monthly')}/mo ({round(lr.get('cost_savings_pct') or 0,1)}% cluster)")
print(f"Old on-demand CAST nodes ≥30d (plan scope): {len(old_od)}")
print(f"Health findings: " + ", ".join(f"{f['severity']}:{f['type']}" for f in findings))
print(f"WOOP: managed={woop['total_checked']} ok={woop['ok']} warnings={woop['warnings']}")
print(f"Exec: {len(critical)} critical / {len(high)} high / {len(medium)} medium")
print("JSON written.")
