#!/usr/bin/env python3
"""Lucid Standard Import: COINT-21594 POC-D, 3 methods that pass every chart case (E1, E2, E4). python3 -I gen.py > spec.json"""
import json

K8 = "https://raw.githubusercontent.com/kubernetes/community/master/icons/png/resources/labeled/"
CN = "https://raw.githubusercontent.com/cncf/artwork/main/projects/"
LOGO = {"argo": CN + "argo/icon/color/argo-icon-color.png", "helm": CN + "helm/icon/color/helm-icon-color.png",
        "eso": "https://raw.githubusercontent.com/external-secrets/external-secrets/main/assets/eso-logo-large.png",
        "gitlab": "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/gitlab.png",
        "secret": K8 + "secret-128.png", "cronjob": K8 + "cronjob-128.png", "pod": K8 + "pod-128.png", "sa": K8 + "sa-128.png"}
AWS = {"role": "ResAWSIdentityAccessManagementRoleAWS2024", "ecr": "ArchAmazonElasticContainerRegistryAWS2024",
       "reg": "ResAmazonElasticContainerRegistryRegistryAWS2024", "img": "ResAmazonElasticContainerRegistryImageAWS2024",
       "eks": "ArchAmazonElasticKubernetesServiceAWS2024", "ec2": "ArchAmazonEC2AWS2024"}
BLUE, GREY, ORANGE, GREEN, RED, PURPLE = "#2D6CDF", "#6B7280", "#ED7100", "#1A7F37", "#C62828", "#8C4FFF"
NS = {"fill": {"type": "color", "color": "#EEF4FF"}, "stroke": {"color": "#326CE5", "width": 2, "style": "solid"}}
POD = {"fill": {"type": "color", "color": "#FFFFFF"}, "stroke": {"color": "#326CE5", "width": 2, "style": "dashed"}}
NOSTROKE = {"color": "#00000000", "width": 0, "style": "solid"}
ICON = 88


def t(text, px=14, bold=False, align="center"):
    inner = "<b>%s</b>" % text if bold else text
    return '<p style="font-size:%dpx;text-align:%s">%s</p>' % (px, align, inner)


