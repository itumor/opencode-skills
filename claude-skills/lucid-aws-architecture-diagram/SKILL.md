---
name: lucid-aws-architecture-diagram
description: Use when asked to draw an architecture diagram in Lucid (lucid.app / Lucidchart), especially an AWS-style one with real AWS icons (EKS, ECR, IAM, Secrets Manager) plus Argo CD, Helm or GitLab logos, or when a Lucid diagram "overlaps", "looks messy" or must be reorganized. Covers the Lucid MCP create-from-specification flow, the generator script, label rules that stop overlaps, and the checks to run.
---

# Lucid AWS-style architecture diagram (built 2026-10-13, ECR access diagram)

Memory: `lucid-mcp-setup`, `feedback-architecture-diagram-zone-layout`. Example output: ECR Helm charts access (GENESIS-429536).

## Flow
0. **Search before you build.** "Give me the Lucid diagram" usually means one already exists (2026-10-20: started a new ECR diagram, user said "we have one somewhere", it was 5be91c12). Run the Lucid `search` tool with topic keywords (it lists `OLD DRAFT n (delete)` copies too, skip those) and grep memory for `lucid.app/` + the ticket key. Hand back the existing link; build only if none fits or the user asks for new.
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

## Method comparison deck (verified 2026-10-27, COINT-21594 doc aa6b9666)
- Example generator `gen_methods_comparison_example.py`: page 1 = Standard Import `table` (rowCount/colCount/flat `cells` with per-cell fill) + recommendation boxes; one page per method via a `method_page()` helper (icons row + Result/Pros/Cons/Verdict boxes); last page = side path (image pulls).
- Rectangle text is vertically centred: size note boxes to the text (~170 px for 3-4 lines at 13 px), or they look empty.
- Keep a flow's actor next to its IAM role; a line that runs past another icon on the same row crosses it. Put the Secret/actor/consumer in an L, not one row.
- A `containerTitle` tab (~50 px above) covers captions of icons placed just above the container: leave 60 px or move the container down.
- Bash output also redacts `SecretSynced=False`-style text (word + `=`), and the redaction leaks into JSON you copy from it. Reword before generating; grep `REDACT` after.
- Export each page PNG into the repo docs folder for Jira; build the doc as HTML with relative `<img>` and print to PDF with headless Chrome (`--print-to-pdf`, `--no-pdf-header-footer`).

## Identity / SSO diagram (verified 2026-10-29, COINT-21591 doc 3e6180a4)
- Icons (200 image/png): Keycloak `https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/keycloak.png`, Active Directory stand-in `.../png/windows-11.png` (`microsoft-windows.png` is 403; no AD icon), Entra `.../png/entra-id.png`, user `https://raw.githubusercontent.com/kubernetes/community/master/icons/png/resources/labeled/user-128.png` (no AWS "user" class in aws-2024/common).
- Remove a colliding line label in place: `basecanvasediting.setText({itemId: '<line id>', text: ''})`. Add a missing arrow: `createLine({from:{kind:'block',blockId,connection:{x,y}}, to:{kind:'block',blockId:'<container id>',...}, label, shape:'diagonal'})` (containers are valid endpoints).
- `resizeBlock` on a `table` widens all columns evenly (ColumnWidths not settable via basecanvasediting): keep evidence text short or accept clipping and put the full table in the PDF.

## Two-method side-by-side page (verified 2026-11-01, COEXT-111852 doc dd1467bc)
- One page, two `rectangleContainer` panels (A orange, B green), each with user icon + AWS cloud `namedContainer` + note box, comparison `table` below, recommendation box last.
- AWS classes: WorkSpaces `ArchAmazonWorkSpacesAWS2024`, Managed AD `ResAWSDirectoryServiceAWSManagedMicrosoftADAWS2024`, AD Connector `ResAWSDirectoryServiceADConnectorAWS2024`, Simple AD `ResAWSDirectoryServiceSimpleADAWS2024`, S2S VPN `ArchAWSSitetoSiteVPNAWS2024`, Directory Service `ArchAWSDirectoryServiceAWS2024`.
- A line label at 0.5 on a line that crosses a container border lands ON the border: leave that hop unlabeled (`setText` '' on the line) or move the label.
- Rectangle text renders centered even with `text-align:left` in the HTML; accept it or use a `text` shape inside.
- Preflight warns icon-vs-own-caption (<60 px) and container-padding <80 px on every icon: expected with this layout, judge by the PNG export.

