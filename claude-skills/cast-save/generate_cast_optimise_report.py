#!/usr/bin/env python3
import json
import os
import sys
from html import escape

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import (
    BaseDocTemplate,
    Frame,
    PageBreak,
    PageTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
)

# ── Brand palette (matches CAST AI cluster-readiness reports) ──────────────────
CAST_BLUE   = colors.HexColor("#0669FD")
CAST_BLACK  = colors.HexColor("#0E0F13")
CAST_WHITE  = colors.white
RED_FAIL    = colors.HexColor("#EF4444")
RED_LIGHT   = colors.HexColor("#FEE2E2")
AMBER_WARN  = colors.HexColor("#F59E0B")
AMBER_LIGHT = colors.HexColor("#FEF3C7")
AMBER_DARK  = colors.HexColor("#92400E")
GREEN_PASS  = colors.HexColor("#22C55E")
GREEN_LIGHT = colors.HexColor("#DCFCE7")
BLUE_INFO   = colors.HexColor("#3B82F6")
BLUE_LIGHT  = colors.HexColor("#DBEAFE")
GRAY_LIGHT  = colors.HexColor("#F4F6FA")
GRAY_MID    = colors.HexColor("#D1D5DB")
GRAY_DARK   = colors.HexColor("#6B7280")
DARK_ROW    = colors.HexColor("#1E2228")
PURPLE      = colors.HexColor("#8B5CF6")
PURPLE_LIGHT= colors.HexColor("#EDE9FE")
ORANGE_WARN = colors.HexColor("#F97316")
ORANGE_LIGHT= colors.HexColor("#FFEDD5")

ICON_CANDIDATES = [
    "/mnt/skills/private/cluster-readiness/assets/castai_icon.png",
    "/mnt/skills/user/cluster-readiness/assets/castai_icon.png",
]
ICON_PATH = next((p for p in ICON_CANDIDATES if os.path.exists(p)), "")

def S(name, **kw):
    base = dict(fontName="Helvetica", fontSize=9, textColor=CAST_BLACK, leading=13)
    base.update(kw)
    return ParagraphStyle(name, **base)

def grid(extra=None):
    ts = extra or []
    return ts + [
        ("GRID",         (0,0),(-1,-1), 0.3, GRAY_MID),
        ("LEFTPADDING",  (0,0),(-1,-1), 7),
        ("RIGHTPADDING", (0,0),(-1,-1), 7),
        ("TOPPADDING",   (0,0),(-1,-1), 5),
        ("BOTTOMPADDING",(0,0),(-1,-1), 5),
        ("FONTSIZE",     (0,0),(-1,-1), 8),
        ("VALIGN",       (0,0),(-1,-1), "TOP"),
    ]

def section_header(title, W):
    hdr = S(f"sh_{id(title)}", fontName="Helvetica-Bold", fontSize=10, textColor=CAST_WHITE)
    t = Table([[Paragraph(f"  {title}", hdr)]], colWidths=[W])
    t.setStyle(TableStyle([
        ("BACKGROUND",    (0,0),(0,0), CAST_BLUE),
        ("TOPPADDING",    (0,0),(0,0), 8),
        ("BOTTOMPADDING", (0,0),(0,0), 8),
    ]))
    return t

def callout(text, W, bg=AMBER_LIGHT, border=AMBER_WARN, tc=AMBER_DARK):
    p = S(f"co_{id(text)}", fontSize=8.5, textColor=tc, leading=13)
    t = Table([[Paragraph(text, p)]], colWidths=[W])
    t.setStyle(TableStyle([
        ("BACKGROUND",    (0,0),(0,0), bg),
        ("BOX",           (0,0),(0,0), 1, border),
        ("TOPPADDING",    (0,0),(0,0), 7),
        ("BOTTOMPADDING", (0,0),(0,0), 7),
        ("LEFTPADDING",   (0,0),(0,0), 10),
        ("RIGHTPADDING",  (0,0),(0,0), 10),
    ]))
    return t

def make_decorator(cluster_name, cluster_id, generated_at):
    def decorate(canvas_obj, doc):
        W, H = letter
        canvas_obj.setFillColor(CAST_BLACK)
        canvas_obj.rect(0, H-50, W, 50, fill=1, stroke=0)
        if ICON_PATH:
            canvas_obj.drawImage(ICON_PATH, 28, H-46, width=34, height=34,
                                 mask="auto", preserveAspectRatio=True)
            canvas_obj.setFillColor(CAST_WHITE)
            canvas_obj.setFont("Helvetica-Bold", 16)
            canvas_obj.drawString(68, H-33, "CAST AI")
        else:
            canvas_obj.setFillColor(CAST_BLUE)
            canvas_obj.circle(44, H-25, 12, fill=1, stroke=0)
            canvas_obj.setFillColor(CAST_WHITE)
            canvas_obj.setFont("Helvetica-Bold", 16)
            canvas_obj.drawString(62, H-33, "CAST AI")
        canvas_obj.setFont("Helvetica-Bold", 7)
        canvas_obj.setFillColor(CAST_WHITE)
        canvas_obj.drawRightString(W-28, H-16, "CAST AI TAM · CLUSTER OPTIMISATION")
        canvas_obj.setFont("Helvetica", 7)
        canvas_obj.setFillColor(CAST_BLUE)
        canvas_obj.drawRightString(W-28, H-28, "CONFIDENTIAL")
        canvas_obj.setFillColor(CAST_BLUE)
        canvas_obj.rect(0, H-54, W, 4, fill=1, stroke=0)
        # Footer
        canvas_obj.setFillColor(CAST_BLACK)
        canvas_obj.rect(0, 0, W, 22, fill=1, stroke=0)
        if ICON_PATH:
            canvas_obj.drawImage(ICON_PATH, 28, 3, width=16, height=16,
                                 mask="auto", preserveAspectRatio=True)
            canvas_obj.setFillColor(CAST_WHITE)
            canvas_obj.setFont("Helvetica-Bold", 8)
            canvas_obj.drawString(48, 7, "CAST AI")
        else:
            canvas_obj.setFillColor(CAST_BLUE)
            canvas_obj.circle(36, 11, 6, fill=1, stroke=0)
            canvas_obj.setFillColor(CAST_WHITE)
            canvas_obj.setFont("Helvetica-Bold", 8)
            canvas_obj.drawString(46, 7, "CAST AI")
        canvas_obj.setFillColor(GRAY_DARK)
        canvas_obj.setFont("Helvetica", 6.5)
        foot = f"CAST AI Customer Success · Confidential · {generated_at} · {cluster_name} · {cluster_id}"
        canvas_obj.drawString(92, 7, foot)
    return decorate

