#!/usr/bin/env python3
"""Lucid Standard Import for the SonarQube on EKS POC (GENESIS-447522). 3 pages. python3 -I gen_sonarqube_eks_example.py > spec.json
Helpers copied from gen_nexus_eks_example.py."""
import json

DI = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/"
K8 = "https://raw.githubusercontent.com/kubernetes/community/master/icons/png/resources/labeled/"
CN = "https://raw.githubusercontent.com/cncf/artwork/main/projects/"
LOGO = {
    "gitlab": DI + "gitlab.png", "vault": DI + "hashicorp-vault.png", "windows": DI + "microsoft-windows.png",
    "nexus": DI + "nexus.png", "sonar": DI + "sonarqube.png", "postgres": DI + "postgresql.png", "docker": DI + "docker.png", "jenkins": DI + "jenkins.png",
    "argo": CN + "argo/icon/color/argo-icon-color.png", "helm": CN + "helm/icon/color/helm-icon-color.png",
    "istio": CN + "istio/icon/color/istio-icon-color.png", "k8s": CN + "kubernetes/icon/color/kubernetes-icon-color.png",
    "eso": "https://raw.githubusercontent.com/external-secrets/external-secrets/main/assets/eso-logo-large.png",
    "atlantis": "https://raw.githubusercontent.com/runatlantis/atlantis/main/runatlantis.io/public/hero.png",
    "pod": K8 + "pod-128.png", "sts": K8 + "sts-128.png", "pvc": K8 + "pvc-128.png", "secret": K8 + "secret-128.png",
    "job": K8 + "job-128.png", "sa": K8 + "sa-128.png", "svc": K8 + "svc-128.png", "ns": K8 + "ns-128.png", "cm": K8 + "cm-128.png",
}
AWS = {"eks": "ArchAmazonElasticKubernetesServiceAWS2024", "rds": "ResAmazonAuroraPostgreSQLInstanceAWS2024",
       "s3": "ArchAmazonSimpleStorageServiceAWS2024", "sm": "ArchAWSSecretsManagerAWS2024",
       "role": "ResAWSIdentityAccessManagementRoleAWS2024", "alb": "ResElasticLoadBalancingApplicationLoadBalancerAWS2024",
       "r53": "ArchAmazonRoute53AWS2024", "tgw": "ArchAWSTransitGatewayAWS2024", "codestar": "ArchAWSCodeStarAWS2024",
       "ec2": "ArchAmazonEC2AWS2024", "vpn": "ArchAWSClientVPNAWS2024"}
BLUE, GREY, ORANGE, GREEN, PURPLE = "#2D6CDF", "#6B7280", "#ED7100", "#1A7F37", "#8C4FFF"
ZONE = {"fill": {"type": "color", "color": "#F5F6F8"}, "stroke": {"color": "#9CA3AF", "width": 1.5, "style": "dashed"}}
NS = {"fill": {"type": "color", "color": "#EEF4FF"}, "stroke": {"color": "#326CE5", "width": 2, "style": "solid"}}
PHASE = {"fill": {"type": "color", "color": "#FFFFFF"}, "stroke": {"color": "#326CE5", "width": 2, "style": "dashed"}}
NOSTROKE = {"color": "#00000000", "width": 0, "style": "solid"}
ICON = 88

def t(text, px=14, bold=False, align="center"):
    inner = "<b>%s</b>" % text if bold else text
    return '<p style="font-size:%dpx;text-align:%s">%s</p>' % (px, align, inner)

