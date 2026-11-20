#!/usr/bin/env python3
"""Standard Import JSON: GitOps promotion lower GitLab -> upper CodeCommit, 7 pages.
python3 -I gen.py > spec.json"""
import json

IMG = {
    "gitlab": "https://commons.wikimedia.org/wiki/Special:FilePath/GitLab_icon.svg?width=240",
    "jenkins": "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/jenkins.png",
    "argo": "https://raw.githubusercontent.com/cncf/artwork/main/projects/argo/icon/color/argo-icon-color.png",
    "helm": "https://raw.githubusercontent.com/cncf/artwork/main/projects/helm/icon/color/helm-icon-color.png",
    "atlantis": "https://raw.githubusercontent.com/runatlantis/atlantis/main/runatlantis.io/public/hero.png",
    "user": "https://raw.githubusercontent.com/kubernetes/community/master/icons/png/resources/labeled/user-128.png",
    "terraform": "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/terraform.png",
}
AWS = {
    "s3": "ArchAmazonSimpleStorageServiceAWS2024", "ecr": "ArchAmazonElasticContainerRegistryAWS2024",
    "codecommit": "ArchAWSCodeCommitAWS2024", "codebuild": "ArchAWSCodeBuildAWS2024",
    "eventbridge": "ArchAmazonEventBridgeAWS2024", "eks": "ArchAmazonElasticKubernetesServiceAWS2024",
}
INK = {"color": "#3A414A", "width": 2, "style": "solid"}
RED = {"color": "#C62828", "width": 2, "style": "dashed"}
NOSTROKE = {"color": "#0000", "width": 0, "style": "solid"}
ICON, PITCH, CAPW = 72, 240, 200
X0, ROW1, ROW2 = 130, 260, 560
pages = []


