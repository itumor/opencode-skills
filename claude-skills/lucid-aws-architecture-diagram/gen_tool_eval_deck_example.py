#!/usr/bin/env python3
"""Lucid Standard Import JSON: Ansible controller (Tower alternative) evaluation for EIS.
python3 -I gen_lucid.py > spec.json   |   python3 -I gen_lucid.py --selftest
Source of tool facts: research doc "Open-Source Ansible Tower Alternatives" (2026-11-24), not re-verified here."""
import json
import sys

DI = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/"
K8S = "https://raw.githubusercontent.com/kubernetes/community/master/icons/png/resources/labeled/"
IMG = {
    "ascender": "https://github.com/ctrliq.png?size=200", "awx": DI + "awx.png", "ansible": DI + "ansible.png",
    "semaphore": DI + "semaphore.png", "rundeck": DI + "rundeck.png", "kestra": DI + "kestra.png",
    "airflow": DI + "apache-airflow.png", "jenkins": DI + "jenkins.png", "gitlab": DI + "gitlab.png",
    "argo": "https://raw.githubusercontent.com/cncf/artwork/main/projects/argo/icon/color/argo-icon-color.png",
    "argocd": DI + "argo-cd.png", "oracle": DI + "oracle.png", "vault": DI + "hashicorp-vault.png",
    "keycloak": DI + "keycloak.png", "grafana": DI + "grafana.png", "linux": DI + "linux.png",
    "windows": DI + "windows-11.png", "docker": DI + "docker.png", "user": K8S + "user-128.png", "pod": K8S + "pod-128.png",
}
AWS = {
    "eks": "ArchAmazonElasticKubernetesServiceAWS2024", "rds": "ArchAmazonRDSAWS2024", "ec2": "ArchAmazonEC2AWS2024",
    "ecr": "ArchAmazonElasticContainerRegistryAWS2024", "sm": "ArchAWSSecretsManagerAWS2024",
    "ssm": "ArchAWSSystemsManagerAWS2024", "alb": "ResElasticLoadBalancingApplicationLoadBalancerAWS2024",
    "iam": "ArchAWSIdentityandAccessManagementAWS2024", "s3": "ArchAmazonSimpleStorageServiceAWS2024",
    "idc": "ArchAWSIAMIdentityCenterAWS2024",
}
INK = {"color": "#3A414A", "width": 2, "style": "solid"}
RED = {"color": "#C62828", "width": 2, "style": "dashed"}
NOSTROKE = {"color": "#0000", "width": 0, "style": "solid"}
GREEN, BLUE, GREY, YEL, REDF, WHITE = "#DFF5E1", "#DCEBFF", "#F2F3F5", "#FFF2CC", "#F8D7DA", "#FFFFFF"
ICON, CAPW = 72, 200
pages = []