## Plain flowchart of a script or code path (verified 2026-11-12, doc 2176067a, clusters !22)
- Example generator `gen_flowchart_example.py`: three columns (inputs left x=40, flow centre x=440, exits/results right x=900), one row per step, row pitch 180. Shapes: `terminator` start/end/stop, `process` step, `decision`, `database`/`document` inputs and results, `note` for a side remark.
- Came out clean on the first create with `use_assisted_layout: false`: every box has explicit font sizes (title 15 bold, detail 13), all straight lines pin both endpoints (bottom->top, right->left), only the two "rejoin" arrows are `elbow`.
- Colour by role and say so in the subtitle (blue step, yellow decision, grey input, green result, red stop): the reader gets the legend without a legend box.
- Decision exits: label the side exit `side: top`, the downward exit `side: bottom`; keep side-exit labels to 1-2 words (120 px gap fits about 10 characters; longer ones raise `line-label-span`).
- Text: no `<` `>` raw, use `&lt;` `&gt;`; keep box detail to two short lines.
- The connector named `lucid` in the MCP list may show "needs authentication" while the claude.ai Lucid connector tools (`mcp__<uuid>__lucid_*`) work: try those first.
- The spec (~17 KB) must be typed into the tool call: generate to a file, Read it, paste.

## Tool evaluation deck: as-is, landscape, capability matrix, score bars, target, fit table (verified 2026-11-24, doc af66871b)
- Example generator `gen_tool_eval_deck_example.py` (`--selftest`): 6 pages. Landscape = 4 columns of coloured verdict boxes with a 44 px logo in the box corner; matrix = one `table` whose cell fill comes from the WORDING (`cell_fill()`: free = green, add-on/plugin/workaround = amber, paid/none = red); score page = one rectangle per tool with `w = score * 10`; fit table + recommendation / do-now / POC boxes + open-question boxes.
- Clean on the first create at 67 KB via a general-purpose subagent (2 min). If the session restarts mid-create, `search` by title before relaunching: the first agent may or may not have created the doc.
- Keyword colouring trap: "Yes (credential plugin)" turned amber because of the word "plugin". Check the legend words against every cell before generating.
- **Table cells cannot be edited by script** (`inspect` shows only Text/ColumnWidths/RowHeights/FillColor for the whole table): a wrong cell colour means regenerate or fix by hand.
- Line labels sit on container borders when the line crosses one: clear them with `setText({itemId:'<line id>', text:''})` and let the icon caption carry the meaning.
- A text label inside a container top-left gets crossed by any arrow entering from above: keep it under about 250 px wide (`resizeBlock`) or enter from the side.
- Logos (200 image/png): dashboard-icons `awx`, `ansible`, `semaphore`, `rundeck`, `kestra`, `apache-airflow`, `jenkins`, `gitlab`, `argo-cd`, `keycloak`, `hashicorp-vault`, `oracle`, `docker`; org avatar `https://github.com/<org>.png?size=200` (used for CIQ). 404/403: `windmill`, `foreman`, `stackstorm`, `cyberark`, `argo-workflows`.
- AWS classes used: `ArchAWSSystemsManagerAWS2024`, `ArchAWSSecretsManagerAWS2024`, `ArchAWSIAMIdentityCenterAWS2024`, `ArchAmazonRDSAWS2024`, `ResElasticLoadBalancingApplicationLoadBalancerAWS2024`.
- Put the data source and "not re-verified" in each page subtitle when the facts come from someone's research document.
- Share link: `lucid_create_document_share_link(role='view')`, default `restrict_to_account: true`; only when the user asks.

## Multi-page options deck: problem, one diagram per option, comparison table (verified 2026-11-16, doc f3668e5a)
- Example generator `gen_options_deck_example.py`: 7 pages from one `Page` class (`icon`, `arrow`, `up`, `box`, `pros_cons`, `zone`). Per option page: LOWER and UPPER `rectangleContainer` zones, a row of icons with captions, arrows across the border, then three boxes below (Advantages, Disadvantages, First POC). Comparison page = `table` + a 3-phase flow of boxes.
- Shapes used (all rendered): AWS `ArchAmazonSimpleStorageServiceAWS2024`, `ArchAmazonElasticContainerRegistryAWS2024`, `ArchAWSCodeCommitAWS2024`, `ArchAWSCodeBuildAWS2024`, `ArchAmazonEventBridgeAWS2024`, `ArchAmazonElasticKubernetesServiceAWS2024`; images (200 image/png) GitLab, Jenkins, Argo, Helm, Atlantis, Terraform, user (URLs in the generator).
- **A spec over ~40 KB cannot be pasted from the main session** (the 52 KB spec took a subagent): spawn a general-purpose agent, tell it to load `lucid_create_diagram_from_specification` + `get_mcp_resource` with ToolSearch, read `lucid://skills/diagram-specification`, `Read` the spec file with `allow_large`, and pass its content verbatim; it returns documentId + preflight rule names. First call succeeded.
- Compact the JSON first (`separators=(",", ":")`) and drop optional `stroke`/`assistedLayout: false` keys that equal the defaults.
- Arrow labels land on a container border when the arrow crosses it: cosmetic, mention it in the hand-back.
- Page-by-page `lucid_export_document_as_PNG` in one batch (4 calls) is enough to check; save the PNGs next to the ticket docs.