class Page:
    def __init__(self, n, title):
        self.p, self.shapes, self.lines = f"p{n}", [], []
        pages.append({"id": self.p, "title": title, "shapes": self.shapes, "lines": self.lines})

    def text(self, i, x, y, w, h, html):
        self.shapes.append({"id": f"{self.p}_{i}", "type": "text", "boundingBox": {"x": x, "y": y, "w": w, "h": h}, "text": html})

    def title(self, head, sub):
        self.text("title", 40, 20, 1800, 90,
                  f'<p style="font-size:26px;text-align:left"><b>{head}</b><br><span style="font-size:15px">{sub}</span></p>')

    def zone(self, i, label, x, w, y=190, h=300, color="#1565C0"):
        self.shapes.append({"id": f"{self.p}_{i}", "type": "rectangleContainer", "boundingBox": {"x": x, "y": y, "w": w, "h": h},
                            "containerTitle": {"text": label},
                            "style": {"stroke": {"color": color, "width": 2, "style": "dashed"}}})

    def icon(self, i, kind, col, row, name, detail):
        """One icon + caption. Returns the icon id; caption id is <id>t."""
        x, y = X0 + col * PITCH, row
        sid = f"{self.p}_{i}"
        bb = {"x": x, "y": y, "w": ICON, "h": ICON}
        if kind in AWS:
            self.shapes.append({"id": sid, "type": "namedShape", "className": AWS[kind], "boundingBox": bb,
                                "text": f'<p style="font-size:14px;text-align:center"><b>{name}</b></p>'})
            cap, cy = f'<p style="font-size:12px;text-align:center">{detail}</p>', y + ICON + 36
        else:
            self.shapes.append({"id": sid, "type": "image", "boundingBox": bb, "image": {"type": "image", "url": IMG[kind]}, "stroke": NOSTROKE})
            cap, cy = f'<p style="font-size:12px;text-align:center"><span style="font-size:14px"><b>{name}</b></span><br>{detail}</p>', y + ICON + 8
        self.shapes.append({"id": sid + "t", "type": "text", "boundingBox": {"x": x + ICON // 2 - CAPW // 2, "y": cy, "w": CAPW, "h": 76}, "text": cap})
        return sid

    def arrow(self, i, a, b, pa=(1, 0.5), pb=(0, 0.5), label=None, stroke=INK, side="top", pos=0.5):
        l = {"id": f"{self.p}_L{i}", "lineType": "straight",
             "endpoint1": {"type": "shapeEndpoint", "style": "none", "shapeId": a, "position": {"x": pa[0], "y": pa[1]}},
             "endpoint2": {"type": "shapeEndpoint", "style": "arrow", "shapeId": b, "position": {"x": pb[0], "y": pb[1]}},
             }
        if stroke is not INK:
            l["stroke"] = stroke
        if label:
            l["text"] = [{"text": f'<span style="font-size:12px">{label}</span>', "position": pos, "side": side}]
        self.lines.append(l)

    def up(self, i, lower_icon, upper_icon, label=None, stroke=INK):
        """Arrow from a row-2 icon up to the caption of the row-1 icon above it."""
        self.arrow(i, lower_icon, upper_icon + "t", (0.5, 0), (0.5, 1), label, stroke, side="middle")

    def box(self, i, x, y, w, h, head, lines, fill, fs=13):
        body = "<br>".join(lines)
        self.shapes.append({"id": f"{self.p}_{i}", "type": "rectangle", "boundingBox": {"x": x, "y": y, "w": w, "h": h},
                            "text": f'<p style="font-size:{fs}px;text-align:center"><span style="font-size:16px"><b>{head}</b></span><br>{body}</p>',
                            "style": {"fill": {"type": "color", "color": fill}}})

    def pros_cons(self, y, pros, cons, poc):
        self.box("pros", 60, y, 560, 230, "Advantages", pros, "#DFF5E1")
        self.box("cons", 680, y, 560, 230, "Disadvantages", cons, "#F8D7DA")
        self.box("poc", 1300, y, 560, 230, "First POC", poc, "#FFF2CC")


GREEN, BLUE, GREY, YEL, REDF = "#DFF5E1", "#DCEBFF", "#F2F3F5", "#FFF2CC", "#F8D7DA"

# ---------------------------------------------------------------- page 1: problem
p = Page(1, "1 Problem and requirements")
p.title("GitOps promotion: lower GitLab to upper CodeCommit",
        "Problem: move GitOps configuration from lower GitLab into the per-cluster CodeCommit repositories of upper, securely and repeatably.")
p.zone("lower", "LOWER (dev)", 60, 330, h=600)
p.zone("upper", "UPPER (stage, prod): no network path to any GitLab", 520, 800, h=600, color="#2E7D32")
gl = p.icon("gl", "gitlab", 0, ROW1, "GitLab argocd repo", "components/, templates/,<br>cluster and repo templates")
cc = p.icon("cc", "codecommit", 2, ROW1, "CodeCommit", "one repo per cluster:<br>NAME-argocd")
ar = p.icon("ar", "argo", 3, ROW1, "Argo CD", "self-hosted per cluster,<br>sync window")
ek = p.icon("ek", "eks", 4, ROW1, "EKS", "one cluster")
lap = p.icon("lap", "user", 2, ROW2, "Engineer laptop", "VPN + AWS CLI")
p.arrow("1", gl, cc, label="blocked: no network path", stroke=RED)
p.arrow("2", cc, ar)
p.arrow("3", ar, ek)
p.up("4", lap, cc, "write = break-glass only", RED)
reqs = [("Upper cannot reach lower GitLab", ["no direct network access", "(Atlantis is the one exception)"]),
        ("Laptop writes are break-glass", ["day to day goes through CyberArk;", "no hand-run scripts in upper"]),
        ("Seed and update: one mechanism", ["first-time seeding and later updates", "use the same path"]),
        ("Reviewable and approved", ["a person approves before anything", "merges in upper"]),
        ("Minimal additions", ["little new infrastructure, maintenance", "and few security exceptions"]),
        ("Keep the design", ["Argo CD per cluster and one", "CodeCommit repo per cluster stay"])]
for n, (h, l) in enumerate(reqs):
    p.box(f"req{n}", 1400 + (n % 2) * 300, 190 + (n // 2) * 150, 280, 120, h, l, BLUE, 12)
p.box("key", 1400, 660, 580, 130, "Key principle",
      ["The control is not only how code crosses environments,", "but how upper reviewers can verify, approve and recover changes."], YEL)

# ---------------------------------------------------------------- page 2: option A
p = Page(2, "2 Option A S3 bundle")
p.title("Option A: immutable S3 bundle + upper promotion", "Recommended for the initial implementation. Seed = update against an empty repo.")
p.zone("lower", "LOWER", 60, 455, h=600)
p.zone("upper", "UPPER", 530, 1370, h=600, color="#2E7D32")
a1 = p.icon("ci", "gitlab", 0, ROW1, "1. GitLab CI", "render per cluster, gate,<br>bundle: files, hashes, commit")
a2 = p.icon("s3", "s3", 1, ROW1, "2. S3 bundle", "versioning + Object Lock,<br>read-only for upper")
a3 = p.icon("run", "jenkins", 3, ROW1, "3. Upper runner", "download, verify,<br>compare, reject drift")
a4 = p.icon("cc", "codecommit", 4, ROW1, "4. CodeCommit PR", "one pull request<br>per cluster repo")
a5 = p.icon("ar", "argo", 5, ROW1, "6. Argo CD", "syncs main inside<br>the sync window")
a6 = p.icon("ek", "eks", 6, ROW1, "EKS", "cluster")
a7 = p.icon("rev", "user", 4, ROW2, "5. Reviewer", "approves and merges<br>in a CyberArk session")
p.arrow("1", a1, a2); p.arrow("2", a2, a3, label="pull, IAM only"); p.arrow("3", a3, a4); p.arrow("4", a4, a5); p.arrow("5", a5, a6)
p.up("6", a7, a4, "approve")
p.pros_cons(860, ["Reuses most of seed-cluster-repo.sh", "One mechanism for seed and update", "No upper-to-GitLab connectivity", "Easy to audit and roll back", "Minimal change to the architecture"],
            ["Large updates give hard-to-review pull requests", "Whole-tree replace can overwrite emergency changes", "Needs a runner in upper and a controlled S3 path"],
            ["Add an output-directory mode to the script", "Render one pref-dev cluster", "Output must match the existing repo", "Test verify, drift detection, PR creation"])

# ---------------------------------------------------------------- page 3: option B
p = Page(3, "3 Option B OCI charts")
p.title("Option B: OCI Helm charts in ECR + thin cluster repository", "Recommended as the longer-term architecture. Promotion = a version pin changed by pull request.")
p.zone("lower", "LOWER", 60, 455, h=600)
p.zone("upper", "UPPER", 530, 890, h=600, color="#2E7D32")
b1 = p.icon("ci", "gitlab", 0, ROW1, "1. GitLab CI", "package each components/ chart<br>with a version")
b2 = p.icon("helm", "helm", 1, ROW1, "OCI Helm charts", "about 40 versioned<br>component charts")
b3 = p.icon("ecr", "ecr", 2, ROW1, "2. ECR", "shared charts,<br>immutable tags")
b4 = p.icon("ar", "argo", 3, ROW1, "4. Argo CD", "ApplicationSet with two sources:<br>chart + values")
b5 = p.icon("ek", "eks", 4, ROW1, "EKS", "cluster")
b6 = p.icon("cc", "codecommit", 3, ROW2, "3. Thin CodeCommit repo", "cluster values, bootstrap,<br>chart version pins")
b7 = p.icon("rev", "user", 2, ROW2, "5. Reviewer", "version-pin pull request,<br>CyberArk session")
p.arrow("1", b1, b2); p.arrow("2", b2, b3, label="push"); p.arrow("3", b3, b4, label="chart"); p.arrow("4", b4, b5)
p.up("5", b6, b4, "values + pins"); p.arrow("6", b7, b6)
p.pros_cons(860, ["Much less duplicated GitOps content", "Many updates become one-line version changes", "Easier review, approval and rollback", "Independent releases per cluster", "Fits per-stage pinning (COINT-21582)"],
            ["ApplicationSet design must change", "About 40 components to package and version", "Chart and values compatibility needs schemas", "Depends on approval of the ECR publishing path", "Cluster values still need a promotion path"],
            ["Pick one stateless component in pref-dev", "Convert it to an OCI chart", "Configure multi-source Argo CD", "Rendered manifests must be identical"])

# ---------------------------------------------------------------- page 4: option C
p = Page(4, "4 Option C CodeBuild")
p.title("Option C: upper-owned CodeBuild promotion", "Recommended automation option if CodeBuild is approved in upper. Same bundle format as option A.")
p.zone("lower", "LOWER", 60, 455, h=600)
p.zone("upper", "UPPER", 530, 1610, h=600, color="#2E7D32")
c1 = p.icon("ci", "gitlab", 0, ROW1, "1. GitLab CI", "publish versioned,<br>signed bundles")
c2 = p.icon("s3l", "s3", 1, ROW1, "S3 lower", "lower-owned bucket")
c3 = p.icon("s3u", "s3", 2, ROW1, "2. S3 upper", "only the replication<br>role can write")
c4 = p.icon("eb", "eventbridge", 3, ROW1, "3. EventBridge", "object created event")
c5 = p.icon("cb", "codebuild", 4, ROW1, "4. CodeBuild", "verify signature, check drift,<br>update permitted files")
c6 = p.icon("cc", "codecommit", 5, ROW1, "5. CodeCommit PR", "per cluster repo")
c7 = p.icon("ar", "argo", 6, ROW1, "Argo CD", "syncs main inside<br>the sync window")
c8 = p.icon("ek", "eks", 7, ROW1, "EKS", "cluster")
c9 = p.icon("rev", "user", 5, ROW2, "6. Reviewer", "reviews and merges<br>in a CyberArk session")
p.arrow("1", c1, c2); p.arrow("2", c2, c3, label="one-way replication"); p.arrow("3", c3, c4); p.arrow("4", c4, c5)
p.arrow("5", c5, c6); p.arrow("6", c6, c7); p.arrow("7", c7, c8); p.up("8", c9, c6, "approve")
p.pros_cons(860, ["Upper controls every CodeCommit write", "No laptop dependency", "No extra GitLab connectivity from upper", "IAM scoped per cluster and repository", "Event-driven, auditable, repeatable"],
            ["Needs CodeBuild and IAM approval in upper", "More Terraform, S3 events and monitoring", "The pull request still needs a readable diff", "More initial infrastructure than option A"],
            ["Confirm CodeBuild is allowed in upper", "One test project with narrow IAM", "Scratch CodeCommit repo, non-production", "Validate PR creation, drift, rollback"])

# ---------------------------------------------------------------- page 5: option D
p = Page(5, "5 Option D Terraform")
p.title("Option D: Terraform-owned cluster configuration", "Alternative architecture, for discussion only. No per-cluster writable CodeCommit repository.")
p.zone("lower", "LOWER", 60, 455, h=600)
p.zone("upper", "UPPER", 530, 1130, h=600, color="#2E7D32")
d1 = p.icon("gl", "gitlab", 0, ROW1, "1. Terraform repo", "cluster Argo CD values,<br>merge request")
d2 = p.icon("ci", "helm", 1, ROW2, "OCI Helm charts", "shared components,<br>versioned")
d3 = p.icon("atl", "atlantis", 2, ROW1, "3. Atlantis", "the one upper component<br>allowed to reach GitLab")
d4 = p.icon("tf", "terraform", 3, ROW1, "Terraform", "plan and apply,<br>owns the Applications")
d5 = p.icon("ar", "argo", 4, ROW1, "Argo CD", "Applications created<br>by Terraform")
d6 = p.icon("ek", "eks", 5, ROW1, "EKS", "cluster")
d7 = p.icon("ecr", "ecr", 4, ROW2, "2. ECR", "shared charts")
d8 = p.icon("rev", "user", 0, ROW2, "Reviewer", "approves the Terraform<br>merge request")
p.arrow("1", d1, d3, label="plan on merge request"); p.arrow("7", d2, d7, label="push"); p.arrow("2", d3, d4); p.arrow("3", d4, d5); p.arrow("4", d5, d6)
p.up("5", d7, d5, "chart"); p.up("6", d8, d1, "approve")
p.pros_cons(860, ["Reuses an existing approval and audit process", "Less repository synchronisation", "No separate promotion process for this configuration"],
            ["Significant architectural change", "Gives up one repository per cluster", "Rework of ownership and Argo CD integration", "Not a short-term replacement for MR 22"],
            ["None planned", "Keep as a discussion option"])

# ---------------------------------------------------------------- page 6: comparison
p = Page(6, "6 Final options comparison")
p.title("Final options comparison", "Recommendation: A first, then C and B. The options are not exclusive: A = how the artifact is promoted, C = who runs it in upper, B = how much has to cross.")
rows = [
    ["Criteria", "A: S3 bundle", "B: OCI + thin repo", "C: CodeBuild", "D: Terraform"],
    ["Main purpose", "Secure artifact promotion", "Reduce GitOps duplication", "Automate upper promotion", "Remove separate promotion model"],
    ["Architecture changes", "Low to medium", "High", "Medium", "Very high"],
    ["Implementation effort", "Medium", "High", "Medium", "High"],
    ["Reuse existing script", "High", "Partial", "High", "Low"],
    ["Seed and update", "Yes", "Yes, with configuration promotion", "Yes", "Different model"],
    ["Human approval", "CodeCommit PR", "Version-pin PR", "CodeCommit PR", "Terraform MR"],
    ["Upper GitLab access", "Not needed", "Not needed", "Not needed", "Depends on approved artifact path"],
    ["Laptop dependency", "No in target design", "No in target design", "No", "No in target design"],
    ["Security boundary", "Strong, upper-controlled retrieval", "Depends on ECR access controls", "Strong, upper-owned", "Depends on Atlantis permissions"],
    ["Review complexity", "Medium to high", "Low for chart version updates", "Medium to high", "Medium"],
    ["Rollback", "Restore previous bundle", "Revert chart version", "Restore previous bundle", "Revert Terraform change"],
    ["Main risk", "Large diffs and drift", "Chart and values compatibility", "Upper service approval", "Architectural disruption"],
    ["Best use", "Immediate solution", "Long-term simplification", "Automated execution", "Future redesign"],
    ["Recommendation", "Implement first", "Pilot after A", "Add when approved", "Keep as discussion option"],
]
colfill = [GREY, GREEN, BLUE, YEL, "#FFFFFF"]
cells = []
for y, r in enumerate(rows):
    for x, v in enumerate(r):
        fill = "#CFD8DC" if y == 0 else (colfill[x] if (x == 0 or y in (13, 14)) else "#FFFFFF")
        cells.append({"xPosition": x, "yPosition": y, "text": v, "style": {"fill": {"type": "color", "color": fill}}})
p.shapes.append({"id": "p6_table", "type": "table", "boundingBox": {"x": 60, "y": 150, "w": 1800, "h": 780},
                 "rowCount": len(rows), "colCount": 5, "cells": cells})
p.box("ph1", 60, 1010, 520, 150, "Phase 1: deliver option A",
      ["keep per-cluster CodeCommit; split MR 22 into render and publish;", "bundle + verification, rendered diff, drift protection;", "validate on one pref-dev cluster"], GREEN)
p.box("ph2", 700, 1010, 520, 150, "Phase 2: evaluate option C",
      ["ask approval for upper-owned CodeBuild;", "reuse the bundle and verification of A;", "replace the temporary upper step with an automated runner"], YEL)
p.box("ph3", 1340, 1010, 520, 150, "Phase 3: introduce option B",
      ["move shared components to OCI charts step by step;", "cluster values stay in CodeCommit;", "promotions shrink to small version changes"], BLUE)
p.arrow("1", "p6_ph1", "p6_ph2"); p.arrow("2", "p6_ph2", "p6_ph3")

# ---------------------------------------------------------------- page 7: controls, avoid, questions
p = Page(7, "7 Controls, avoid, questions")
p.title("Mandatory controls, options to avoid, open questions", "Controls apply to every option. Status: design evaluation only; nothing implemented, deployed or approved.")
ctl = [("Human approval", "no automatic merge into production"), ("Reviewable diff", "meaningful before and after, not file replacements"),
       ("Drift protection", "refuse an update when upper was changed unexpectedly"), ("Integrity", "verify checksums and signatures before promotion"),
       ("Least privilege", "a promotion role updates only its repository and paths"), ("Rollback", "known-good version and a documented recovery"),
       ("Traceability", "source commit, bundle version, target cluster, approval"), ("Environment promotion", "production never gets an unvalidated version")]
p.text("h1", 60, 140, 800, 40, '<p style="font-size:18px;text-align:left"><b>Mandatory controls for any option</b></p>')
for n, (h, l) in enumerate(ctl):
    p.box(f"ctl{n}", 60 + (n % 4) * 460, 200 + (n // 4) * 170, 400, 110, h, [l], GREEN)
p.text("h2", 60, 560, 800, 40, '<p style="font-size:18px;text-align:left"><b>Options we should avoid</b></p>')
avoid = [("Atlantis as a file courier", "Terraform local-exec pushing large repositories mixes infrastructure with artifact transport"),
         ("In-cluster repository writer", "a production workload that can change its own source of truth"),
         ("OCI content instead of CodeCommit", "removes the pull-request approval workflow"),
         ("Manifest-only rebuild in upper", "extra complexity without enough benefit")]
for n, (h, l) in enumerate(avoid):
    p.box(f"av{n}", 60 + n * 460, 620, 400, 130, h, [l], REDF)
p.text("h3", 60, 830, 800, 40, '<p style="font-size:18px;text-align:left"><b>Questions for Markuss and the team</b></p>')
qs = ["1. Lower publishes immutable artifacts and upper owns repository writes: agreed?",
      "2. Is AWS CodeBuild approved for use in upper?",
      "3. Can the existing ECR publishing path carry OCI component releases?",
      "4. Refactor MR 22 before approval, not merge it with laptop-dependent behaviour?",
      "5. Who owns the final upper approval, and how do we merge while CyberArk is on hold?"]
for n, q in enumerate(qs):
    p.box(f"q{n}", 60, 890 + n * 90, 1780, 60, q, [], YEL)

print(json.dumps({"version": 1, "pages": pages}, separators=(",", ":")))
