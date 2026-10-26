#!/usr/bin/env python3
"""Lucid Standard Import for the Nexus on EKS POC (GENESIS-425582). 3 pages. python3 -I gen_nexus_lucid.py > spec.json"""
import json

DI = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/"
K8 = "https://raw.githubusercontent.com/kubernetes/community/master/icons/png/resources/labeled/"
CN = "https://raw.githubusercontent.com/cncf/artwork/main/projects/"
LOGO = {
    "gitlab": DI + "gitlab.png", "vault": DI + "hashicorp-vault.png", "windows": DI + "microsoft-windows.png",
    "nexus": DI + "nexus.png", "postgres": DI + "postgresql.png", "docker": DI + "docker.png", "jenkins": DI + "jenkins.png",
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
p.heading("Nexus Repository on EKS (POC, GENESIS-425582)",
          "pref-dev cluster aws0prefdeveks01, Nexus 3.97.0 Community Edition, chart stevehipwell/nexus3 5.27.0. Blue = runtime traffic, orange = delivery (GitOps / Terraform), green = identity and secrets.")
H = 1310
p.zone("z_on", 40, 110, 400, H, "Corporate network (on-prem, VPN)")
p.aws_zone("z_hub", "AWSCloudAWS2024", 520, 110, 400, H, "Hub account 182399717428")
p.aws_zone("z_pto", "AWSCloudAWS2024", 1000, 110, 1560, H, "PTO-Reference account 468381823127")
p.aws_zone("z_reg", "RegionAWS2024", 1030, 150, 1500, H - 60, "us-west-2")
p.zone("z_eks", 1360, 190, 740, H - 140, "EKS cluster aws0prefdeveks01 (pref-dev)", NS)
p.zone("z_ns", 1390, 600, 680, H - 570, "namespace nexus (system nodegroup, m6a.2xlarge)", PHASE)
p.zone("z_up", 2610, 110, 260, 640, "Internet upstreams")
# on-prem
p.node("ad", "img", "windows", 196, 200, "Active Directory", "exigengroup.com, LDAPS 636<br>bind CN=ldap,CN=users")
p.node("usr", "aws", "vpn", 196, 430, "Engineers (VPN)", "browser, docker, helm CLI")
p.node("gl", "img", "gitlab", 196, 890, "GitLab", "iac/argocd/argocd<br>pto-reference/terraform")
p.node("vault", "img", "vault", 196, 1180, "Vault", "LDAP bind pw + AD root CA<br>(copied once, then unused)")
# hub
p.node("cc", "aws", "codestar", 676, 890, "CodeConnections", "mirror of iac/argocd/argocd")
p.node("argo", "img", "argo", 676, 1160, "Argo CD (EKS-managed)", "app nexus-aws0prefdeveks01<br>auto-sync, selfHeal, prune")
# PTO edge
p.node("tgw", "aws", "tgw", 1146, 200, "Transit Gateway", "routes to on-prem AD")
p.node("dns", "aws", "r53", 1146, 430, "DNS", "nexus.dev.aws0.pref.eislab.cloud")
p.node("alb", "aws", "alb", 1146, 660, "Internal ALB", "aws0prefdeveks01-alb, 443")
p.node("atl", "img", "atlantis", 1146, 1150, "Atlantis", "aws0prefatlantis01<br>project lower-dev-services")
# EKS
p.node("istio", "img", "istio", 1446, 230, "Istio cluster-gw", "VirtualService nexus-nexus-vs")
p.node("eso", "img", "eso", 1916, 230, "External Secrets", "ClusterSecretStore<br>scope aws0prefdeveks01/*", wide=200)
p.node("nexus", "img", "nexus", 1686, 660, "Nexus 3.97.0 CE", "StatefulSet nexus, pod nexus-0<br>8081 UI/API, 5002 docker")
p.node("pvc", "img", "pvc", 1686, 960, "PVC data-nexus-0", "20Gi gp3, local state only")
p.node("pre", "img", "job", 1466, 880, "PreSync Job", "nexus-db-bootstrap<br>SA with IRSA", wide=220)
p.node("post", "img", "job", 1466, 1130, "PostSync Jobs", "nexus-config-1, nexus-ldap-config<br>REST config of Nexus", wide=220)
p.node("sec", "img", "secret", 1916, 1000, "k8s Secrets", "admin, db, ldap,<br>nexus-ca-certs (public CA)", wide=200)
# AWS services
p.node("sm", "aws", "sm", 2266, 230, "Secrets Manager", "aws0prefdeveks01/nexus/*<br>aws0prefdevrdsnexus/master")
p.node("s3", "aws", "s3", 2266, 430, "S3 bucket", "aws0prefdevnexus-blobs<br>blob store s3-main")
p.node("rds", "aws", "rds", 2266, 720, "RDS PostgreSQL 16.10", "aws0prefdevrdsnexus, t4g.medium<br>db nexus owner nexus, pg_trgm")
p.node("iam", "aws", "role", 2266, 1100, "IAM IRSA roles", "nexus-Role: one bucket<br>nexus-db-bootstrap-Role: master")
# upstreams (no lines: reached by the proxy repos over the NAT path)
p.node("dh", "img", "docker", 2696, 180, "Docker Hub", "dockerhub-proxy", wide=200)
p.node("jc", "img", "jenkins", 2696, 420, "charts.jenkins.io", "jenkins-charts-proxy", wide=200)
p.label("upn", 2740, 650, "used by Nexus proxy repos", w=220, h=40, px=12)
# runtime (blue)
p.line("u1", "usr", "alb", R, L, BLUE, "HTTPS 443", lpos=0.45)
p.line("u2", "dnst", "alb", B, T, BLUE)
p.line("u3", "alb", "istiot", R, B, BLUE, "443", lpos=0.35)
p.line("u4", "istiot", "nexus", B, T, BLUE, "8081", lpos=0.5)
p.line("u5", "nexus", "rds", R, L, BLUE, "JDBC TLS, user nexus", lpos=0.55, side="bottom")
p.line("u6", "nexus", "s3", R, L, BLUE, "S3 API via IRSA", lpos=0.55)
p.line("u7", "nexust", "pvc", B, T, BLUE)
p.line("u10", "nexus", "tgwt", (0, 0.25), B, GREEN, "LDAPS 636", lpos=0.25)
p.line("u11", "tgw", "ad", L, R, GREEN, "LDAPS to AD")
# delivery (orange)
p.line("d1", "gl", "cc", R, L, ORANGE, "mirror")
p.line("d2", "cct", "argo", B, T, ORANGE)
p.line("d3", "argo", "pre", R, L, ORANGE, "sync: PreSync, Sync, PostSync", lpos=0.4)
p.line("d4", "glt", "atl", B, L, ORANGE, "MR plan / apply", lpos=0.5, side="bottom")
p.line("d5", "pre", "rdst", R, (0.3, 1), ORANGE, "create role / db over TLS", lpos=0.45, side="bottom")
# secrets (green)
p.line("s1", "sm", "eso", L, R, GREEN, "GetSecretValue")
p.line("s2", "esot", "sec", B, T, GREEN, "sync", lpos=0.15)
p.line("s3", "sec", "nexust", L, (0.8, 1), GREEN, "env + files", lpos=0.5)
pages = [p.out()]

# ───────────────────────── Page 2: sync and rebuild order ─────────────────────────
q = Page("p2", "2 Sync and rebuild order")
q.heading("What ArgoCD does on every sync (and on a rebuild from nothing)",
          "Proven 2026-10-19 15:08Z: S3 emptied, database dropped, PVC deleted; ArgoCD rebuilt everything with zero manual steps.", w=2200)
Y = 260
q.zone("g", 40, 130, 440, 420, "1 Git")
q.zone("pre", 520, 130, 860, 420, "2 PreSync (hooks)", PHASE)
q.zone("syn", 1420, 130, 620, 420, "3 Sync", NS)
q.zone("pst", 2080, 130, 660, 420, "4 PostSync (hooks)", PHASE)
q.node("gl", "img", "gitlab", 100, Y, "MR merged", "argocd/argocd main", wide=200)
q.node("argo", "img", "argo", 330, Y, "Argo CD", "refresh via CodeConnections", wide=200)
q.node("es", "img", "eso", 580, Y, "ExternalSecrets", "wave -20<br>admin, db, ldap", wide=200)
q.node("sa", "img", "sa", 820, Y, "ServiceAccount", "wave -10<br>nexus-db-bootstrap, IRSA", wide=200)
q.node("job", "img", "job", 1100, Y, "Bootstrap Job", "wave 0: role nexus,<br>db OWNER nexus, pg_trgm", wide=220)
q.node("sts", "img", "sts", 1480, Y, "StatefulSet", "nexus, RollingUpdate", wide=200)
q.node("nx", "img", "nexus", 1720, Y, "nexus-0", "import AD CA, start on RDS", wide=220)
q.node("cfg", "img", "job", 2150, Y, "Config Job", "blob store, 5 repos,<br>realms, 5 roles", wide=200)
q.node("ldap", "img", "job", 2400, Y, "LDAP Job", "LDAP 'ad' upsert<br>jq --rawfile", wide=200)
for n, (a, b) in enumerate([("gl", "argo"), ("argo", "es"), ("es", "sa"), ("sa", "job"), ("job", "sts"), ("sts", "nx"), ("nx", "cfg"), ("cfg", "ldap")]):
    q.line("a%d" % n, a, b, R, L, ORANGE)
Y2 = 680
q.node("sm", "aws", "sm", 580, Y2, "Secrets Manager", "values written by Terraform<br>(write-only)", wide=220)
q.node("rds", "aws", "rds", 1100, Y2, "RDS PostgreSQL", "aws0prefdevrdsnexus", wide=200)
q.node("s3", "aws", "s3", 1720, Y2, "S3 s3-main", "aws0prefdevnexus-blobs", wide=200)
q.node("ad", "img", "windows", 2400, Y2, "Active Directory", "exigengroup.com:636", wide=200)
q.line("b1", "sm", "est", T, B, GREEN, "read", lpos=0.5)
q.line("b2", "jobt", "rds", B, T, BLUE, "SQL over TLS", lpos=0.5)
q.line("b3", "nxt", "s3", B, T, BLUE, "IRSA", lpos=0.5)
q.line("b4", "ldapt", "ad", B, T, GREEN, "verify bind", lpos=0.5)
q.box("note", 40, 900, 2700, 110,
      "<b>Rebuild proof</b>: new PVC 15:10:39Z; nexus-0 restarted 3x while database nexus did not exist, an Argo retry ran the bootstrap Job, Nexus started fresh with the Terraform admin password, "
      "config + LDAP Jobs succeeded, sync Succeeded. Only manual step on a fresh Community Edition database: accept the EULA (legal decision, done by a person).", GREY, "#F9FAFB", 15)
pages.append(q.out())

# ───────────────────────── Page 3: identity and secrets ─────────────────────────
r = Page("p3", "3 Identity and secrets")
r.heading("Who can read what", "No secret value in git, plan output or logs. Each identity gets the narrowest scope that works.", w=2200)
r.zone("tf", 40, 130, 560, 980, "Written by Terraform (MR !52, Atlantis)")
r.zone("k8", 660, 130, 1100, 980, "Read at runtime in the cluster", NS)
r.zone("dst", 1820, 130, 900, 980, "Targets")
r.node("atl", "img", "atlantis", 110, 200, "Atlantis apply", "ephemeral random_password<br>secret_string_wo", wide=200)
r.node("sm1", "aws", "sm", 380, 200, "nexus/admin, db", "ESO scope aws0prefdeveks01/*", wide=220)
r.node("sm2", "aws", "sm", 380, 470, "rds .../master", "outside the ESO prefix", wide=220)
r.node("sm3", "aws", "sm", 380, 740, "nexus/ldap", "empty shell, value copied<br>once from Vault", wide=220)
r.node("vault", "img", "vault", 110, 740, "Vault", "secret2/pref/automation/ldap<br>secret2/ansible/.../ldap (CA)", wide=200)
r.node("eso", "img", "eso", 740, 200, "ESO role", "reads aws0prefdeveks01/* only", wide=240)
r.node("sec", "img", "secret", 1000, 200, "k8s Secrets", "admin-secret, db-secret,<br>ldap-secret", wide=220)
r.node("ca", "img", "cm", 1300, 200, "nexus-ca-certs", "public AD root CA,<br>SHA-1 39:CA:F2:08...", wide=220)
r.node("bsa", "img", "sa", 740, 470, "SA nexus-db-bootstrap", "IRSA: GetSecretValue on<br>the master secret ARN only", wide=240)
r.node("bjob", "img", "job", 1000, 470, "Bootstrap Job", "master pw in memory emptyDir,<br>never a k8s Secret", wide=240)
r.node("pod", "img", "nexus", 1300, 470, "nexus-0", "env JDBC user nexus,<br>JVM truststore + AD CA", wide=220)
r.node("nsa", "img", "sa", 740, 740, "SA nexus", "IRSA: one bucket only<br>(other bucket AccessDenied)", wide=240)
r.node("rds", "aws", "rds", 1900, 470, "RDS", "role nexus (runtime)<br>postgres (bootstrap only)", wide=220)
r.node("s3", "aws", "s3", 1900, 740, "S3 bucket", "aws0prefdevnexus-blobs", wide=220)
r.node("ad", "img", "windows", 2200, 200, "AD groups", "nexus_genesis-admins -&gt; nx-admin<br>DevOps -&gt; nx-all, nexus_pref-*", wide=260)
r.node("role", "aws", "role", 2200, 740, "IRSA trust", "sub system:serviceaccount:<br>nexus:nexus, nexus:nexus-db-bootstrap", wide=260)
r.line("w1", "atl", "sm1", R, L, ORANGE, "write-only")
r.line("w2", "atlt", "sm2", B, (0, 0.3), ORANGE, "master", lpos=0.5)
r.line("w3", "vault", "sm3", R, L, GREY, "copied once", dashed=True)
r.line("g1", "sm1", "eso", R, L, GREEN, "read")
r.line("g2", "eso", "sec", R, L, GREEN, "sync")
r.line("g3", "sect", "pod", B, (0.2, 0), GREEN, "env / files", lpos=0.5)
r.line("g4", "sm2", "bsa", R, L, GREEN, "read via IRSA")
r.line("g5", "bsa", "bjob", R, L, GREEN)
r.line("g6", "bjobt", "rdst", B, B, BLUE, "ALTER ROLE nexus", lpos=0.5, kind="elbow")
r.line("g7", "pod", "rds", R, L, BLUE, "JDBC TLS")
r.line("g8", "nsa", "s3", R, L, GREEN, "S3 API", lpos=0.5)
r.line("g9", "cat", "pod", B, T, GREEN, "truststore")
r.line("g10", "pod", "ad", (1, 0.2), (0, 0.6), GREEN, "LDAPS 636 login", lpos=0.4)
pages.append(r.out())

print(json.dumps({"version": 1, "pages": pages}, separators=(",", ":")))