# ── Cover page ─────────────────────────────────────────────────────────────────
def cover(story, data, W):
    story.append(Spacer(1, 0.6*inch))
    t = Table([[Paragraph("Cluster Optimisation Report",
                           S("cov_t", fontName="Helvetica-Bold", fontSize=22,
                             textColor=CAST_BLUE, leading=28))]], colWidths=[W])
    story.append(t)
    story.append(Spacer(1, 0.15*inch))

    meta = [
        ["Cluster",    data.get("cluster_name","—")],
        ["Cluster ID", data.get("cluster_id","—")],
        ["Generated",  data.get("generated_at","—")],
    ]
    mt = Table(meta, colWidths=[1.4*inch, W-1.4*inch])
    mt.setStyle(TableStyle([
        ("FONTNAME",  (0,0),(-1,-1), "Helvetica"),
        ("FONTNAME",  (0,0),(0,-1),  "Helvetica-Bold"),
        ("FONTSIZE",  (0,0),(-1,-1), 9),
        ("TEXTCOLOR", (0,0),(0,-1),  GRAY_DARK),
        ("TOPPADDING",(0,0),(-1,-1), 4),
        ("BOTTOMPADDING",(0,0),(-1,-1), 4),
        ("LINEBELOW", (0,0),(-1,-2), 0.3, GRAY_MID),
    ]))
    story.append(mt)
    story.append(Spacer(1, 0.3*inch))

    # Summary scorecard
    ev   = data["evictor"]
    ph   = data["pod_health"]
    mpn  = data["max_pod_per_node"]
    nt   = data["node_templates"]
    ntrp = data.get("nt_resource_profile", {})
    wr   = data.get("woop_rollout", {})

    blocked   = len(ev["blocked_nodes"])
    xmatch    = len(ev["cross_matches"])
    unhealthy = len(ph["unhealthy"])
    at_cap    = len(mpn["at_capacity"])
    merge_c   = len(nt["merge_candidates"])
    misconfig = len(nt["misconfigured"])
    nt_issues = sum(1 for t in ntrp.get("templates", []) if t.get("pattern") != "general-purpose")
    woop_issues = wr.get("warnings", 0) + wr.get("action_needed", 0)

    def badge(val, label, warn_threshold=1, crit_threshold=None):
        if crit_threshold is not None and val >= crit_threshold:
            bg, tc = RED_LIGHT, RED_FAIL
        elif val >= warn_threshold:
            bg, tc = AMBER_LIGHT, AMBER_DARK
        else:
            bg, tc = GREEN_LIGHT, GREEN_PASS
        cell = Table([[
            Paragraph(str(val), S(f"b_{label}", fontName="Helvetica-Bold", fontSize=18, textColor=tc, leading=22, alignment=TA_CENTER)),
            Paragraph(label, S(f"bl_{label}", fontSize=8, textColor=tc, leading=11)),
        ]], colWidths=[0.55*inch, 1.2*inch])
        cell.setStyle(TableStyle([
            ("BACKGROUND", (0,0),(-1,-1), bg),
            ("BOX",        (0,0),(-1,-1), 1, tc),
            ("TOPPADDING", (0,0),(-1,-1), 8),
            ("BOTTOMPADDING",(0,0),(-1,-1), 8),
            ("LEFTPADDING",(0,0),(-1,-1), 8),
            ("VALIGN",     (0,0),(-1,-1), "MIDDLE"),
        ]))
        return cell

    cw = W / 7
    badges = Table([[
        badge(blocked,    "Nodes Blocked",       1, 5),
        badge(xmatch,     "Cross-matches",        1, 3),
        badge(unhealthy,  "Unhealthy Pods",       1, 10),
        badge(at_cap,     "Nodes at Pod Cap",     1, 5),
        badge(merge_c,    "Merge Candidates",     1, 99),  # warn only, never red
        badge(nt_issues,  "NT Profile Issues",    1, 99),  # warn only, never red
        badge(woop_issues,"WOOP Rollout Issues",  1, 3),
    ]], colWidths=[cw]*7)
    badges.setStyle(TableStyle([("LEFTPADDING",(0,0),(-1,-1),3),("RIGHTPADDING",(0,0),(-1,-1),3)]))
    story.append(badges)
    story.append(PageBreak())