## Extending an existing Lucid document (script API, learned 2026-11-24)

Use when the ask is "add a page / option to this Lucid doc" or "update the comparison table". Tools: `lucid_load_script_documentation` (`basecanvasediting`, then `pages`, `tables`, `text`, `images` as needed) + `lucid_run_script`. The `lucid` server may be listed as "needs authentication" while the UUID-named Lucid connector tools work - try `lucid_get_document_metadata` before reporting it unavailable.

1. Read first: `getPages()` in its own script, then `read({})` per page; note the document `version` from metadata (rollback point for the user).
2. New page in the same style: `skills.pages.addPage({title})`, `setPageOrder([...])`, then from the closest sibling page `copyPasteItems({itemIds, destinationPageId})` and use the returned `idMap`. Never start with plain `createBlock` boxes when sibling pages have icons and containers. Renumber later page titles with `setTitle`; page ids do not change.
3. Rewrite text with `setText`. Trap: `setText` drops rich text (bold first line, per-line font sizes) and the text renders large. Re-apply: `skills.text.setItemTextStyle` (small size, bold false) then `setPartialTextStyle` on the first line (bold + bigger). Read the sibling's real sizes with `skills.text.getItemTextStyle(id)` first (this doc: captions 6/5, boxes 7/6, title 12/7). Line labels: `setText` on the line id works and keeps its size.
4. Table needs a column: `createBlock` with `DefaultTableBlock` always gives 3x3. Use `skills.tables.create({rows, columns, columnWidths, cells, style:'headerRow'})` at the old table's x/y/size, then delete the old table (or `addColumn` + `setCells` on the existing one). Read old cell text from `inspect()` `properties.TextAreas` (`Cell_r,c`).
5. Swap an image icon: `skills.images.setSource(id, url, 'fit')` validates the URL through Lucid's proxy and throws on failure. A throw rolls back the WHOLE script, so try URLs in a separate script with try/catch per URL. Known good: `https://raw.githubusercontent.com/opencontainers/artwork/main/oci/icon/color/oci-icon-color.png` (OCI). Known bad: the cncf/artwork ORAS icon PNG path.
6. Lines: let Lucid route. A new line from a side note to an icon can cut through a neighbour icon (`lineThroughBlock`); for a note box prefer no line and say the relation in the text.
7. Verify: `validateCanvas` in the same script as the edits, then `lucid_export_document_as_PNG` for each edited page and LOOK at it. `blockOverlap` between an icon and its caption text block is normal on copied pages.
8. Script traps: `inspect()` results have no `labels` field for blocks (mapping it throws); process big reads inside the script and return compact data.

## Wiki diagrams, 4 pages, one document (verified 2026-11-17, doc 98ea9ca3, COINT-21712)
- `text: ""` on an AWS `namedShape` in the import spec does NOT remove the default label ("AWS Identity and Access Management (IAM)" drew over the caption). Fix after import: `basecanvasediting.setText({itemId, text: ''})` per icon (`getPages()` first, `navigateToPage(id)`; import ids are kept).
- `lucid_export_document_as_PNG` saves the PNG on disk (path in the tool result under the session `tool-results/`): copy it and attach to Confluence, no screenshot needed.
- A 30 KB spec: created through a general-purpose subagent that reads `spec.json` with `allow_large` and passes it verbatim; first call succeeded. Preflight `shape-clearance` / `container-padding` warnings for icon + caption layouts are expected: judge by the PNG.
- Flow page that came out clean: snake of 8 boxes in 2 rows (row 2 right to left), inputs above, outputs below, straight lines with both endpoints pinned.
- No AWS class needed for Organizations / Identity Center in `aws-2024/common`: plain rectangle or the IAM icon with a caption was enough.