class Page:
    def __init__(self, pid, title):
        self.pid, self.title, self.shapes, self.lines = pid, title, [], []
    def id(self, s): return "%s_%s" % (self.pid, s)
    def heading(self, text, sub, w=1900):
        self.shapes.append({"id": self.id("h1"), "type": "text", "boundingBox": {"x": 40, "y": 10, "w": w, "h": 44}, "text": t(text, 26, True, "left")})
        self.shapes.append({"id": self.id("h2"), "type": "text", "boundingBox": {"x": 40, "y": 54, "w": w, "h": 30}, "text": t(sub, 15, False, "left")})
    def zone(self, i, x, y, w, h, title, style=ZONE):
        self.shapes.append({"id": self.id(i), "type": "rectangleContainer", "boundingBox": {"x": x, "y": y, "w": w, "h": h},
                            "containerTitle": {"text": title}, "style": style})
    def aws_zone(self, i, cls, x, y, w, h, text):
        self.shapes.append({"id": self.id(i), "type": "namedContainer", "className": cls,
                            "boundingBox": {"x": x, "y": y, "w": w, "h": h}, "text": t(text, 15, True, "left")})
    def label(self, i, cx, y, text, w=240, h=40, px=13):
        self.shapes.append({"id": self.id(i), "type": "text", "boundingBox": {"x": cx - w // 2, "y": y, "w": w, "h": h}, "text": t(text, px)})
    def node(self, i, kind, key, x, y, title, detail=None, wide=240, size=ICON):
        """icon at (x,y) size x size, title + detail under it; returns centre"""
        if kind == "aws":
            self.shapes.append({"id": self.id(i), "type": "namedShape", "className": AWS[key],
                                "boundingBox": {"x": x, "y": y, "w": size, "h": size}, "text": " "})
        else:
            self.shapes.append({"id": self.id(i), "type": "image", "boundingBox": {"x": x, "y": y, "w": size, "h": size},
                                "image": {"type": "image", "url": LOGO[key]}, "stroke": NOSTROKE})
        cx = x + size // 2
        body = '<span style="font-size:15px"><b>%s</b></span>' % title + ("<br>" + detail if detail else "")
        self.shapes.append({"id": self.id(i + "t"), "type": "text", "boundingBox": {"x": cx - wide // 2, "y": y + size + 6, "w": wide, "h": 70 if detail else 28},
                            "text": '<p style="font-size:12px;text-align:center">%s</p>' % body})
    def box(self, i, x, y, w, h, text, color=BLUE, fill="#FFFFFF", px=13):
        self.shapes.append({"id": self.id(i), "type": "rectangle", "boundingBox": {"x": x, "y": y, "w": w, "h": h},
                            "text": t(text, px), "style": {"fill": {"type": "color", "color": fill},
                                                           "stroke": {"color": color, "width": 2, "style": "solid"}}})
    def line(self, i, a, b, pa, pb, color=BLUE, label=None, lpos=0.5, side="top", dashed=False, kind="straight", width=2):
        l = {"id": self.id("L" + i), "lineType": kind,
             "endpoint1": {"type": "shapeEndpoint", "style": "none", "shapeId": self.id(a), "position": {"x": pa[0], "y": pa[1]}},
             "endpoint2": {"type": "shapeEndpoint", "style": "arrow", "shapeId": self.id(b), "position": {"x": pb[0], "y": pb[1]}},
             "stroke": {"color": color, "width": width, "style": "dashed" if dashed else "solid"}}
        if label:
            l["text"] = [{"text": '<span style="font-size:12px">%s</span>' % label, "position": lpos, "side": side}]
        self.lines.append(l)
    def out(self):
        return {"id": self.pid, "title": self.title, "shapes": self.shapes, "lines": self.lines}

R, L, T, B = (1, 0.5), (0, 0.5), (0.5, 0), (0.5, 1)

# ───────────────────────── Page 1: architecture ─────────────────────────
p = Page("p1", "1 Architecture")
p.heading("SonarQube on EKS (POC, GENESIS-447522)",
          "pref-dev cluster aws0prefdeveks01, SonarQube Community 26.9.0.129388, chart SonarSource sonarqube 2026.5.1002. Blue = runtime traffic, orange = delivery (GitOps / Terraform / one-time restore), green = secrets.")
H = 1310
p.zone("z_on", 40, 110, 400, H, "Corporate network (on-prem, VPN)")
p.aws_zone("z_hub", "AWSCloudAWS2024", 520, 110, 400, H, "Hub account 182399717428")
p.aws_zone("z_pto", "AWSCloudAWS2024", 1000, 110, 1560, H, "PTO-Reference account 468381823127")
p.aws_zone("z_reg", "RegionAWS2024", 1030, 150, 1500, H - 60, "us-west-2")
p.zone("z_eks", 1360, 190, 740, H - 140, "EKS cluster aws0prefdeveks01 (pref-dev)", NS)
p.zone("z_ns", 1390, 600, 680, H - 570, "namespace sonarqube (system nodegroup)", PHASE)
# on-prem
p.node("usr", "aws", "vpn", 196, 200, "Engineers (VPN)", "browser: UI, tokens")
p.node("run", "img", "gitlab", 196, 430, "GitLab runner #23", "sfo-cvdevopsgitwork01, tag docker<br>sonar-scanner-cli 8.1.0")
p.node("gl", "img", "gitlab", 196, 890, "GitLab", "iac/argocd/argocd<br>pto-reference/terraform")
p.node("vault", "img", "vault", 196, 1180, "Vault", "secret2/pref/automation<br>EC2 DB creds, admin pw")
# hub
p.node("cc", "aws", "codestar", 676, 890, "CodeConnections", "mirror of iac/argocd/argocd")
p.node("argo", "img", "argo", 676, 1160, "Argo CD (EKS-managed)", "app sonarqube-aws0prefdeveks01<br>auto-sync, selfHeal, prune")
# PTO edge
p.node("dns", "aws", "r53", 1146, 200, "DNS (wildcard)", "sonarqube.dev.aws0.pref.eislab.cloud")
p.node("alb", "aws", "alb", 1146, 430, "Internal ALB", "aws0prefdeveks01-alb, 443")
p.node("ec2", "aws", "ec2", 1146, 880, "EC2 aws0prefsonar01", "source: SonarQube 25.1 + postgres<br>Infra VPC, untouched")
p.node("atl", "img", "atlantis", 1146, 1150, "Atlantis", "MR !51, targeted apply<br>module.rds_sonarqube")
# EKS
p.node("istio", "img", "istio", 1446, 230, "Istio cluster-gw", "VS sonarqube-sonarqube-vs")
p.node("eso", "img", "eso", 1916, 230, "External Secrets", "ClusterSecretStore<br>scope aws0prefdeveks01/*", wide=200)
p.node("sonar", "img", "sonar", 1686, 660, "SonarQube 26.9 CE", "StatefulSet sonarqube, pod sonarqube-0<br>9000 UI/API, 4-6 GiB")
p.node("pvc", "img", "pvc", 1686, 960, "PVC sonarqube", "10Gi gp3, ES index only")
p.node("init", "img", "pod", 1466, 880, "init-sysctl", "privileged, vm.max_map_count<br>524288", wide=220)
p.node("sec", "img", "secret", 1916, 1000, "k8s Secrets", "db-secret (JDBC pw)<br>app-secret (passcode)", wide=200)
# AWS services
p.node("sm", "aws", "sm", 2266, 230, "Secrets Manager", "aws0prefdeveks01/sonarqube/{db,app}<br>aws0prefdevrdssonarqube/master")
p.node("rds", "aws", "rds", 2266, 720, "RDS PostgreSQL 16.10", "aws0prefdevrdssonarqube, t4g.small<br>db sonarqube owner sonarqube")
# runtime (blue)
p.line("u1", "usr", "alb", R, L, BLUE, "HTTPS 443", lpos=0.45)
p.line("u1b", "run", "alb", R, L, BLUE, "scan 443", lpos=0.45, side="bottom")
p.line("u2", "dnst", "alb", B, T, BLUE)
p.line("u3", "alb", "istiot", R, B, BLUE, "443", lpos=0.35)
p.line("u4", "istiot", "sonar", B, T, BLUE, "9000", lpos=0.5)
p.line("u5", "sonar", "rds", R, L, BLUE, "JDBC TLS, user sonarqube", lpos=0.55, side="bottom")
p.line("u7", "sonart", "pvc", B, T, BLUE)
# delivery (orange)
p.line("d1", "gl", "cc", R, L, ORANGE, "mirror")
p.line("d2", "cct", "argo", B, T, ORANGE)
p.line("d3", "argo", "init", R, L, ORANGE, "sync", lpos=0.4)
p.line("d4", "glt", "atl", B, L, ORANGE, "MR plan / apply", lpos=0.5, side="bottom")
p.line("d5", "ec2", "rdst", R, (0.3, 1), ORANGE, "dump / restore once (SSM relay)", lpos=0.45, side="bottom", dashed=True)
# secrets (green)
p.line("s1", "sm", "eso", L, R, GREEN, "GetSecretValue")
p.line("s2", "esot", "sec", B, T, GREEN, "sync", lpos=0.15)
p.line("s3", "sec", "sonart", L, (0.8, 1), GREEN, "env", lpos=0.5)
pages = [p.out()]

# ───────────────────────── Page 2: order of work ─────────────────────────
q = Page("p2", "2 Order of work")
q.heading("Order that worked: data first, then two upgrade hops",
          "SonarQube 26.9 refuses a 25.1 database (\"upgrade to the 25.12 version first\"). Restore before the first start, then 25.1 -> 25.12 -> 26.9.", w=2200)
Y = 260
q.zone("g1", 40, 130, 700, 420, "1 Infra + data (Terraform, POC scripts)")
q.zone("g2", 780, 130, 640, 420, "2 Deploy (Argo CD)", NS)
q.zone("g3", 1460, 130, 1100, 420, "3 Upgrade hops + proof", PHASE)
q.node("tf", "img", "atlantis", 90, Y, "MR !51", "RDS via Atlantis<br>7 add, 0 destroy", wide=200)
q.node("boot", "img", "job", 320, Y, "Secrets + DB role", "SM secrets, role<br>sonarqube owns DB", wide=200)
q.node("rest", "aws", "rds", 560, Y, "Restore", "EC2 25.1 -> RDS<br>99/99 tables", wide=200)
q.node("a506", "img", "argo", 840, Y, "MR !506", "component synced", wide=200)
q.node("s26a", "img", "sonar", 1120, Y, "26.9 start", "refused: too old<br>schema untouched", wide=220)
q.node("s25", "img", "sonar", 1520, Y, "MR !510: 25.12", "migrate_db -> UP<br>~30 s", wide=200)
q.node("s26", "img", "sonar", 1800, Y, "MR !514: 26.9", "migrate_db -> UP", wide=200)
q.node("ci", "img", "gitlab", 2080, Y, "CI scan", "quality gate PASSED", wide=200)
q.node("doc", "img", "argo", 2360, Y, "MRs !518 !528", "README results", wide=200)
for n, (a, b) in enumerate([("tf", "boot"), ("boot", "rest"), ("rest", "a506"), ("a506", "s26a"), ("s26a", "s25"), ("s25", "s26"), ("s26", "ci"), ("ci", "doc")]):
    q.line("a%d" % n, a, b, R, L, ORANGE)
q.box("note", 40, 620, 2520, 110,
      "<b>Stuck rollout once</b>: hop 1 needed the crash-looping 26.9 pod removed by hand (StatefulSet OrderedReady never replaces a never-Ready pod). Hop 2 rolled by itself. "
      "Every 25.1 instance (CAA pins 25.1) needs the same 2 hops at cutover: one window per hop.", GREY, "#F9FAFB", 15)
pages.append(q.out())

# ───────────────────────── Page 3: identity and secrets ─────────────────────────
r = Page("p3", "3 Identity and secrets")
r.heading("Who can read what", "No secret value in git or logs. POC: SM secrets and DB role from scripts; Terraform before cutover.", w=2200)
r.zone("src", 40, 130, 560, 980, "Sources")
r.zone("k8", 660, 130, 1100, 980, "Read at runtime / by the one-off jobs", NS)
r.zone("dst", 1820, 130, 900, 980, "Targets")
r.node("vault", "img", "vault", 110, 200, "Vault", "secret2/pref/automation<br>login -method=ldap", wide=200)
r.node("sm1", "aws", "sm", 380, 200, "sonarqube/db, app", "ESO scope aws0prefdeveks01/*", wide=220)
r.node("sm2", "aws", "sm", 380, 470, "rds .../master", "outside the ESO prefix", wide=220)
r.node("adm", "img", "sonar", 110, 820, "admin", "restored EC2 admin<br>pw in Vault", wide=200)
r.node("dump", "img", "docker", 740, 600, "Dump script", "pg_dump in postgres:16<br>over SSM port-forward", wide=240)
r.node("eso", "img", "eso", 740, 200, "ESO", "reads aws0prefdeveks01/* only", wide=240)
r.node("sec", "img", "secret", 1000, 200, "k8s Secrets", "db-secret, app-secret", wide=220)
r.node("bjob", "img", "job", 1000, 470, "Bootstrap pod", "master pw via temp Secret,<br>deleted at exit", wide=240)
r.node("pod", "img", "sonar", 1300, 200, "sonarqube-0", "JDBC user sonarqube,<br>monitoring passcode", wide=220)
r.node("tok", "img", "gitlab", 1300, 820, "SONAR_TOKEN", "user token, masked<br>project 1637", wide=220)
r.node("rds", "aws", "rds", 1900, 470, "RDS", "role sonarqube (runtime)<br>postgres (bootstrap only)", wide=220)
r.node("run", "img", "gitlab", 2200, 820, "CI scan", "runner #23, tag docker", wide=220)
r.box("ad", 1900, 200, 760, 110, "<b>AD / LDAP: not configured on the POC</b> (local admin only). Cutover: sonar.security.realm=LDAP, bind pw from SM; reuse Nexus POC LDAPS settings.", GREY, "#F9FAFB", 14)
r.line("g1", "sm1", "eso", R, L, GREEN, "read")
r.line("g2", "eso", "sec", R, L, GREEN, "sync")
r.line("g3", "sec", "pod", R, L, GREEN, "env")
r.line("g4", "sm2", "bjob", R, L, GREEN, "master", lpos=0.3)
r.line("g5", "bjobt", "rdst", B, B, BLUE, "CREATE ROLE sonarqube", lpos=0.5, kind="elbow")
r.line("g6", "vaultt", "dump", B, (0, 0.3), GREEN, "EC2 DB creds", lpos=0.4)
r.line("g7", "dump", "rds", (1, 0.3), (0.3, 1), ORANGE, "pg_restore", lpos=0.5, kind="elbow")
r.line("g8", "adm", "tok", R, L, GREEN, "generate token", lpos=0.3)
r.line("g9", "tok", "run", R, L, GREEN, "CI variable")
pages.append(r.out())

print(json.dumps({"version": 1, "pages": pages}, separators=(",", ":")))