# ── Exec Summary page ────────────────────────────────────────────────────────
def section_exec_summary(story, data, W):
    es = data.get("exec_summary", {})
    critical = es.get("critical", [])
    high     = es.get("high", [])
    medium   = es.get("medium", [])

    if not critical and not high and not medium:
        return  # nothing to show

    story.append(section_header("Executive Summary — Priority Actions", W))
    story.append(Spacer(1, 8))

    intro_s = S("es_intro", fontSize=8.5, textColor=GRAY_DARK, leading=13)
    story.append(Paragraph(
        "The following actions are ranked by impact. Address critical items before enabling "
        "further Cast AI automation features.",
        intro_s))
    story.append(Spacer(1, 10))

    PRIORITY_CONFIG = [
        ("CRITICAL", critical, RED_FAIL,   RED_LIGHT),
        ("HIGH",     high,     AMBER_WARN, AMBER_LIGHT),
        ("MEDIUM",   medium,   BLUE_INFO,  BLUE_LIGHT),
    ]

    for priority_label, items, border_color, bg_color in PRIORITY_CONFIG:
        if not items:
            continue

        # Priority label header
        lbl_s = S(f"es_lbl_{priority_label}", fontName="Helvetica-Bold",
                  fontSize=8, textColor=border_color)
        story.append(Paragraph(priority_label, lbl_s))
        story.append(Spacer(1, 4))

        hdr_s = S(f"es_hdr_{priority_label}", fontName="Helvetica-Bold",
                  fontSize=8, textColor=CAST_WHITE)
        row_s = S(f"es_row_{priority_label}", fontSize=8, textColor=CAST_BLACK)
        act_s = S(f"es_act_{priority_label}", fontSize=8, textColor=border_color,
                  fontName="Helvetica-Bold")

        rows = [[
            Paragraph("Area", hdr_s),
            Paragraph("Finding", hdr_s),
            Paragraph("Recommended Action", hdr_s),
        ]]
        for item in items:
            rows.append([
                Paragraph(item.get("area", ""), row_s),
                Paragraph(item.get("finding", ""), row_s),
                Paragraph(item.get("action", ""), act_s),
            ])

        t = Table(rows, colWidths=[W*0.15, W*0.42, W*0.43])
        t.setStyle(TableStyle(grid([
            ("BACKGROUND", (0,0),(-1,0), CAST_BLUE),
            ("ROWBACKGROUNDS", (0,1),(-1,-1), [bg_color, CAST_WHITE]),
        ])))
        story.append(t)
        story.append(Spacer(1, 10))

    story.append(PageBreak())

# ── Section 1: Evictor ────────────────────────────────────────────────────────
def section_evictor(story, data, W):
    ev = data["evictor"]
    story.append(section_header("1. Evictor Analysis", W))
    story.append(Spacer(1, 6))

    meta_p = S("em", fontSize=8.5, textColor=GRAY_DARK)
    story.append(Paragraph(
        f"Window: {ev.get('window_start','—')} → {ev.get('window_end','—')}  |  "
        f"Reconcile cycles: {ev.get('reconcile_cycles',0)}  |  "
        f"Evictions completed: {ev.get('evictions_completed',0)}",
        meta_p))
    story.append(Spacer(1, 6))

    xm = ev.get("cross_matches", [])
    if xm:
        for x in xm:
            story.append(callout(
                f"CROSS-MATCH  {x['pod']} in {x['namespace']} is blocking node "
                f"{x['node']} AND is in a bad state ({x['reason']}). "
                f"This pod cannot be rescheduled — explains the persistent eviction block.",
                W, bg=RED_LIGHT, border=RED_FAIL, tc=RED_FAIL))
            story.append(Spacer(1, 4))

    blocked = ev.get("blocked_nodes", [])
    if blocked:
        hdr_s = S("eh", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("er", fontSize=8, textColor=CAST_BLACK)
        rows = [[
            Paragraph("Node", hdr_s),
            Paragraph("Category", hdr_s),
            Paragraph("Blocking Pod", hdr_s),
            Paragraph("Namespace", hdr_s),
        ]]
        for b in blocked:
            rows.append([
                Paragraph(b.get("node",""), row_s),
                Paragraph(b.get("category",""), row_s),
                Paragraph(b.get("blocking_pod",""), row_s),
                Paragraph(b.get("namespace",""), row_s),
            ])
        t = Table(rows, colWidths=[W*0.28, W*0.18, W*0.30, W*0.24])
        ts_extra = [("BACKGROUND",(0,0),(-1,0), CAST_BLUE),
                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE, GRAY_LIGHT])]
        t.setStyle(TableStyle(grid(ts_extra)))
        story.append(t)
    else:
        story.append(callout("No evictor blockers found in the analysis window.", W,
                             bg=GREEN_LIGHT, border=GREEN_PASS, tc=GREEN_PASS))
    story.append(Spacer(1, 12))

