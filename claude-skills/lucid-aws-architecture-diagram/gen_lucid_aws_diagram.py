import json

LOGO = {
    "gitlab": "https://commons.wikimedia.org/wiki/Special:FilePath/GitLab_icon.svg?width=240",
    "argo": "https://raw.githubusercontent.com/cncf/artwork/main/projects/argo/icon/color/argo-icon-color.png",
    "helm": "https://raw.githubusercontent.com/cncf/artwork/main/projects/helm/icon/color/helm-icon-color.png",
}
ACC = {"fill": {"type": "color", "color": "#DCEBFF"}, "stroke": {"color": "#2D6CDF", "width": 2, "style": "solid"}}
PLN = {"fill": {"type": "color", "color": "#FFFFFF"}, "stroke": {"color": "#6B7280", "width": 1.5, "style": "solid"}}
ZONE = {"fill": {"type": "color", "color": "#F5F6F8"}, "stroke": {"color": "#9CA3AF", "width": 1.5, "style": "dashed"}}
NOSTROKE = {"color": "#00000000", "width": 0, "style": "solid"}

shapes, lines = [], []

def t(text, px=14, bold=False):
    s = '<p style="font-size:%dpx;text-align:center">%s</p>' % (px, text)
    return s.replace(text, "<b>" + text + "</b>") if bold else s

def zone(i, x, y, w, h, title):
    shapes.append({"id": i, "type": "rectangleContainer", "boundingBox": {"x": x, "y": y, "w": w, "h": h},
                   "containerTitle": {"text": title}, "style": ZONE})

def named_container(i, cls, x, y, w, h, text):
    shapes.append({"id": i, "type": "namedContainer", "className": cls,
                   "boundingBox": {"x": x, "y": y, "w": w, "h": h}, "text": text})

