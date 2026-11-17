#!/usr/bin/env python3
"""Standard Import JSON for the seed-cluster-repo.sh flow (clusters !22). python3 -I gen.py > spec.json"""
import json
shapes, lines = [], []
LX, CX, RX = 40, 440, 900           # left inputs, centre flow, right exits/outputs
LW, CW, RW = 300, 340, 320
def t(title, body="", fs=13):
    b = f'<br><span style="font-size:{fs}px">{body}</span>' if body else ""
    return f'<p style="font-size:15px;text-align:center"><b>{title}</b>{b}</p>'
def box(i, typ, x, y, w, h, text, fill):
    shapes.append({"id": i, "type": typ, "boundingBox": {"x": x, "y": y, "w": w, "h": h}, "text": text,
                   "style": {"fill": {"type": "color", "color": fill}, "stroke": {"color": "#3A414A", "width": 1, "style": "solid"}}})
def line(i, a, pa, b, pb, label=None, lt="straight", pos=0.5, side="top"):
    l = {"id": i, "lineType": lt,
         "endpoint1": {"type": "shapeEndpoint", "style": "none", "shapeId": a, "position": {"x": pa[0], "y": pa[1]}},
         "endpoint2": {"type": "shapeEndpoint", "style": "arrow", "shapeId": b, "position": {"x": pb[0], "y": pb[1]}},
         "stroke": {"color": "#3A414A", "width": 2, "style": "solid"}}
    if label: l["text"] = [{"text": f'<span style="font-size:13px">{label}</span>', "position": pos, "side": side}]
    lines.append(l)
STEP, DEC, STOP, IN, OUT, END = "#DCEBFF", "#FFF2CC", "#F8D7DA", "#F2F3F5", "#DFF5E1", "#D5E8D4"
B, T, L, R = (0.5, 1), (0.5, 0), (0, 0.5), (1, 0.5)
shapes.append({"id": "title", "type": "text", "boundingBox": {"x": 40, "y": 20, "w": 1180, "h": 70},
               "text": '<p style="font-size:24px;text-align:left"><b>seed-cluster-repo.sh: one command builds or refreshes the GitOps repo of a self-hosted Argo CD cluster</b><br><span style="font-size:14px">clusters template !22, folder self-hosted/. Blue = script step, yellow = decision, grey = input, green = result in the repo, red = stop.</span></p>'})
y = 130
box("start", "terminator", CX, y, CW, 80, t("seed-cluster-repo.sh --cluster NAME", "account and region from the AWS session"), END)
y1 = 280
box("s1", "process", CX, y1, CW, 110, t("1. Clone the cluster repo", "branch seed/&lt;time&gt;; a new repo gets main<br>through one README commit"), STEP)
box("in1", "database", LX, y1, LW, 110, t("CodeCommit NAME-argocd", "created by Terraform module<br>eis-self-argocd"), IN)
y2 = 460
box("s2", "process", CX, y2, CW, 110, t("2. Repo files from the Copier template", "asks only the sync window; -a reads<br>earlier answers back on a re-run"), STEP)
box("in2", "document", LX, y2, LW, 110, t("self-hosted/repo-template/", "copier.yml: cluster, account, region,<br>sync window (cron, length, zone)"), IN)
box("out2", "document", RX, y2, RW, 110, t("bootstrap/ + scripts/", "AppProject platform with sync window;<br>ApplicationSet, autoSync switch"), OUT)
y3 = 640
box("s3", "process", CX, y3, CW, 110, t("3. Hub components at --ref", "ref resolved as branch, tag, commit id;<br>components/ templates/ copied unchanged"), STEP)
box("in3", "database", LX, y3, LW, 110, t("Hub repo iac/argocd/argocd", "GitLab, or a local clone (--hub)"), IN)
box("out3", "document", RX, y3, RW, 110, t("components/ templates/ .hub-source", "last line of .hub-source = hub commit<br>this repo carries"), OUT)
y4 = 820
box("d4", "decision", CX, y4, CW, 130, t("clusters/NAME exists?"), DEC)
box("s4", "process", RX, y4 + 10, RW, 110, t("4. Generate the cluster folder", "clusters template V2.3.0,<br>argocd_mode self-hosted, ECR registry"), STEP)
y5 = 1020
box("s5", "process", CX, y5, CW, 110, t("5. Render check", "scripts/render.sh: helm template of<br>every enabled component"), STEP)
y6 = 1200
box("d6", "decision", CX, y6, CW, 130, t("Every component renders?"), DEC)
box("x6", "terminator", RX, y6 + 25, RW, 80, t("Stop: nothing committed", "tree left in the work folder"), STOP)
y7 = 1400
box("d7", "decision", CX, y7, CW, 130, t("Any change against main?"), DEC)
box("x7", "terminator", RX, y7 + 25, RW, 80, t("No change, nothing to do", "a plain re-run ends here"), STOP)
y8 = 1600
box("s8", "process", CX, y8, CW, 110, t("6. Commit, push, pull request", "branch seed/&lt;time&gt; into main<br>on CodeCommit"), STEP)
box("note8", "note", LX, y8 - 20, LW, 150, t("Promotion and rollback", "run again on the next stage with --ref =<br>last line of the lower stage .hub-source;<br>rollback = previous --ref"), IN)
y9 = 1780
box("d9", "decision", CX, y9, CW, 130, t("--merge given?"), DEC)
box("s9", "process", RX, y9 + 10, RW, 110, t("Fast-forward merge now", "the script merges the pull request"), STEP)
y10 = 1980
box("s10", "process", CX, y10, CW, 110, t("A person reviews and merges", "merging deploys"), STEP)
y11 = 2160
box("end", "terminator", CX, y11, CW, 100, t("Argo CD syncs main", "inside the sync window; a component with<br>autoSync false waits for a manual sync"), END)
line("L_start_s1", "start", B, "s1", T)
line("L_in1_s1", "in1", R, "s1", L)
line("L_s1_s2", "s1", B, "s2", T)
line("L_in2_s2", "in2", R, "s2", L)
line("L_s2_out2", "s2", R, "out2", L)
line("L_s2_s3", "s2", B, "s3", T)
line("L_in3_s3", "in3", R, "s3", L)
line("L_s3_out3", "s3", R, "out3", L)
line("L_s3_d4", "s3", B, "d4", T)
line("L_d4_s4", "d4", R, "s4", L, "no")
line("L_d4_s5", "d4", B, "s5", T, "yes: left as it is", side="bottom")
line("L_s4_s5", "s4", B, "s5", R, lt="elbow")
line("L_s5_d6", "s5", B, "d6", T)
line("L_d6_x6", "d6", R, "x6", L, "no")
line("L_d6_d7", "d6", B, "d7", T, "yes", side="bottom")
line("L_d7_x7", "d7", R, "x7", L, "no change")
line("L_d7_s8", "d7", B, "s8", T, "changed", side="bottom")
line("L_s8_d9", "s8", B, "d9", T)
line("L_d9_s9", "d9", R, "s9", L, "merge flag")
line("L_d9_s10", "d9", B, "s10", T, "no flag", side="bottom")
line("L_s10_end", "s10", B, "end", T)
line("L_s9_end", "s9", B, "end", R, lt="elbow")
print(json.dumps({"version": 1, "pages": [{"id": "p1", "title": "seed-cluster-repo.sh flow", "shapes": shapes, "lines": lines}]}))