# ── Section 2: Pod Health ─────────────────────────────────────────────────────
def section_pod_health(story, data, W):
    ph = data["pod_health"]
    story.append(section_header("2. Pod Health", W))
    story.append(Spacer(1, 6))

    unhealthy = ph.get("unhealthy", [])
    if not unhealthy:
        story.append(callout("All pods healthy — no Pending/Failed/CrashLoopBackOff pods found.", W,
                             bg=GREEN_LIGHT, border=GREEN_PASS, tc=GREEN_PASS))
    else:
        hdr_s = S("ph", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("pr", fontSize=8, textColor=CAST_BLACK)
        rows = [[Paragraph(c, hdr_s) for c in ["Pod","Namespace","Phase","Container","State","Reason","Restarts"]]]
        for p in unhealthy:
            reason = p.get("reason","")
            bg_c = RED_LIGHT if reason in ("CrashLoopBackOff","OOMKilled") else AMBER_LIGHT
            rows.append([
                Paragraph(p.get("name",""), row_s),
                Paragraph(p.get("namespace",""), row_s),
                Paragraph(p.get("phase",""), row_s),
                Paragraph(p.get("container",""), row_s),
                Paragraph(p.get("state",""), row_s),
                Paragraph(reason, S(f"rr_{reason}", fontSize=8,
                                    textColor=RED_FAIL if reason in ("CrashLoopBackOff","OOMKilled") else AMBER_DARK)),
                Paragraph(str(p.get("restarts",0)), row_s),
            ])
        cw = [W*0.20, W*0.14, W*0.10, W*0.14, W*0.10, W*0.20, W*0.12]
        t = Table(rows, colWidths=cw)
        t.setStyle(TableStyle(grid([("BACKGROUND",(0,0),(-1,0), CAST_BLUE),
                                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE,GRAY_LIGHT])])))
        story.append(t)
    story.append(Spacer(1, 12))


# ── Section 4: Max Pod Per Node ───────────────────────────────────────────────
def section_max_pod(story, data, W):
    mpn = data["max_pod_per_node"]
    story.append(section_header("3. Max Pod Per Node", W))
    story.append(Spacer(1, 6))

    cfg = mpn.get("config_summary", [])
    if cfg:
        hdr_s = S("mph", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("mpr", fontSize=8, textColor=CAST_BLACK)
        rows = [[Paragraph(c, hdr_s) for c in ["Node Config","Instance Type","Provider","Max Pods","Nodes"]]]
        for r in cfg:
            rows.append([
                Paragraph(r.get("node_config",""), row_s),
                Paragraph(r.get("instance_type",""), row_s),
                Paragraph(r.get("provider",""), row_s),
                Paragraph(str(r.get("max_pods","")), row_s),
                Paragraph(str(r.get("node_count","")), row_s),
            ])
        t = Table(rows, colWidths=[W*0.24, W*0.22, W*0.14, W*0.18, W*0.12, W*0.10][:5])
        t.setStyle(TableStyle(grid([("BACKGROUND",(0,0),(-1,0), CAST_BLUE),
                                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE,GRAY_LIGHT])])))
        story.append(t)
        story.append(Spacer(1, 8))

    at_cap = mpn.get("at_capacity", [])
    if at_cap:
        story.append(Paragraph("Nodes at or Near Pod Capacity",
                                S("mpnhdr", fontName="Helvetica-Bold", fontSize=9, textColor=RED_FAIL)))
        story.append(Spacer(1, 4))
        hdr_s = S("mph2", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("mpr2", fontSize=8, textColor=CAST_BLACK)
        rows = [[Paragraph(c, hdr_s) for c in ["Node","Instance","Config","Allocatable","Running","Utilization"]]]
        for r in at_cap:
            pct = r.get("pct", 0)
            flag = "AT CAPACITY" if pct >= 100 else "NEAR CAPACITY"
            pct_style = S(f"pct_{pct}", fontSize=8,
                          textColor=RED_FAIL if pct >= 100 else AMBER_DARK,
                          fontName="Helvetica-Bold")
            rows.append([
                Paragraph(r.get("node",""), row_s),
                Paragraph(r.get("instance_type",""), row_s),
                Paragraph(r.get("config",""), row_s),
                Paragraph(str(r.get("allocatable","")), row_s),
                Paragraph(str(r.get("running","")), row_s),
                Paragraph(f"{pct}% {flag}", pct_style),
            ])
        t = Table(rows, colWidths=[W*0.26, W*0.16, W*0.14, W*0.12, W*0.10, W*0.22])
        t.setStyle(TableStyle(grid([("BACKGROUND",(0,0),(-1,0), CAST_BLUE),
                                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[RED_LIGHT,CAST_WHITE])])))
        story.append(t)
    else:
        story.append(callout("No nodes at or near pod capacity.", W,
                             bg=GREEN_LIGHT, border=GREEN_PASS, tc=GREEN_PASS))
    story.append(Spacer(1, 12))