def label(i, cx, y, text, w=280, h=60, px=14):
    shapes.append({"id": i, "type": "text", "boundingBox": {"x": cx - w // 2, "y": y, "w": w, "h": h}, "text": t(text, px)})

def aws(i, cls, x, y, w, h, title, detail=None):
    shapes.append({"id": i, "type": "namedShape", "className": cls, "boundingBox": {"x": x, "y": y, "w": w, "h": h},
                   "text": t(title, 16)})
    if detail:
        label(i + "_d", x + w // 2, y + h + 38, detail, h=40)

def img(i, key, x, y, title, detail=None):
    shapes.append({"id": i, "type": "image", "boundingBox": {"x": x, "y": y, "w": 96, "h": 96},
                   "image": {"type": "image", "url": LOGO[key]}, "stroke": NOSTROKE})
    label(i + "_t", x + 48, y + 104, title, w=240, h=28, px=16)
    if detail:
        label(i + "_d", x + 48, y + 136, detail, w=240, h=40, px=14)

def rect(i, x, y, w, h, text, accent):
    shapes.append({"id": i, "type": "rectangle", "boundingBox": {"x": x, "y": y, "w": w, "h": h},
                   "text": t(text, 16), "style": ACC if accent else PLN})

def line(i, a, b, accent, by=0.5, label_text=None):
    l = {"id": i, "lineType": "straight",
         "endpoint1": {"type": "shapeEndpoint", "style": "none", "shapeId": a, "position": {"x": 1, "y": 0.5}},
         "endpoint2": {"type": "shapeEndpoint", "style": "arrow", "shapeId": b, "position": {"x": 0, "y": by}},
         "stroke": {"color": "#2D6CDF" if accent else "#6B7280", "width": 2 if accent else 1.5, "style": "solid"}}
    if label_text:
        l["text"] = [{"text": label_text, "position": 0.5, "side": "top"}]
    lines.append(l)

rows = {"A": 380, "B": 580, "E": 780, "C": 1020, "D": 1220}
cy = {k: v + 48 for k, v in rows.items()}
ecr_y, ecr_h = 380, 950
def frac(k):
    return round((cy[k] - ecr_y) / ecr_h, 4)

zone("z_gl", 20, 60, 400, 1370, "GitLab, on-prem datacenter")
named_container("z_aws", "AWSCloudAWS2024", 440, 60, 1900, 1450, "AWS account 182399717428")
named_container("z_reg", "RegionAWS2024", 480, 120, 1820, 1370, "us-west-2")
zone("z_eks", 540, 330, 640, 660, "Hub EKS cluster aws0iacdeveks01, namespace iac")

# GitLab side
img("g1", "gitlab", 100, rows["A"], "iac/argocd/argocd CI", "pull jobs, tag eks-irsa")
img("g2", "gitlab", 100, rows["B"], "ecr-helm-guestbook-chart", "push jobs, tag eks-irsa-push")
rect("g3", 80, rows["C"], 280, 96, "Docker runners, on-prem<br>masked vars ECR_PULL_AWS_*<br>key option", False)
rect("g5", 80, rows["D"], 280, 96, "Publisher pipeline<br>other team<br>push key or SSO", False)

# AWS services strip above the EKS box
aws("eks", "ArchAmazonElasticKubernetesServiceAWS2024", 700, 140, 80, 80, "Amazon EKS", "hub cluster")
aws("sm", "ArchAWSSecretsManagerAWS2024", 1000, 140, 80, 80, "Secrets Manager", "runner tokens of 37 and 38")

# EKS runners and pods (rows A, B), Argo CD (row E)
rect("r37", 580, rows["A"], 240, 96, "Runner 37<br>tag eks-irsa", True)
rect("p37", 900, rows["A"], 240, 96, "Job pod<br>SA gitlab-ci-ecr-pull<br>IRSA credentials", True)
rect("r38", 580, rows["B"], 240, 96, "Runner 38 (protected)<br>tag eks-irsa-push", True)
rect("p38", 900, rows["B"], 240, 96, "Job pod<br>SA gitlab-ci-ecr-push<br>IRSA credentials", True)
img("argo", "argo", 620, rows["E"], "Argo CD", "EKS-managed capability")

# IAM
for k, i, ttl, det in (("A", "pullrole", "IRSA pull role", "aws0iacdeveks01-gitlab-ci-ecr-pull-Role"),
                       ("B", "pushrole", "IRSA push role", "push only on ecr-helm-guestbook"),
                       ("E", "argorole", "Argo CD role", "capability role, ECRRead, no key")):
    aws(i, "ResAWSIdentityAccessManagementRoleAWS2024", 1440, cy[k] - 35, 120, 70, ttl, det)
aws("pulluser", "ArchAWSIdentityandAccessManagementAWS2024", 1452, rows["C"], 96, 96, "Pull IAM user (key)",
    "aws0iacdevgitlab-argocd-ci-ecr-pull-user")
aws("pushuser", "ArchAWSIdentityandAccessManagementAWS2024", 1452, rows["D"], 96, 96, "Push IAM user (key)",
    "aws0iacdevhelm-charts-ci-ecr-push-user")

# ECR + Helm
aws("ecr_icon", "ArchAmazonElasticContainerRegistryAWS2024", 2000, 130, 100, 100, "Amazon ECR")
img("helm", "helm", 1800, 130, "Helm charts (OCI)")
shapes.append({"id": "ecr", "type": "rectangle", "boundingBox": {"x": 1900, "y": ecr_y, "w": 300, "h": ecr_h},
               "text": t("<b>10 Helm chart repos</b><br><br>helm-guestbook<br>ecr-helm-guestbook<br>metallb<br>pyrra<br>"
                         "observascope-oss<br>observascope-eis<br>observascope-logging<br>observascope-exporters<br>"
                         "observascope-storage<br>observascope-minio<br><br>IMMUTABLE tags, KMS<br>scan on push<br>"
                         "no delete for CI", 18),
               "style": {"fill": {"type": "color", "color": "#FFFFFF"},
                         "stroke": {"color": "#ED7100", "width": 2.5, "style": "solid"}}})

label("legend", 220, 1460, "Blue = keyless, no AWS key stored.<br>White = key option, Argo CD, other publishers.", w=340, h=70, px=16)

line("l1", "g1", "r37", True)
line("l2", "r37", "p37", True)
line("l3", "p37", "pullrole", True, label_text="web identity")
line("l4", "pullrole", "ecr", True, by=frac("A"), label_text="pull via role")
line("l5", "g2", "r38", True)
line("l6", "r38", "p38", True)
line("l7", "p38", "pushrole", True, label_text="web identity")
line("l8", "pushrole", "ecr", True, by=frac("B"), label_text="push via role")
line("l9", "argo", "argorole", False, label_text="capability role")
line("l10", "argorole", "ecr", False, by=frac("E"), label_text="pull via Argo")
line("l11", "g3", "pulluser", False, label_text="key option")
line("l12", "pulluser", "ecr", False, by=frac("C"), label_text="pull via key")
line("l13", "g5", "pushuser", False, label_text="push key or SSO")
line("l14", "pushuser", "ecr", False, by=frac("D"), label_text="push via key")

doc = {"version": 1, "pages": [{"id": "p1", "title": "ECR access, AWS style", "shapes": shapes, "lines": lines}]}
print(json.dumps(doc, separators=(",", ":")))