class Page:
    def __init__(self, n, title):
        self.p, self.shapes, self.lines = f"p{n}", [], []
        pages.append({"id": self.p, "title": title, "shapes": self.shapes, "lines": self.lines})

    def text(self, i, x, y, w, h, html):
        self.shapes.append({"id": f"{self.p}_{i}", "type": "text", "boundingBox": {"x": x, "y": y, "w": w, "h": h}, "text": html})

    def title(self, head, sub):
        self.text("title", 40, 20, 1840, 90,
                  f'<p style="font-size:26px;text-align:left"><b>{head}</b><br><span style="font-size:15px">{sub}</span></p>')

    def zone(self, i, label, x, y, w, h, color="#1565C0"):
        self.shapes.append({"id": f"{self.p}_{i}", "type": "rectangleContainer", "boundingBox": {"x": x, "y": y, "w": w, "h": h},
                            "containerTitle": {"text": label},
                            "style": {"stroke": {"color": color, "width": 2, "style": "dashed"}}})

    def icon(self, i, kind, x, y, name, detail="", size=ICON):
        """Icon + caption below. Returns icon id; caption id is <id>t."""
        sid = f"{self.p}_{i}"
        bb = {"x": x, "y": y, "w": size, "h": size}
        if kind in AWS:
            # text on the AWS shape replaces its long default label and renders under the icon
            self.shapes.append({"id": sid, "type": "namedShape", "className": AWS[kind], "boundingBox": bb,
                                "text": f'<p style="font-size:14px;text-align:center"><b>{name}</b></p>'})
            cap, cy = f'<p style="font-size:12px;text-align:center">{detail}</p>', y + size + 36
        else:
            self.shapes.append({"id": sid, "type": "image", "boundingBox": bb, "image": {"type": "image", "url": IMG[kind]}, "stroke": NOSTROKE})
            cap, cy = f'<p style="font-size:12px;text-align:center"><span style="font-size:14px"><b>{name}</b></span><br>{detail}</p>', y + size + 8
        self.shapes.append({"id": sid + "t", "type": "text", "boundingBox": {"x": x + size // 2 - CAPW // 2, "y": cy, "w": CAPW, "h": 70}, "text": cap})
        return sid

    def down(self, i, upper, lower, label=None, stroke=INK, pos=0.5):
        """Arrow from the caption under `upper` down to the top of `lower`."""
        self.arrow(i, upper + "t", lower, (0.5, 1), (0.5, 0), label, stroke, side="middle", pos=pos)

    def up(self, i, lower, upper, label=None, stroke=INK):
        self.arrow(i, lower, upper + "t", (0.5, 0), (0.5, 1), label, stroke, side="middle")

    def logo(self, i, kind, x, y, size=44):
        self.shapes.append({"id": f"{self.p}_{i}", "type": "image", "boundingBox": {"x": x, "y": y, "w": size, "h": size},
                            "image": {"type": "image", "url": IMG[kind]}, "stroke": NOSTROKE})

    def arrow(self, i, a, b, pa=(1, 0.5), pb=(0, 0.5), label=None, stroke=INK, side="top", pos=0.5):
        l = {"id": f"{self.p}_L{i}", "lineType": "straight",
             "endpoint1": {"type": "shapeEndpoint", "style": "none", "shapeId": a, "position": {"x": pa[0], "y": pa[1]}},
             "endpoint2": {"type": "shapeEndpoint", "style": "arrow", "shapeId": b, "position": {"x": pb[0], "y": pb[1]}}}
        if stroke is not INK:
            l["stroke"] = stroke
        if label:
            l["text"] = [{"text": f'<span style="font-size:12px">{label}</span>', "position": pos, "side": side}]
        self.lines.append(l)

    def box(self, i, x, y, w, h, head, lines, fill, fs=13):
        body = "<br>".join(lines)
        sep = "<br>" if lines else ""
        self.shapes.append({"id": f"{self.p}_{i}", "type": "rectangle", "boundingBox": {"x": x, "y": y, "w": w, "h": h},
                            "text": f'<p style="font-size:{fs}px;text-align:center"><span style="font-size:16px"><b>{head}</b></span>{sep}{body}</p>',
                            "style": {"fill": {"type": "color", "color": fill}}})
        return f"{self.p}_{i}"

    def table(self, i, x, y, w, h, rows, fill_fn):
        cells = [{"xPosition": cx, "yPosition": cy, "text": v, "style": {"fill": {"type": "color", "color": fill_fn(cx, cy, v)}}}
                 for cy, r in enumerate(rows) for cx, v in enumerate(r)]
        self.shapes.append({"id": f"{self.p}_{i}", "type": "table", "boundingBox": {"x": x, "y": y, "w": w, "h": h},
                            "rowCount": len(rows), "colCount": len(rows[0]), "cells": cells})


def cell_fill(v):
    """Colour a matrix cell from its wording. Order matters: 'Free; export paid' is amber, not red."""
    s = v.lower()
    if any(k in s for k in ("basic", "workaround", "plugin", "via ", "add-on", "unverified", "partial", "frozen", "fixed")):
        return YEL
    if s.startswith(("paid", "none", "no", "fail")):
        return REDF
    return GREEN


SRC = "Source: research doc 2026-11-24 (free / community editions only). Vendor facts not re-verified by us."

# ------------------------------------------------------------ page 2: landscape
p = Page(2, "2 Candidates landscape")
p.title("Candidates: 18 projects, 4 classes, 3 pass the enterprise gates",
        "Gate = free edition must give SSO + group mapping, RBAC, audit, external secrets, isolation, HA and security patches. " + SRC)
classes = [
    ("Ansible controllers (Tower-like)", [("ascender", "CIQ Ascender OSS", "AWX fork, monthly CVE fixes", GREEN, "PASS"),
                                          ("awx", "AWX 24.6.1", "frozen Jul 2024, 45 open CVEs", REDF, "OUT"),
                                          ("semaphore", "Semaphore UI CE", "SSO, Vault, HA are paid", REDF, "OUT"),
                                          ("oracle", "Oracle OLAM", "AWX rebuild, VM/RPM only", YEL, "VM only")]),
    ("Workflow / runbook engines", [("argo", "Argo Workflows + Events", "CNCF, pod per step, no inventory UI", GREEN, "PASS"),
                                    ("airflow", "Apache Airflow 3", "ASF, Python DAGs", GREEN, "PASS"),
                                    ("rundeck", "Rundeck CE", "HA and Git are paid", REDF, "OUT"),
                                    ("kestra", "Kestra OSS", "one shared login, no RBAC", REDF, "OUT")]),
    ("CI/CD we already know", [("gitlab", "GitLab CE / Free", "runs Ansible in CI, group sync paid", YEL, "what we use"),
                               ("jenkins", "Jenkins OSS", "no controller HA, plugin CVEs", REDF, "OUT")]),
    ("Companions (not controllers)", [("ansible", "ansible-navigator + ARA", "CLI in EE + run history UI", BLUE, "add-on"),
                                      ("keycloak", "Keycloak / Dex", "SAML or AD to OIDC broker", BLUE, "add-on")]),
]
for c, (cname, items) in enumerate(classes):
    x = 60 + c * 465
    p.text(f"h{c}", x, 140, 425, 40, f'<p style="font-size:18px;text-align:center"><b>{cname}</b></p>')
    for r, (ic, name, why, fill, verdict) in enumerate(items):
        y = 200 + r * 170
        p.box(f"c{c}r{r}", x, y, 425, 130, name, [why, f"<b>{verdict}</b>"], fill)
        p.logo(f"c{c}r{r}i", ic, x + 12, y + 12)
p.box("leg", 60, 900, 1820, 70, "How to read",
      ["green = passes all gates at zero licence cost | amber = works with a limit | red = a must-have is paid, missing or unpatched | blue = companion tool"], GREY)

# ------------------------------------------------------------ page 3: capability matrix
p = Page(3, "3 Capability matrix")
p.title("Capability matrix: what the FREE edition really gives", "Green = built in and free. Amber = add-on, plugin or workaround. Red = paid, missing or unpatched. " + SRC)
cols = ["Capability", "Ascender OSS", "AWX 24.6.1", "Semaphore CE", "Rundeck CE", "Kestra OSS", "Argo Workflows", "Airflow 3", "GitLab CE", "Jenkins OSS"]
matrix = [
    ["OIDC login", "Free", "Free", "Paid (Pro)", "Unverified", "Paid", "Free", "Free", "Free", "Plugin"],
    ["SAML 2.0 login", "Free", "Free", "None", "Unverified", "Paid", "Via Keycloak/Dex", "Via Keycloak", "Free", "Plugin"],
    ["LDAP / AD", "Free", "Free", "Paid (Pro)", "Free", "Paid", "Via Keycloak/Dex", "Free", "Free", "Plugin"],
    ["IdP group to role", "Free", "Free", "Paid (Ent)", "Free (file ACL)", "Paid", "Free", "Free", "Paid (Premium)", "Plugin"],
    ["Granular RBAC", "Free", "Free", "Basic", "Free (file ACL)", "Paid", "Free (K8s RBAC)", "Free", "Fixed roles", "Plugin"],
    ["Audit log", "Free", "Free", "Basic, export paid", "Basic", "Paid", "Add-on (K8s audit, Loki)", "Free", "Basic", "Plugin"],
    ["Vault / AWS SM / CyberArk", "Free", "Free", "Paid", "Unverified", "Paid", "Add-on (ESO)", "Free", "Workaround", "Plugin"],
    ["Job isolation (container)", "Free (EE pods)", "Free (EE pods)", "Paid", "Workaround", "Free", "Free (pods)", "Free (pods)", "Free (K8s runner)", "Plugin (K8s agent)"],
    ["High availability", "Free", "Free", "Paid (Ent)", "Paid", "Paid", "Free", "Free", "Free", "Paid (CloudBees)"],
    ["Inventory (dynamic, AWS)", "Free", "Free", "Free", "Free", "Workaround", "Workaround", "Workaround", "Workaround", "Workaround"],
    ["Approval step", "Free", "Free", "None", "Paid", "Free", "Free (suspend)", "Workaround", "Paid", "Free (input)"],
    ["Surveys + per-host results", "Free", "Free", "Free", "Free", "Partial", "Add-on (ARA)", "Add-on (ARA)", "Add-on (ARA)", "Add-on (ARA)"],
    ["Kubernetes install", "Operator", "Frozen operator", "Helm", "Workaround (community Helm)", "Helm", "CRDs + Helm", "Helm", "Helm", "Helm"],
    ["Security patches", "Monthly", "No: 45 open CVEs", "Yes", "Yes", "Yes", "Yes (CNCF)", "Yes (ASF)", "Yes", "Yes"],
    ["Score /100 (research)", "89.2", "68.8", "50.0", "58.8", "45.0", "80.8", "78.0", "67.5", "65.0"],
    ["Gate verdict", "PASS", "FAIL: unpatched", "FAIL: SSO, HA paid", "FAIL: HA paid", "FAIL: no RBAC", "PASS", "PASS", "FAIL: group sync paid", "FAIL: no HA"],
]


def mfill(cx, cy, v):
    if cy == 0:
        return "#CFD8DC"
    if cx == 0:
        return GREY
    if cy == len(matrix) - 1:  # score row: colour by the verdict below it
        return cell_fill(matrix[-1][cx])
    return cell_fill(v)


p.table("matrix", 60, 140, 1820, 860, [cols] + matrix, mfill)

# ------------------------------------------------------------ page 4: scoring
p = Page(4, "4 Weighted score")
p.title("Weighted score (research model) and gate verdict",
        "Weights: security 20, identity 20, HA 15, Ansible parity 15, licence 10, project health 10, Kubernetes 5, ops simplicity 5. " + SRC)
scores = [("ascender", "CIQ Ascender OSS", 89.2, GREEN, "PASS"), ("argo", "Argo Workflows + Events", 80.75, GREEN, "PASS, low Ansible parity (4/10)"),
          ("airflow", "Apache Airflow 3", 78.0, GREEN, "PASS, Python DAG overhead"), ("oracle", "Oracle OLAM", 77.0, YEL, "VM/RPM only, not EKS"),
          ("awx", "AWX 24.6.1 (frozen)", 68.75, REDF, "OUT: 45 unpatched CVEs"), ("gitlab", "GitLab CE / Free", 67.5, REDF, "OUT: group sync is Premium"),
          ("jenkins", "Jenkins OSS", 65.0, REDF, "OUT: no controller HA"), ("rundeck", "Rundeck CE", 58.75, REDF, "OUT: HA, Git paid"),
          ("semaphore", "Semaphore UI CE", 50.0, REDF, "OUT: SSO, Vault, HA paid"), ("kestra", "Kestra OSS", 45.0, REDF, "OUT: one shared login")]
for n, (ic, name, sc, fill, note) in enumerate(scores):
    y = 150 + n * 80
    p.logo(f"s{n}i", ic, 60, y + 3)
    p.text(f"s{n}n", 120, y, 300, 50, f'<p style="font-size:15px;text-align:left"><b>{name}</b></p>')
    p.shapes.append({"id": f"p4_s{n}b", "type": "rectangle", "boundingBox": {"x": 430, "y": y, "w": int(sc * 10), "h": 50},
                     "text": f'<p style="font-size:15px;text-align:center"><b>{sc:g}</b></p>', "style": {"fill": {"type": "color", "color": fill}}})
    p.text(f"s{n}v", 1440, y, 440, 50, f'<p style="font-size:14px;text-align:left">{note}</p>')


# ------------------------------------------------------------ page 1: how we run Ansible today
EIS = "Source: our repos (projects/aws/*/ansible, ansible/template, ansible/roles), read 2026-11-24."
p = Page(1, "1 Ansible at EIS today")
p.title("How we run Ansible today: one engineer, one laptop, personal credentials",
        "5 client repos from one Copier template. No controller, no CI run, no schedule, no central log. " + EIS)
p.zone("lap", "Engineer laptop (VPN)", 60, 200, 700, 300)
p.zone("shared", "Shared services", 60, 620, 700, 300, "#6A1B9A")
p.zone("client", "Client AWS account (one SSO profile per client)", 860, 200, 1020, 720, "#2E7D32")
u = p.icon("user", "user", 130, 270, "Engineer", "runs by hand, in waves,<br>--check --diff first")
d = p.icon("run", "docker", 450, 270, "docker/run.sh", "local image ansible-aws:local,<br>not in a registry")
g = p.icon("gl", "gitlab", 110, 690, "GitLab", "roles by git+ssh,<br>pinned by tag")
v = p.icon("vault", "vault", 340, 690, "Vault", "personal token in .env,<br>expires mid-run")
s = p.icon("idc", "idc", 570, 690, "Identity Center", "SSO profile on laptop,<br>token expiry = 0 hosts")
m = p.icon("ssm", "ssm", 960, 270, "SSM", "aws_ssm plugin,<br>no SSH, no bastion")
e = p.icon("ec2", "ec2", 1300, 270, "EC2 RHEL hosts", "docker-compose apps,<br>CAA = 12 hosts")
b = p.icon("s3", "s3", 960, 600, "S3 bucket", "SSM file transfer")
p.arrow("1", u, d)
p.arrow("2", d, m, label="aws_ssm")
p.arrow("3", m, e)
p.down("4", d, g, "roles", pos=0.75)
p.down("5", d, v, "secrets", pos=0.75)
p.down("6", d, s, "SSO", pos=0.75)
p.down("7", m, b)
p.box("repos", 1560, 250, 280, 190, "5 client repos",
      ["credit-agricole (reference)", "axa-japan (template v1.4.0)", "nnl-japan (template v1.2.0)", "pto-reference (hand-made)", "anlab (empty)"], BLUE, 12)
p.box("plays", 1560, 500, 280, 190, "Playbooks",
      ["atlantis, jenkins, gitlab, sonar,", "nexus, opengrok, keycloak, sisense,", "kernel patch, cert update,", "vault agent, join domain"], BLUE, 12)
pains = [("Laptop only", ["no CI job runs a playbook;", "macOS needs the Docker wrapper"]),
         ("Personal credentials", ["Vault token + SSO + GitLab SSH", "for every operator"]),
         ("No audit trail", ["no central job log;", "evidence is notes and Jira"]),
         ("No roles", ["cannot give run-only or", "one-client-only access"]),
         ("No schedule, no approval", ["window approval is Slack or Jira,", "outside the tool"]),
         ("Version drift", ["clients on different template", "and role versions"])]
for n, (h, l) in enumerate(pains):
    p.box(f"pain{n}", 60 + n * 305, 1010, 285, 110, h, l, REDF, 12)

# ------------------------------------------------------------ page 5: proposed target
p = Page(5, "5 Proposed target on EKS")
p.title("Proposed target: Ascender OSS on our EKS hub (design only, nothing deployed)",
        "Same playbooks, roles and SSM path. The run moves from the laptop to a pod, with SSO, roles, schedules, approval and job history.")
p.shapes.append({"id": "p5_hub", "type": "rectangleContainer", "boundingBox": {"x": 330, "y": 330, "w": 900, "h": 640},
                 "style": {"stroke": {"color": "#1565C0", "width": 2, "style": "dashed"}}})
p.text("hubt", 350, 340, 500, 30, '<p style="font-size:15px;text-align:left"><b>EKS hub cluster (proposed home, to confirm)</b></p>')
p.zone("client", "Client AWS accounts (CAA, AXA Japan, NNL Japan, PTO)", 1300, 330, 580, 640, "#2E7D32")
g = p.icon("gl", "gitlab", 640, 130, "GitLab", "playbooks + roles,<br>project sync")
v = p.icon("vault", "vault", 900, 130, "Vault", "service login,<br>no personal token")
u = p.icon("user", "user", 80, 420, "Engineer / approver", "browser, VPN")
i = p.icon("idc", "idc", 80, 700, "SSO", "CyberArk Identity or IdC,<br>AD groups to roles")
a = p.icon("alb", "alb", 400, 420, "Internal ALB", "TLS, VPN only")
c = p.icon("asc", "ascender", 640, 420, "Ascender web + task", "inventory, templates,<br>schedules, approvals, RBAC")
x = p.icon("pod", "pod", 900, 420, "Job pod (EE image)", "ansible + aws_ssm<br>+ hashi_vault")
ar = p.icon("argo", "argocd", 400, 720, "Argo CD", "deploys the operator<br>(playground first)")
r = p.icon("rds", "rds", 640, 720, "PostgreSQL", "job history, config")
ec = p.icon("ecr", "ecr", 900, 720, "ECR", "EE image, built in CI")
m = p.icon("ssm", "ssm", 1380, 420, "SSM", "same path as today")
e = p.icon("ec2", "ec2", 1680, 420, "EC2 RHEL hosts", "no agent change")
ro = p.icon("iam", "iam", 1380, 720, "IAM role per client", "pod identity + assume role<br>(new, by Terraform)")
p.arrow("1", u, a)
p.arrow("2", a, c)
p.arrow("3", c, x, label="start job")
p.arrow("4", x, m, label="aws_ssm")
p.arrow("5", m, e)
p.down("6", g, c)
p.down("7", v, x)
p.down("8", c, r)
p.up("9", ec, x, "pull")
p.up("10", ro, m, "short-lived")
p.up("11", i, u, "login")
p.box("chg", 60, 1060, 590, 170, "What changes",
      ["runs start from a pod, not a laptop", "SSO login, roles per client and per job", "per-host job history kept in one place", "schedules and an approval step in the tool"], GREEN)
p.box("stay", 680, 1060, 590, 170, "What stays",
      ["same playbooks, roles and Copier template", "SSM only: no SSH, no bastion", "same Vault secret paths", "GitLab stays the source of truth"], BLUE)
p.box("build", 1300, 1060, 580, 170, "What we must build",
      ["EE image in ECR from today's docker image", "IAM role per client account (Terraform MRs)", "Vault service login for the controller", "PostgreSQL + pods = needs cost approval"], YEL)

# ------------------------------------------------------------ page 6: EIS fit + recommendation
p = Page(6, "6 EIS fit and recommendation")
p.title("Which one fits EIS: our needs against four realistic options",
        "Our lens, draft for team discussion: small RHEL fleet, SSM only, Vault, GitLab, EKS + Argo CD, no Tower to migrate. Effort = our estimate, not measured.")
fit_cols = ["What we need", "Ascender OSS on EKS", "GitLab CI + ARA", "Argo Workflows + ARA", "Semaphore CE", "Stay on laptop"]
fit = [
    ["Run off the laptop", "Yes", "Yes", "Yes", "Yes", "No"],
    ["SSO + AD group to role", "Free, built in", "Partial (group sync paid)", "Via Dex/Keycloak", "Paid", "No"],
    ["Role: run-only, per client", "Free", "Partial (project roles)", "Free (K8s RBAC)", "Basic", "No"],
    ["SSM connection (custom image)", "Yes (EE image)", "Yes (CI image)", "Yes (EE image)", "Partial (isolation paid)", "Yes"],
    ["Vault without personal token", "Yes (Vault credential)", "Workaround (job login)", "Add-on (ESO)", "Paid", "No"],
    ["Many client AWS accounts", "Yes (role per client)", "Yes (role per client)", "Yes (role per client)", "Partial", "Yes (SSO profiles)"],
    ["Schedules", "Free", "Free", "Free", "Free", "No"],
    ["Approval before a prod run", "Free", "Workaround (manual job)", "Free (suspend)", "None", "No (Slack, Jira)"],
    ["Job history per host", "Free", "Add-on (ARA)", "Add-on (ARA)", "Basic", "No"],
    ["Self-service launch form", "Free (surveys)", "Basic (variables)", "Basic (parameters)", "Free", "No"],
    ["New things to own", "Pods + PostgreSQL", "ARA only", "Controller + Dex + ARA", "Pod + database", "Nothing"],
    ["Effort to first real run", "Medium", "Low", "High", "Low", "None"],
    ["Verdict for EIS", "Recommended", "Quick win, do first", "Fallback", "Fail: SSO and Vault paid", "Not sustainable"],
]


def ffill(cx, cy, v):
    if cy == 0:
        return "#CFD8DC"
    if cx == 0:
        return GREY
    if v in ("Medium", "Fallback", "Quick win, do first", "Pods + PostgreSQL", "Controller + Dex + ARA", "Pod + database"):
        return YEL
    if v in ("High", "Not sustainable"):
        return REDF
    return cell_fill(v)


p.table("fit", 60, 140, 1820, 640, [fit_cols] + fit, ffill)
for n, ic in enumerate(["ascender", "gitlab", "argo", "semaphore", "user"]):
    p.logo(f"fl{n}", ic, 60 + 1820 // 6 * (n + 1) + 130, 92, 40)
r1 = p.box("rec", 60, 840, 580, 200, "Recommendation",
           ["Controller: CIQ Ascender OSS on EKS.", "Only free option with SSO, roles, Vault, approvals", "and per-host history built in. Top score in research (89).", "Risk: one vendor (CIQ). Exit: Argo Workflows."], GREEN)
r2 = p.box("now", 680, 840, 580, 200, "Do now, whatever we pick",
           ["Add GitLab CI to the Ansible template:", "lint + --check on merge request.", "Publish the ansible image to ECR.", "Both are reused by any controller."], BLUE)
r3 = p.box("poc", 1300, 840, 580, 200, "POC (2 weeks, one client)",
           ["Ascender on a dev cluster via Argo CD", "SSO login + one AD group mapped to a role", "CAA kernel-patch playbook in --check over SSM", "Vault service login, one approval step, one schedule"], YEL)
p.arrow("1", r2, r3)
qs = ["Open: is a controller worth it for a fleet this size, or is GitLab CI + ARA enough?",
      "Open: SSO through CyberArk Identity or Identity Center? Who owns the app registration?",
      "Open: which cluster hosts it, and PostgreSQL on RDS or in-cluster? Cost approval needed before apply.",
      "Open: is single-vendor open source (CIQ) acceptable to security and to mzivarts?"]
for n, q in enumerate(qs):
    p.box(f"q{n}", 60 + (n % 2) * 920, 1100 + (n // 2) * 90, 900, 70, q, [], GREY, 13)

pages.sort(key=lambda pg: pg["id"])


def emit():
    return json.dumps({"version": 1, "pages": pages}, separators=(",", ":"))


def selftest():
    ids = [s["id"] for pg in pages for s in pg["shapes"]] + [l["id"] for pg in pages for l in pg["lines"]]
    assert len(ids) == len(set(ids)), "duplicate ids"
    for pg in pages:
        sid = {s["id"] for s in pg["shapes"]}
        for l in pg["lines"]:
            assert l["endpoint1"]["shapeId"] in sid and l["endpoint2"]["shapeId"] in sid, l["id"]
    assert all(len(r) == len(cols) for r in matrix), "ragged matrix"
    assert cell_fill("Basic, export paid") == YEL and cell_fill("Paid (Pro)") == REDF and cell_fill("Free") == GREEN
    assert "REDACT" not in emit()
    print("selftest ok:", len(pages), "pages,", len(ids), "items,", len(emit()), "bytes")


if __name__ == "__main__":
    selftest() if "--selftest" in sys.argv else print(emit())