# ── Section 5: Node Template Analysis ────────────────────────────────────────
def section_node_templates(story, data, W):
    nt = data["node_templates"]
    story.append(section_header("4. Node Template Analysis", W))
    story.append(Spacer(1, 6))

    inventory = nt.get("inventory", [])
    if inventory:
        hdr_s = S("nth", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("ntr", fontSize=8, textColor=CAST_BLACK)
        rows = [[Paragraph(c, hdr_s) for c in ["Template","Nodes","Arch","Capacity","OS","Instance Types","Taints","GPU"]]]
        for r in inventory:
            rows.append([
                Paragraph(r.get("template",""), row_s),
                Paragraph(str(r.get("count","")), row_s),
                Paragraph(", ".join(r.get("arch",[])), row_s),
                Paragraph(", ".join(r.get("capacity_type",[])), row_s),
                Paragraph(", ".join(r.get("os",[])), row_s),
                Paragraph(", ".join(r.get("instance_types",[])), row_s),
                Paragraph(", ".join(r.get("taints",[])) or "None", row_s),
                Paragraph("Yes" if r.get("gpu") else "No", row_s),
            ])
        cw = [W*0.17, W*0.06, W*0.08, W*0.10, W*0.07, W*0.22, W*0.20, W*0.06]
        t = Table(rows, colWidths=cw)
        t.setStyle(TableStyle(grid([("BACKGROUND",(0,0),(-1,0), CAST_BLUE),
                                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE,GRAY_LIGHT])])))
        story.append(t)
        story.append(Spacer(1, 10))

    merge = nt.get("merge_candidates", [])
    keep  = nt.get("keep_separate", [])
    misc  = nt.get("misconfigured", [])

    story.append(Paragraph("Consolidation Recommendations",
                            S("crhdr", fontName="Helvetica-Bold", fontSize=9, textColor=CAST_BLACK)))
    story.append(Spacer(1, 4))

    if merge:
        for m in merge:
            tnames = " + ".join(f"`{x}`" for x in m.get("templates",[]))
            story.append(callout(
                f"MERGE CANDIDATE: {tnames}\n{m.get('reason','')}",
                W, bg=BLUE_LIGHT, border=BLUE_INFO, tc=BLUE_INFO))
            story.append(Spacer(1, 4))

    if misc:
        for ms in misc:
            story.append(callout(
                f"MISCONFIGURED: {ms.get('template','')} — {ms.get('issue','')}",
                W, bg=RED_LIGHT, border=RED_FAIL, tc=RED_FAIL))
            story.append(Spacer(1, 4))

    if keep:
        for k in keep:
            story.append(callout(
                f"KEEP SEPARATE: {k.get('template','')} — {k.get('reason','')}",
                W, bg=GRAY_LIGHT, border=GRAY_MID, tc=GRAY_DARK))
            story.append(Spacer(1, 4))

    if not merge and not misc and not keep:
        story.append(callout("No consolidation opportunities found. All templates are correctly scoped.", W,
                             bg=GREEN_LIGHT, border=GREEN_PASS, tc=GREEN_PASS))
    story.append(Spacer(1, 12))

# ── Section 6: NT Resource Profile ───────────────────────────────────────────
def section_nt_resource_profile(story, data, W):
    ntrp = data.get("nt_resource_profile", {})
    story.append(section_header("5. Node Template Resource Profile", W))
    story.append(Spacer(1, 6))

    templates = ntrp.get("templates", [])
    if not templates:
        story.append(callout("No resource profile data available.", W,
                             bg=GRAY_LIGHT, border=GRAY_MID, tc=GRAY_DARK))
        story.append(Spacer(1, 12))
        return

    PATTERN_COLORS = {
        "memory-heavy":    (PURPLE_LIGHT, PURPLE),
        "compute-heavy":   (ORANGE_LIGHT, ORANGE_WARN),
        "general-purpose": (GREEN_LIGHT,  GREEN_PASS),
    }
    PATTERN_RECO = {
        "memory-heavy":    "r6i/r7g (AWS)  ·  n2-highmem (GCP)  ·  Epsv5 (Azure)",
        "compute-heavy":   "c6i/c7g (AWS)  ·  n2-highcpu (GCP)  ·  Fsv2 (Azure)",
        "general-purpose": "m6i/m7g (AWS)  ·  n2-standard (GCP)  ·  Dsv5 (Azure)",
    }

    hdr_s = S("ntrph", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
    row_s = S("ntrpr", fontSize=8, textColor=CAST_BLACK)
    rows  = [[Paragraph(c, hdr_s) for c in
              ["Template", "Nodes", "CPU Req", "Mem Req", "CPU:Mem Ratio", "Pattern", "Recommendation"]]]

    for t in templates:
        pattern = t.get("pattern", "general-purpose")
        _, tc   = PATTERN_COLORS.get(pattern, (CAST_WHITE, CAST_BLACK))
        pat_s   = S(f"pat_{t.get('template','')}", fontSize=8, textColor=tc, fontName="Helvetica-Bold")
        reco    = t.get("recommendation") or PATTERN_RECO.get(pattern, "")
        rows.append([
            Paragraph(t.get("template", ""), row_s),
            Paragraph(str(t.get("node_count", "")), row_s),
            Paragraph(f"{t.get('cpu_vcpu', 0)} vCPU", row_s),
            Paragraph(f"{t.get('mem_gi', 0)} Gi", row_s),
            Paragraph(t.get("ratio_str", ""), row_s),
            Paragraph(pattern, pat_s),
            Paragraph(reco, row_s),
        ])

    t = Table(rows, colWidths=[W*0.14, W*0.06, W*0.09, W*0.09, W*0.12, W*0.14, W*0.36])
    t.setStyle(TableStyle(grid([("BACKGROUND", (0,0),(-1,0), CAST_BLUE),
                                ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE,GRAY_LIGHT])])))
    story.append(t)
    story.append(Spacer(1, 8))

    if ntrp.get("ds_advisory"):
        ds_pct = ntrp.get("ds_cpu_pct", 0)
        total  = ntrp.get("total_nodes", 0)
        story.append(callout(
            f"ADVISORY: DaemonSet pods are consuming {ds_pct}% of total cluster CPU across {total} nodes.\n"
            f"On the current instance sizes, DaemonSet overhead per node is disproportionately high.\n"
            f"Recommendation: Set minCPU=4 in node templates to enforce a minimum instance size "
            f"and reduce DaemonSet-to-workload CPU dilution.",
            W, bg=AMBER_LIGHT, border=AMBER_WARN, tc=AMBER_DARK))

    story.append(Spacer(1, 12))

