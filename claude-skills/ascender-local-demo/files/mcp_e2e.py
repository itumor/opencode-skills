#!/usr/bin/env python3
"""End-to-end test of ascender-mcp against the LOCAL demo Ascender. Launches real (local, fake-host) jobs.
  set -a; . ./demo-credentials.env; set +a; python3 mcp_e2e.py
Needs OPERATOR_MCP_TOKEN and ADMIN_MCP_TOKEN in env. Prints PASS/FAIL per check, exit 1 on any FAIL."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_client import Client  # noqa: E402

JT, WF, APPROVAL = "Kernel patch (demo)", "Patch with approval", "Maintenance window approved?"
results = []


def check(name, ok, observed):
    results.append(ok)
    print(f'{"PASS" if ok else "FAIL"} | {name} | {str(observed)[:160]}')


def rows(d):
    return (d.get("results") or []) if isinstance(d, dict) else []  # server sends results: null for an empty list


# ---- run-only operator ------------------------------------------------------
op = Client(os.environ["OPERATOR_MCP_TOKEN"])
st, r = op.init()
check("operator: initialize", st == 200, r.get("result", {}).get("serverInfo"))
e, d = op.call("ping")
check("operator: ping", not e, {k: d.get(k) for k in ("version", "ha")} if isinstance(d, dict) else d)
e, d = op.call("whoami")
check("operator: whoami is run-only user", not e and d.get("username") == "operator" and d.get("is_superuser") is False,
      {k: d.get(k) for k in ("username", "is_superuser")} if isinstance(d, dict) else d)
e, d = op.call("list_templates", {})
names = [t.get("name") for t in rows(d)]
check("operator: sees only its one template", not e and names == [JT], names)
jt_id = rows(d)[0]["id"] if rows(d) else None
e, d = op.call("list_templates", {"kind": "workflow"})
check("operator: sees no workflow templates", not e and rows(d) == [], [t.get("name") for t in rows(d)])
e, d = op.call("get_survey", {"id_or_name": JT})
qs = [q.get("variable") for q in d.get("spec", [])] if isinstance(d, dict) else d
check("operator: reads the launch form", not e and qs == ["client", "change_ticket"], qs)

e, d = op.call("launch_template", {"id_or_name": JT, "limit": "aws0caanexus01",
                                   "extra_vars": {"client": "axa-japan", "change_ticket": "NOJIRA-MCP-1"}})
job = d.get("job") or d.get("id") if isinstance(d, dict) else None
check("operator: launch_template with limit + form values", not e and bool(job),
      {"job": job, "ignored_fields": d.get("ignored_fields") if isinstance(d, dict) else d})
if job:
    e, d = op.call("wait_for_job", {"job_id": job, "timeout_seconds": 240})
    check("operator: wait_for_job ends successful", not e and d.get("status") == "successful",
          {k: d.get(k) for k in ("status", "limit", "launched_by", "elapsed")} if isinstance(d, dict) else d)
    e, d = op.call("get_job_host_summaries", {"job_id": job})
    hs = [(h.get("host_name"), h.get("ok"), h.get("failures")) for h in rows(d)]
    check("operator: job ran on the limited host only", not e and [h[0] for h in hs] == ["aws0caanexus01"] and hs[0][2] == 0, hs)
    import time
    for _ in range(10):  # the last stdout lines land a moment after the job status flips to successful
        e, d = op.call("get_job_stdout", {"job_id": job})
        text = d if isinstance(d, str) else str(d)
        if "PLAY RECAP" in text:
            break
        time.sleep(1)
    check("operator: get_job_stdout has the play recap", not e and "PLAY RECAP" in text, text[-120:].replace("\n", " "))
    e, d = op.call("list_job_events", {"job_id": job, "failed_only": True})
    check("operator: no failed events", not e and rows(d) == [], len(rows(d)))

e, d = op.call("update_job_template", {"template_id": jt_id, "description": "changed through MCP"})
check("operator: edit template is refused (RBAC)", e, d)
e, d = op.call("launch_workflow", {"id_or_name": WF})
check("operator: launch workflow is refused (RBAC)", e, d)
e, d = op.call("list_credentials", {})
check("operator: sees no credentials", not e and rows(d) == [], len(rows(d)))

# ---- admin: workflow with an approval gate ----------------------------------
ad = Client(os.environ["ADMIN_MCP_TOKEN"])
ad.init()
e, d = ad.call("launch_workflow", {"id_or_name": WF})
wj = (d.get("workflow_job") or d.get("id")) if isinstance(d, dict) else None
check("admin: launch_workflow", not e and bool(wj), {"workflow_job": wj})
appr = None
if wj:
    import time
    for _ in range(30):
        e, d = ad.call("list_workflow_approvals", {})
        pend = [a for a in rows(d) if a.get("status") == "pending" and a.get("name") == APPROVAL]
        if pend:
            appr = max(a["id"] for a in pend)
            break
        time.sleep(2)
    check("admin: workflow pauses at the approval step", appr is not None, {"approval_id": appr})
if appr:
    e, d = ad.call("approve_workflow_approval", {"approval_id": appr, "expected_name": "wrong name"})
    check("admin: approve with a wrong expected_name is refused", e, d)
    e, d = ad.call("approve_workflow_approval", {"approval_id": appr, "expected_name": APPROVAL})
    check("admin: approve with the right name", not e, d if e else "approved")
    e, d = ad.call("wait_for_job", {"job_id": wj, "kind": "workflow", "timeout_seconds": 300})
    check("admin: workflow ends successful after approval", not e and d.get("status") == "successful",
          d.get("status") if isinstance(d, dict) else d)
    e, d = ad.call("list_workflow_nodes", {"workflow_job_id": wj})
    check("admin: workflow ran 2 nodes", not e and len(rows(d)) == 2,
          [(n.get("summary_fields", {}).get("job", {}).get("type"), n.get("summary_fields", {}).get("job", {}).get("status")) for n in rows(d)])

print(f"\n{sum(results)}/{len(results)} checks passed")
sys.exit(0 if all(results) else 1)