class Page:
    def __init__(self, pid, title):
        self.pid, self.title, self.shapes, self.lines = pid, title, [], []

    def id(self, s): return "%s_%s" % (self.pid, s)

    def heading(self, text, sub, w=1800):
        self.shapes.append({"id": self.id("h1"), "type": "text", "boundingBox": {"x": 40, "y": 10, "w": w, "h": 44}, "text": t(text, 26, True, "left")})
        self.shapes.append({"id": self.id("h2"), "type": "text", "boundingBox": {"x": 40, "y": 56, "w": w, "h": 50}, "text": t(sub, 15, False, "left")})

    def aws_zone(self, i, cls, x, y, w, h, text):
        self.shapes.append({"id": self.id(i), "type": "namedContainer", "className": cls,
                            "boundingBox": {"x": x, "y": y, "w": w, "h": h}, "text": t(text, 15, True, "left")})

    def zone(self, i, x, y, w, h, title, style=NS):
        self.shapes.append({"id": self.id(i), "type": "rectangleContainer", "boundingBox": {"x": x, "y": y, "w": w, "h": h},
                            "containerTitle": {"text": title}, "style": style})

    def node(self, i, kind, key, x, y, title, detail=None, wide=260):
        if kind == "aws":
            self.shapes.append({"id": self.id(i), "type": "namedShape", "className": AWS[key],
                                "boundingBox": {"x": x, "y": y, "w": ICON, "h": ICON}, "text": " "})
        else:
            self.shapes.append({"id": self.id(i), "type": "image", "boundingBox": {"x": x, "y": y, "w": ICON, "h": ICON},
                                "image": {"type": "image", "url": LOGO[key]}, "stroke": NOSTROKE})
        cx = x + ICON // 2
        body = '<span style="font-size:15px"><b>%s</b></span>' % title + ("<br>" + detail if detail else "")
        self.shapes.append({"id": self.id(i + "t"), "type": "text",
                            "boundingBox": {"x": cx - wide // 2, "y": y + ICON + 6, "w": wide, "h": 70 if detail else 28},
                            "text": '<p style="font-size:12px;text-align:center">%s</p>' % body})

    def box(self, i, x, y, w, h, title, body, color=BLUE, fill="#FFFFFF"):
        txt = '<p style="font-size:13px;text-align:left"><span style="font-size:16px"><b>%s</b></span><br>%s</p>' % (title, body)
        self.shapes.append({"id": self.id(i), "type": "rectangle", "boundingBox": {"x": x, "y": y, "w": w, "h": h}, "text": txt,
                            "style": {"fill": {"type": "color", "color": fill}, "stroke": {"color": color, "width": 2, "style": "solid"}}})

    def line(self, i, a, b, pa, pb, color=BLUE, label=None, lpos=0.5, side="top", dashed=False):
        l = {"id": self.id("L" + i), "lineType": "straight",
             "endpoint1": {"type": "shapeEndpoint", "style": "none", "shapeId": self.id(a), "position": {"x": pa[0], "y": pa[1]}},
             "endpoint2": {"type": "shapeEndpoint", "style": "arrow", "shapeId": self.id(b), "position": {"x": pb[0], "y": pb[1]}},
             "stroke": {"color": color, "width": 2, "style": "dashed" if dashed else "solid"}}
        if label:
            l["text"] = [{"text": '<span style="font-size:12px">%s</span>' % label, "position": lpos, "side": side}]
        self.lines.append(l)

    def out(self):
        return {"id": self.pid, "title": self.title, "shapes": self.shapes, "lines": self.lines}


R, L, T, B = (1, 0.5), (0, 0.5), (0.5, 0), (0.5, 1)
LEGEND = "Blue = chart pull, orange = token fetch / write, green = IAM identity. Cluster pref-dev aws0prefdeveks01, PTO-Reference 468381823127 us-west-2, Argo CD v3.5.5 (chart 10.10.5)."

# ───────────── Page 1: comparison + recommendation ─────────────
p = Page("p1", "1 Comparison and recommendation")
p.heading("Self-hosted Argo CD + Amazon ECR: the 3 methods that pass every chart case",
          "COINT-21594 POC-D on pto-ref (pref-dev). Cases: (a) ECR chart as dependency of a git wrapper, (b) Argo CD Helm source in ECR, (c) Argo CD 3.x OCI source, C4 ECR chart + values file from git (multi-source). Tested 2026-10-23 to 2026-10-26.")
rows = [
    ["Method", "(a)", "(b)", "(c)", "C4", "What is stored", "Moving parts / own code", "Failure proven", "Verdict"],
    ["E1 ESO ECRAuthorizationToken generator -> repo-creds Secret", "PASS", "PASS", "PASS", "PASS",
     "12 h ECR token in a Secret, refreshed every 6 h", "External Secrets Operator (already a platform add-on); no own code", "D3 12 h expiry: token rotated, apps stay Synced", "RECOMMENDED"],
    ["E2 CronJob refresher (aws ecr get-login-password) -> Secret", "PASS", "PASS", "PASS", "PASS",
     "12 h ECR token in a Secret, CronJob every 6 h", "CronJob + small shell script + Secret-write RBAC", "D5 CronJob stopped: 403 token expired after 12 h; recovers on resume", "Plan B"],
    ["E4 Loopback auth proxy sidecar (127.0.0.1:8098)", "PASS*", "PASS", "PASS", "PASS",
     "Nothing (token only in sidecar memory)", "Sidecar in repo-server + our proxy code; plain HTTP inside the pod", "D3: proxy refreshes token 1 h before expiry", "Not recommended"],
]
cells = []
fills = {0: "#E5E7EB"}
for y, row in enumerate(rows):
    for x, v in enumerate(row):
        c = {"xPosition": x, "yPosition": y, "text": v}
        if y == 0:
            c["style"] = {"fill": {"type": "color", "color": "#E5E7EB"}}
        elif x == 8:
            c["style"] = {"fill": {"type": "color", "color": {"RECOMMENDED": "#E3F4E1", "Plan B": "#FFF4E0"}.get(v, "#FDE8E8")}}
        elif 1 <= x <= 4:
            c["style"] = {"fill": {"type": "color", "color": "#E3F4E1"}}
        cells.append(c)
p.shapes.append({"id": p.id("tbl"), "type": "table", "boundingBox": {"x": 40, "y": 140, "w": 1900, "h": 520},
                 "rowCount": 4, "colCount": 9, "cells": cells})
p.box("rec", 40, 720, 1100, 230, "Recommendation: E1 (ESO ECRAuthorizationToken generator)",
      "Uses an add-on we already run, no code of our own, no sidecar, no long-lived secret (IRSA role; the 12 h ECR token is re-minted every 6 h). "
      "Works for all chart shapes, including the OCI source type (one extra Secret with type oci). Least privilege per repo through the IRSA role policy. "
      "E2 is plan B (same result, but our script and Secret-write RBAC). E4 works but adds a sidecar and plain HTTP, so we do not recommend it.",
      GREEN, "#E3F4E1")
p.box("img", 1200, 720, 740, 230, "Docker images: separate path, works with every method",
      "Pods pull images with the node IAM role (kubelet), not through Argo CD. I1 same-account ECR image PASS (AmazonEC2ContainerRegistryReadOnly). "
      "I4 ECR Public pull-through cache PASS after AmazonEC2ContainerRegistryPullOnly on node roles (pto-reference !66). See page 5.",
      BLUE, "#EEF4FF")
p.box("note", 40, 1000, 1900, 120, "Notes",
      "* E4 case (a) needs helm dependency build with --plain-http and the dependency repository oci://127.0.0.1:8098. "
      "Not possible for charts: E5 native Argo CD ECR auth (upstream #26973 open), E6 static credential (ECR token max 12 h), E7b pull-through cache (images only). "
      "E3 Docker credential helper fails case (c); E8 CMP sidecar works for (a) only.", GREY, "#F9FAFB")
pages = [p.out()]


def method_page(pid, title, head, sub, actor, actor_detail, actor_icon, secret_detail, results):
    q = Page(pid, title)
    q.heading(head, sub)
    q.aws_zone("acct", "AWSCloudAWS2024", 40, 130, 1860, 620, "PTO-Reference account 468381823127, us-west-2")
    q.zone("eks", 80, 220, 1160, 500, "EKS aws0prefdeveks01, namespace argocd-poc-a")
    q.node("role", "aws", "role", 1340, 260, "IAM role (IRSA)", actor_detail[1], wide=300)
    q.node("ecr", "aws", "ecr", 1720, 260, "ECR API", "GetAuthorizationToken<br>token valid 12 h", wide=200)
    q.node("act", "img", actor_icon, 900, 260, actor, actor_detail[0], wide=280)
    q.node("sec", "img", "secret", 440, 260, "repo-creds Secret", secret_detail, wide=280)
    q.node("rs", "img", "argo", 440, 520, "Argo CD repo-server", "helm pull / dependency build /<br>OCI source, user AWS + token", wide=300)
    q.node("reg", "aws", "reg", 1720, 520, "ECR repository", "poc-d/&lt;method&gt;/poc-d-hello<br>Helm chart 0.1.0 (OCI)", wide=220)
    q.line("a1", "role", "act", L, R, GREEN, "AssumeRoleWithWebIdentity", lpos=0.5, side="top")
    q.line("a2", "role", "ecr", R, L, ORANGE, "get token", lpos=0.5, side="top")
    q.line("a3", "act", "sec", L, R, ORANGE, "write token", lpos=0.5, side="bottom")
    q.line("a4", "sect", "rs", B, T, BLUE, "read creds", lpos=0.4, side="top")
    q.line("a5", "rs", "reg", R, L, BLUE, "pull chart over HTTPS (basic auth AWS:token)", lpos=0.5, side="top")
    x = 40
    for n, (ttl, body, col, fill) in enumerate(results):
        q.box("r%d" % n, x, 810, 450, 300, ttl, body, col, fill)
        x += 470
    return q.out()


pages.append(method_page(
    "p2", "2 E1 ESO generator (recommended)",
    "E1: External Secrets Operator ECRAuthorizationToken generator (RECOMMENDED)",
    "ESO uses its own IRSA role to mint the ECR token and writes it into Argo CD repo-creds Secrets (one helm type, one oci type). Argo CD only reads a normal Secret. " + LEGEND,
    "External Secrets Operator", ("ExternalSecret + generator<br>refreshInterval 6h", "argocd-poc-d-e1-Role<br>GetAuthorizationToken + pull on 1 repo"), "eso",
    "poc-d-e1-repo-creds (helm)<br>poc-d-e1-oci-creds (oci)",
    [("Result on pref-dev", "Cases a, b, c and C4 PASS. D3 (12 h expiry soak): ESO refreshed at 10:28Z, 16:28Z, 22:28Z, password changed, apps stayed Synced. Token outlives the 1 h role session.", GREEN, "#E3F4E1"),
     ("Pros", "No code of ours. ESO already runs on every cluster. Standard Argo CD repo-creds Secret. IRSA role scoped to the chart repos. Rotation is declarative (refreshInterval).", BLUE, "#FFFFFF"),
     ("Cons", "A usable 12 h token sits in a Secret in the argocd namespace. Needs a second Secret with type oci for OCI sources. Depends on ESO health.", ORANGE, "#FFF4E0"),
     ("Verdict", "RECOMMENDED for upper Argo CD chart pulls from ECR. Upper rollout: IRSA role per cluster, ExternalSecret + generator, alert when the ExternalSecret stops syncing.", GREEN, "#E3F4E1")]))

pages.append(method_page(
    "p3", "3 E2 CronJob refresher",
    "E2: CronJob refresher (aws ecr get-login-password) -> repo-creds Secret (plan B)",
    "A CronJob with its own IRSA role runs the AWS CLI every 6 h and writes the token into the Argo CD repo-creds Secrets through the Kubernetes API. " + LEGEND,
    "CronJob poc-d-e2-refresher", ("schedule 0 */6 * * *<br>+ init Job on install", "argocd-poc-d-e2-Role<br>GetAuthorizationToken + pull on 1 repo"), "cronjob",
    "poc-d-e2-repo-creds (helm)<br>poc-d-e2-oci-creds (oci)",
    [("Result on pref-dev", "Cases a, b, c and C4 PASS. D5: CronJob suspended -> after 12 h ECR answers 403 'authorization token has expired'. Resumed (argocd !558): b/c recover on next reconcile, case a needs a hard refresh.", GREEN, "#E3F4E1"),
     ("Pros", "Common pattern, easy to read. Only the AWS CLI image. Same Secret format as E1.", BLUE, "#FFFFFF"),
     ("Cons", "Our script to maintain. Role needs create/update on Secrets (not name-scopable). A missed run breaks pulls 12 h later. Install order: Secrets before Applications.", ORANGE, "#FFF4E0"),
     ("Verdict", "PLAN B if ESO is not available on a cluster. Needs an alert on CronJob failure.", ORANGE, "#FFF4E0")]))

# ───────────── Page 4: E4 proxy (different shape) ─────────────
q = Page("p4", "4 E4 loopback proxy")
q.heading("E4: loopback auth proxy sidecar in the repo-server pod (not recommended)",
          "Argo CD talks plain HTTP to 127.0.0.1:8098; the sidecar adds the ECR token and forwards over HTTPS. No credential Secret (repository Secret holds only the URL). " + LEGEND)
q.aws_zone("acct", "AWSCloudAWS2024", 40, 130, 1860, 620, "PTO-Reference account 468381823127, us-west-2")
q.zone("eks", 80, 220, 1160, 500, "EKS aws0prefdeveks01, namespace argocd-poc-a")
q.zone("pod", 140, 420, 1040, 260, "Pod argo-cd-poc-a-argocd-repo-server", POD)
q.node("rs", "img", "argo", 260, 480, "repo-server", "repoURL 127.0.0.1:8098/poc-d/e4<br>oci://127.0.0.1:8098 (case a)", wide=300)
q.node("px", "img", "pod", 820, 480, "ecr-proxy sidecar", "our code, token cached in memory<br>refresh 1 h before expiry", wide=300)
q.node("sec", "img", "secret", 260, 250, "repository Secret", "poc-d-e4-repo-helm / -oci<br>URL only, no password", wide=280)
q.node("role", "aws", "role", 1340, 260, "IAM role (IRSA)", "argocd-poc-a-repo-server-Role<br>shared with other sidecars", wide=300)
q.node("ecr", "aws", "ecr", 1720, 260, "ECR API", "GetAuthorizationToken<br>token valid 12 h", wide=200)
q.node("reg", "aws", "reg", 1720, 520, "ECR repository", "poc-d/e4/poc-d-hello<br>Helm chart 0.1.0 (OCI)", wide=220)
q.line("a1", "sect", "rs", B, T, GREY, "URL", lpos=0.5, side="top", dashed=True)
q.line("a2", "rs", "px", R, L, BLUE, "plain HTTP 127.0.0.1:8098", lpos=0.5, side="top")
q.line("a3", "px", "reg", R, L, BLUE, "HTTPS + token", lpos=0.5, side="top")
q.line("a4", "role", "ecr", R, L, ORANGE, "get token", lpos=0.5, side="top")
q.line("a5", "px", "role", T, L, GREEN, "IRSA", lpos=0.3, side="top")
x = 40
for n, (ttl, body, col, fill) in enumerate([
        ("Result on pref-dev", "Cases a, b, c and C4 PASS (C4 rendered from repo-server chart cache). D3: proxy refreshed the token 3 times in 24 h. First sync after a repo-server roll failed once (connection refused) until startupProbe was added.", GREEN, "#E3F4E1"),
        ("Pros", "No credential stored anywhere in Kubernetes. Works for every chart shape.", BLUE, "#FFFFFF"),
        ("Cons", "Our proxy code to own and security-review. Sidecar in every repo-server pod. Plain HTTP inside the pod; case a needs --plain-http and 127.0.0.1 dependency URLs in the chart.", RED, "#FDE8E8"),
        ("Verdict", "NOT RECOMMENDED. Same outcome as E1 with more code and moving parts.", RED, "#FDE8E8")]):
    q.box("r%d" % n, x, 810, 450, 300, ttl, body, col, fill)
    x += 470
pages.append(q.out())

# ───────────── Page 5: images ─────────────
r = Page("p5", "5 Docker images (I1, I4)")
r.heading("Docker images in pods: pulled by the node, not by Argo CD",
          "Same for E1, E2 and E4. Argo CD only renders manifests; kubelet on each node pulls the image with the node group IAM role. Tested 2026-10-26 on pref-dev.")
r.aws_zone("acct", "AWSCloudAWS2024", 40, 130, 1500, 620, "PTO-Reference account 468381823127, us-west-2")
r.zone("eks", 80, 220, 620, 500, "EKS aws0prefdeveks01, namespace poc-a-apps")
r.node("pod1", "img", "pod", 160, 260, "Pod poc-d-i1", "image .../poc-d/img/busybox:1.37", wide=260)
r.node("pod4", "img", "pod", 160, 520, "Pod poc-d-i4", "image .../ecr-public/docker/library/busybox", wide=280)
r.node("node", "aws", "ec2", 520, 390, "Node (kubelet)", "node group IAM role<br>ReadOnly + PullOnly", wide=240)
r.node("ecr1", "aws", "img", 1000, 260, "ECR repo poc-d/img/busybox", "same account (I1)", wide=280)
r.node("ptc", "aws", "ecr", 1000, 520, "ECR pull-through cache", "rule ecr-public, creation template<br>+ creation role (KMS aws/ecr)", wide=300)
r.node("pub", "aws", "reg", 1680, 520, "ECR Public", "public.ecr.aws (anonymous)", wide=240)
r.line("i1", "pod1", "node", R, (0.3, 0), GREY, None, dashed=True)
r.line("i2", "pod4", "node", R, (0.3, 1), GREY, None, dashed=True)
r.line("i3", "node", "ecr1", (1, 0.3), L, BLUE, "I1 pull", lpos=0.5, side="top")
r.line("i4", "node", "ptc", (1, 0.7), L, BLUE, "I4 pull", lpos=0.5, side="bottom")
r.line("i5", "ptc", "pub", R, L, ORANGE, "import upstream on first pull", lpos=0.5, side="top")
r.box("b1", 40, 810, 740, 220, "I1 PASS (same-account ECR image)",
      "Pod poc-d-i1 Running, imageID @sha256:66a6306d... Node role AmazonEC2ContainerRegistryReadOnly is enough (EKS default).", GREEN, "#E3F4E1")
r.box("b2", 820, 810, 1080, 220, "I4 PASS (ECR Public pull-through cache)",
      "First FAIL: ReadOnly lacks ecr:BatchImportUpstreamImage (CloudTrail AccessDenied). Fix pto-reference !66: AmazonEC2ContainerRegistryPullOnly on 4 node roles. "
      "Then CreateRepository by the creation role 06:09:36Z, pod Running 06:11:48Z, digest = upstream. Not tested: cross-account images (I3, dropped).", GREEN, "#E3F4E1")
pages.append(r.out())

print(json.dumps({"version": 1, "pages": pages}))