# ── Section 7: WOOP Rollout Strategy ─────────────────────────────────────────
def section_woop_rollout(story, data, W):
    wr = data.get("woop_rollout", {})
    story.append(section_header("7. WOOP Rollout Strategy Audit", W))
    story.append(Spacer(1, 6))

    if not wr.get("active", False):
        story.append(callout("WOOP not active on this cluster or no managed workloads found.",
                             W, bg=GRAY_LIGHT, border=GRAY_MID, tc=GRAY_DARK))
        story.append(Spacer(1, 12))
        return

    total   = wr.get("total_checked", 0)
    ok      = wr.get("ok", 0)
    warns   = wr.get("warnings", 0)
    actions = wr.get("action_needed", 0)

    summary_s = S("wrsumm", fontSize=9, textColor=CAST_BLACK)
    story.append(Paragraph(
        f"Total WOOP workloads checked: <b>{total}</b>  |  "
        f"<font color='#22C55E'>OK: {ok}</font>  |  "
        f"<font color='#F59E0B'>Warnings: {warns}</font>  |  "
        f"<font color='#EF4444'>Action Needed: {actions}</font>",
        summary_s))
    story.append(Spacer(1, 8))

    issues = wr.get("issues", [])
    if not issues:
        story.append(callout(
            "All WOOP workloads are using one-by-one rollout. No zero-downtime issues found.",
            W, bg=GREEN_LIGHT, border=GREEN_PASS, tc=GREEN_PASS))
    else:
        hdr_s = S("wrhdr", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("wrrow", fontSize=8, textColor=CAST_BLACK)
        rows  = [[Paragraph(c, hdr_s) for c in
                  ["Workload", "Namespace", "Replicas", "Rollout Strategy", "Zero-Downtime", "Status"]]]
        for issue in issues:
            status = issue.get("status", "")
            if status == "ACTION NEEDED":
                st_s = S(f"wrs_{issue.get('workload','')}", fontSize=8,
                         textColor=RED_FAIL, fontName="Helvetica-Bold")
                row_bg = RED_LIGHT
            else:
                st_s = S(f"wrs_{issue.get('workload','')}", fontSize=8,
                         textColor=AMBER_DARK, fontName="Helvetica-Bold")
                row_bg = AMBER_LIGHT

            replicas = issue.get("replicas", "")
            zdt_val  = issue.get("zero_downtime")
            if replicas != 1:
                zdt_str = "N/A (multi)"
            else:
                zdt_str = "Enforced" if zdt_val else "Not enforced"

            rows.append([
                Paragraph(issue.get("workload", ""), row_s),
                Paragraph(issue.get("namespace", ""), row_s),
                Paragraph(str(replicas), row_s),
                Paragraph(issue.get("rollout_strategy", ""), row_s),
                Paragraph(zdt_str, row_s),
                Paragraph(status, st_s),
            ])

        t = Table(rows, colWidths=[W*0.22, W*0.15, W*0.09, W*0.18, W*0.16, W*0.20])
        t.setStyle(TableStyle(grid([("BACKGROUND", (0,0),(-1,0), CAST_BLUE),
                                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE,GRAY_LIGHT])])))
        story.append(t)

    story.append(Spacer(1, 12))

# ── Section 6: Rebalancing ───────────────────────────────────────────────────
def _rb_int(v):
    return "—" if v is None else str(v)

def _rb_num(v, nd=1, suffix=""):
    if v is None:
        return "—"
    try:
        return f"{float(v):,.{nd}f}{suffix}"
    except (TypeError, ValueError):
        return str(v)

def _rb_money(v):
    if v is None:
        return "—"
    try:
        return f"${float(v):,.2f}"
    except (TypeError, ValueError):
        return str(v)

def _rb_status(e):
    # Flag-based checks first (preserves existing behaviour when flags are set).
    if e.get("is_skipped"):
        return "Skipped", GRAY_DARK
    if e.get("is_partial"):
        return "Partial", AMBER_DARK
    if e.get("is_success") is not None:
        return ("Success", GREEN_PASS) if e.get("is_success") else ("Failed", RED_FAIL)
    # Flag-absence path: key off the raw status string. Missing/unknown status
    # renders as "Unknown" — never silently "Failed".
    status = str(e.get("status") or "").lower()
    if status == "error":
        return "Failed", RED_FAIL
    if status == "partially_finished":
        return "Partial", AMBER_DARK
    if status == "generated":
        return "Skipped", GRAY_DARK
    if status == "finished":
        return ("Success", GREEN_PASS) if e.get("is_success") else ("Failed", RED_FAIL)
    return "Unknown", GRAY_DARK

# severity -> (row background, badge/border color, title text color)
_RB_SEV_STYLES = {
    "critical": (RED_LIGHT,   RED_FAIL,   RED_FAIL),
    "warning":  (AMBER_LIGHT, AMBER_WARN, AMBER_DARK),
    "info":     (BLUE_LIGHT,  BLUE_INFO,  BLUE_INFO),
}

