---
name: lucid-aws-architecture-diagram
description: Use when asked to draw an architecture diagram in Lucid (lucid.app / Lucidchart), especially an AWS-style one with real AWS icons (EKS, ECR, IAM, Secrets Manager) plus Argo CD, Helm or GitLab logos, or when a Lucid diagram "overlaps", "looks messy" or must be reorganized. Covers the Lucid MCP create-from-specification flow, the generator script, label rules that stop overlaps, and the checks to run.
---

# Lucid AWS-style architecture diagram (built 2026-10-13, ECR access diagram)

Memory: `lucid-mcp-setup`, `feedback-architecture-diagram-zone-layout`. Example output: ECR Helm charts access (GENESIS-429536).

## Flow
1. Load the Lucid tools with ToolSearch (`get_mcp_resource`, `lucid_create_diagram_from_specification`, `lucid_validate_diagram_specification`, `lucid_export_document_as_PNG`, `lucid_update_document`).
2. Read `lucid://skills/readme` and `lucid://skills/diagram-specification` BEFORE the first create (the create tool requires it). AWS class names: `lucid://shape-libraries/aws-2024/common` and per category (`containers`, `security-identity-and-compliance`, ...). Do not guess class names.
3. Generate the Standard Import JSON with `gen_lucid_aws_diagram.py` (this folder; edit the rows, boxes, lines, then `python3 -I gen_lucid_aws_diagram.py > spec.json`). Computing coordinates in a script keeps arrows level and the ECR attach points (fractions of the target box height) correct.
4. Create with `use_assisted_layout: false` when you place everything yourself (zones, nested containers). The create call returns `input_preflight` (errors block nothing but report containment).
5. ALWAYS `lucid_export_document_as_PNG` and look. Fix and recreate until nothing overlaps.

## Rules that stopped overlaps
- **AWS `namedShape` draws its own default label** (for example "Role", "AWS Identity and Access Management (IAM)"). Set `text` on the shape to REPLACE it, and keep it to a short title. Put long names (role names, user names) in a separate `text` shape under it (about 34 px below the icon).
- **Give every text an explicit `font-size`** (`<p style="font-size:16px;text-align:center">`). Without it Lucid autoscales each box differently and the diagram looks uneven. Titles 16, details 14, big list 18.
- Icons and boxes of one row share the same centre y so straight arrows are horizontal. Pin BOTH line endpoints (`position`) or neither.
- Containers: leave the top 40 px for the title (`containerTitle`, or `text` on `namedContainer`). Keep icons and their labels out of the title band and out of the region title ("us-west-2" sits top-left). Text boxes must be narrower than the container interior (containment errors).
- Distinct connector labels ("pull via role", "pull via key"); duplicate labels on neighbouring lines are flagged.
- AWS containers: `namedContainer` with `className` `AWSCloudAWS2024` and `RegionAWS2024`.

## Logos (non-AWS)
Image shapes need `image.url` (https) and a top-level `stroke`. Verify each URL first with `curl -sI` (200 + `image/png`). Working: Argo `https://raw.githubusercontent.com/cncf/artwork/main/projects/argo/icon/color/argo-icon-color.png`, Helm `.../projects/helm/icon/color/helm-icon-color.png`, GitLab `https://commons.wikimedia.org/wiki/Special:FilePath/GitLab_icon.svg?width=240` (CNCF artwork has no GitLab; SVG URLs such as simpleicons are not safe). Images carry no text: add a separate label shape.

## Limits of the Lucid MCP (2026-10-13)
- **Edit in place (verified 2026-10-15):** `lucid_load_script_documentation(document_id, name='basecanvasediting')`, then `lucid_run_script` with `skills.basecanvasediting.navigateToPage('p1')`, `moveBlock`, `resizeBlock`, `deleteItem`, `editLineEndpoint({lineId, endpoint:'from', value:{kind:'block', blockId, connection:{x,y}}})`, end with `validateCanvas(...)`. Import ids are kept, so fix overlaps by script; recreate only for big layout changes. Label `position` on a line cannot be edited: move the endpoint instead.
- Still no tool deletes a document. If you recreate, rename the old one `OLD DRAFT n (delete)` and tell the user.
- Ids must be unique across ALL pages (a `title` id on every page fails with `duplicate-id`).
- Don't put secret-looking text in labels (`token = X`): Bash output masks it and you must type the JSON into the call; grep the spec for `REDACT` before copying.
- The share link is a separate call (`lucid_create_document_share_link`); documents are private until the user asks.
- Posting the link to Jira is the user's job (hard rule); hand back a paste-ready comment.

## Kubernetes + product icons (verified 2026-10-19, Nexus diagram 8821c7fa)
- Lucid has NO Kubernetes or product library. Use image shapes (all checked 200 image/png):
  - k8s resources: `https://raw.githubusercontent.com/kubernetes/community/master/icons/png/resources/labeled/<pod|sts|pvc|secret|job|sa|svc|ns|cm|pv>-128.png`
  - CNCF: `https://raw.githubusercontent.com/cncf/artwork/main/projects/<kubernetes|argo|helm|istio>/icon/color/<name>-icon-color.png`
  - products: `https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/<nexus|postgresql|hashicorp-vault|gitlab|docker|jenkins|microsoft-windows>.png` (check names in `.../metadata.json`; `nexus` alias nexus3 = Sonatype Nexus)
  - External Secrets `https://raw.githubusercontent.com/external-secrets/external-secrets/main/assets/eso-logo-large.png`, Atlantis `https://raw.githubusercontent.com/runatlantis/atlantis/main/runatlantis.io/public/hero.png`
- AWS: CodeConnections has no shape; use `ArchAWSCodeStarAWS2024` (CodeConnections = renamed CodeStar Connections). RDS PostgreSQL = `ResAmazonAuroraPostgreSQLInstanceAWS2024`, TGW `ArchAWSTransitGatewayAWS2024`.
- One caption text shape per icon (title 15 px bold + detail 12 px) halves the shape count; attach DOWNWARD lines to the caption's bottom (`<id>t`), not the icon, or the arrow runs through its own caption.
- `containerTitle` draws a tab ~50 px ABOVE the container (footprint y = box y - 50): keep headings above that or they get covered.
- Line ids share the namespace with shapes (`p1_s3` line vs `p1_s3` shape = duplicate-id 400): prefix lines (`p1_L...`).
- ~45 KB spec is fine to pass inline; fix small things after creation with basecanvasediting (moveBlock, resizeBlock, editLineEndpoint) instead of recreating.
- Example generator: `gen_nexus_eks_example.py` (3 pages: architecture, sync order, identity/secrets).