def section_rebalancing(story, data, W):
    rb = data.get("rebalancing") or {}
    story.append(section_header("6. Rebalancing", W))
    story.append(Spacer(1, 6))

    # Schedules
    schedules   = rb.get("schedules") or []
    sched_names = ", ".join(s.get("name", "") for s in schedules if s.get("name"))
    story.append(Paragraph(
        f"Rebalancing schedules: {escape(str(sched_names)) if sched_names else 'None configured'}",
        S("rbmeta", fontSize=8.5, textColor=GRAY_DARK)))
    story.append(Spacer(1, 8))

    # Last completed rebalance
    story.append(Paragraph("Last Completed Rebalance",
                            S("rblh", fontName="Helvetica-Bold", fontSize=9, textColor=CAST_BLACK)))
    story.append(Spacer(1, 4))
    lr = rb.get("last_rebalance") or {}
    if not lr.get("has_rebalancing"):
        story.append(callout("No rebalancing has run.", W,
                             bg=GRAY_LIGHT, border=GRAY_MID, tc=GRAY_DARK))
    else:
        lbl_s = S("rblbl", fontName="Helvetica-Bold", fontSize=8, textColor=GRAY_DARK)
        val_s = S("rbval", fontSize=8, textColor=CAST_BLACK)
        days  = lr.get("days_since")
        days_str = f"{days} days ago" if days is not None else "—"
        pairs = [
            ("Date",
             f"{escape(str(lr.get('last_rebalance_date') or '—'))} ({escape(str(days_str))})"),
            ("Nodes",
             f"{_rb_int(lr.get('nodes_before'))} → {_rb_int(lr.get('nodes_after'))}  "
             f"({_rb_num(lr.get('nodes_reduction_pct'))}% reduction)"),
            ("CPU",
             f"{_rb_num(lr.get('cpu_reduction_pct'))}% reduction"),
            ("Cost",
             f"{_rb_money(lr.get('cost_before_hourly'))}/hr → {_rb_money(lr.get('cost_after_hourly'))}/hr"),
            ("Savings",
             f"{_rb_money(lr.get('cost_savings_monthly'))}/mo  "
             f"({_rb_num(lr.get('cost_savings_pct'))}%)"),
        ]
        rows = [[Paragraph(l, lbl_s), Paragraph(v, val_s)] for l, v in pairs]
        t = Table(rows, colWidths=[W*0.16, W*0.84])
        t.setStyle(TableStyle(grid([("BACKGROUND", (0,0),(0,-1), GRAY_LIGHT)])))
        story.append(t)
    story.append(Spacer(1, 10))

    # Recent events
    story.append(Paragraph("Recent Rebalancing Events",
                            S("rbev", fontName="Helvetica-Bold", fontSize=9, textColor=CAST_BLACK)))
    story.append(Spacer(1, 4))
    events = rb.get("events") or []
    if not events:
        story.append(callout("No recent rebalancing plans.", W,
                             bg=GRAY_LIGHT, border=GRAY_MID, tc=GRAY_DARK))
    else:
        hdr_s = S("rbh", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("rbr", fontSize=8, textColor=CAST_BLACK)
        rows  = [[Paragraph(c, hdr_s) for c in
                  ["Date", "Status", "Schedule", "Nodes", "CPU", "Savings $/mo", "%"]]]
        for e in events:
            status, tc = _rb_status(e)
            st_s = S(f"rbs_{e.get('plan_id','')}", fontSize=8, textColor=tc,
                     fontName="Helvetica-Bold")
            status_text = status
            if status == "Skipped" and e.get("skip_reason"):
                status_text = (f"Skipped<br/><font size=6.5 color='#6B7280'>"
                               f"{escape(str(e['skip_reason']))}</font>")
            elif status == "Failed" and e.get("error_summary"):
                status_text = (f"Failed<br/><font size=6.5 color='#EF4444'>"
                               f"{escape(str(e['error_summary']))}</font>")
            rows.append([
                Paragraph(escape(str(e.get("date") or "—")), row_s),
                Paragraph(status_text, st_s),
                Paragraph(escape(str(e.get("schedule_name") or "—")), row_s),
                Paragraph(f"{_rb_int(e.get('nodes_before'))} → {_rb_int(e.get('nodes_after'))}", row_s),
                Paragraph(f"{_rb_num(e.get('cpu_before'))} → {_rb_num(e.get('cpu_after'))}", row_s),
                Paragraph(_rb_money(e.get("cost_savings_monthly")), row_s),
                Paragraph(_rb_num(e.get("cost_savings_pct"), suffix="%"), row_s),
            ])
        t = Table(rows, colWidths=[W*0.12, W*0.24, W*0.13, W*0.13, W*0.14, W*0.14, W*0.10])
        t.setStyle(TableStyle(grid([("BACKGROUND",(0,0),(-1,0), CAST_BLUE),
                                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE,GRAY_LIGHT])])))
        story.append(t)
    story.append(Spacer(1, 10))

    # Old on-demand nodes
    story.append(Paragraph("Old On-Demand CAST-Managed Nodes (>= 30 Days)",
                            S("rbod", fontName="Helvetica-Bold", fontSize=9, textColor=CAST_BLACK)))
    story.append(Spacer(1, 4))
    od = rb.get("old_ondemand_nodes") or []
    if not od:
        story.append(callout("No old on-demand CAST-managed nodes (>= 30 days).", W,
                             bg=GREEN_LIGHT, border=GREEN_PASS, tc=GREEN_PASS))
    else:
        hdr_s = S("rbodh", fontName="Helvetica-Bold", fontSize=8, textColor=CAST_WHITE)
        row_s = S("rbodr", fontSize=8, textColor=CAST_BLACK)
        rows  = [[Paragraph(c, hdr_s) for c in ["Node", "Instance Type", "Age (days)"]]]
        for n in od:
            rows.append([
                Paragraph(escape(str(n.get("name", ""))), row_s),
                Paragraph(escape(str(n.get("instance_type", ""))), row_s),
                Paragraph(escape(str(n.get("age_days", ""))), row_s),
            ])
        t = Table(rows, colWidths=[W*0.50, W*0.28, W*0.22])
        t.setStyle(TableStyle(grid([("BACKGROUND",(0,0),(-1,0), CAST_BLUE),
                                    ("ROWBACKGROUNDS",(0,1),(-1,-1),[CAST_WHITE,GRAY_LIGHT])])))
        story.append(t)
        story.append(Spacer(1, 4))
        story.append(Paragraph(
            f"Total old on-demand nodes: <b>{escape(str(rb.get('old_ondemand_count', len(od))))}</b>",
            S("rbodt", fontSize=8.5, textColor=GRAY_DARK)))
    story.append(Spacer(1, 10))

    # Rebalancing health findings (Step 7f) — rendered only when findings exist;
    # an absent subsection means healthy / no data (no "no findings" noise).
    rbh          = data.get("rebalancing_health") or {}
    rb_findings  = rbh.get("findings") or []
    if rb_findings:
        story.append(Paragraph("Rebalancing Health Findings",
                                S("rbfh", fontName="Helvetica-Bold", fontSize=9, textColor=CAST_BLACK)))
        story.append(Spacer(1, 4))
        _sev_order = {"critical": 0, "warning": 1, "info": 2}
        for f in sorted(rb_findings,
                        key=lambda x: _sev_order.get(str(x.get("severity", "info")).lower(), 2)):
            sev = str(f.get("severity", "info")).lower()
            bg, border, tc = _RB_SEV_STYLES.get(sev, _RB_SEV_STYLES["info"])
            badge_text = str(f.get("severity", "info")).upper()
            badge_s = S(f"rbfb_{id(f)}", fontName="Helvetica-Bold", fontSize=7,
                        textColor=CAST_WHITE, alignment=TA_CENTER, leading=9)
            badge = Table([[Paragraph(badge_text, badge_s)]], colWidths=[0.72*inch])
            badge.setStyle(TableStyle([
                ("BACKGROUND",    (0,0),(-1,-1), border),
                ("TOPPADDING",    (0,0),(-1,-1), 2),
                ("BOTTOMPADDING", (0,0),(-1,-1), 2),
            ]))
            title_s  = S(f"rbft_{id(f)}", fontName="Helvetica-Bold", fontSize=8.5,
                         textColor=tc, leading=12)
            detail_s = S(f"rbfd_{id(f)}", fontSize=8, textColor=CAST_BLACK, leading=11.5)
            body = [Paragraph(escape(str(f.get("title", ""))), title_s)]
            if f.get("detail"):
                body += [Spacer(1, 2), Paragraph(escape(str(f.get("detail", ""))), detail_s)]
            row = Table([[badge, body]], colWidths=[0.82*inch, W-0.82*inch])
            row.setStyle(TableStyle([
                ("BACKGROUND",    (0,1),(-1,-1), bg),
                ("BOX",           (0,0),(-1,-1), 1, border),
                ("LEFTPADDING",   (0,0),(-1,-1), 8),
                ("RIGHTPADDING",  (0,0),(-1,-1), 8),
                ("TOPPADDING",    (0,0),(-1,-1), 6),
                ("BOTTOMPADDING", (0,0),(-1,-1), 6),
                ("VALIGN",        (0,0),(-1,-1), "TOP"),
            ]))
            story.append(row)
            story.append(Spacer(1, 4))
        story.append(Spacer(1, 6))

    # Audit events are Step 7f diagnostic context (they inform finding wording,
    # e.g. why a schedule skipped) — they never render as a PDF table: on
    # healthy-but-skipping clusters the raw trail just repeats the events table.
    story.append(Spacer(1, 6))

# ── Main ──────────────────────────────────────────────────────────────────────
def generate(data, output_path):
    doc = BaseDocTemplate(
        output_path, pagesize=letter,
        leftMargin=30, rightMargin=30,
        topMargin=68, bottomMargin=30,
    )
    W     = doc.width
    frame = Frame(doc.leftMargin, doc.bottomMargin, W, doc.height, id="main")
    deco  = make_decorator(
        data.get("cluster_name",""),
        data.get("cluster_id",""),
        data.get("generated_at",""))
    doc.addPageTemplates([PageTemplate(id="main", frames=[frame], onPage=deco)])

    story = []
    cover(story, data, W)
    section_exec_summary(story, data, W)
    section_evictor(story, data, W)
    section_pod_health(story, data, W)
    section_max_pod(story, data, W)
    section_node_templates(story, data, W)
    section_nt_resource_profile(story, data, W)
    section_rebalancing(story, data, W)
    section_woop_rollout(story, data, W)
    doc.build(story)
    print(f"Report written: {output_path}")

if __name__ == "__main__":
    data_path   = sys.argv[1] if len(sys.argv) > 1 else "/home/claude/cast_optimise_data.json"
    output_path = sys.argv[2] if len(sys.argv) > 2 else "/home/claude/cast_optimise_report.pdf"
    with open(data_path) as f:
        data = json.load(f)
    generate(data, output_path)
