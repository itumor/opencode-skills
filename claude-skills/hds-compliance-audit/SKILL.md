---
name: hds-compliance-audit
description: Use when asked to audit infra against the HDS (Hebergeur de Donnees de Sante, French health-data hosting) compliance spreadsheet, "HDS audit", "which HDS rows are compliant", "confidence score per requirement", or to compare a compliance Google Sheet against Terraform/Ansible/live AWS and deliver a PDF. Read-only multi-subagent audit (terraform, ansible, live AWS) merged into one verdict+confidence per REQ. ALWAYS name the environment/repo in scope (CAA upper = prod+stage+share) - lower does not carry HDS.
---

# HDS compliance audit (sheet vs Terraform / Ansible / live AWS) -> PDF

Reference run 2026-10-15: Crédit Agricole Assurances (CAA). Sheet "April 2026 HDS Unique Controls for Implementation"
(id `1rup0D91g6j2roO_YHD8AUiyO5s_JSlp5kgsqDrGBM_4`, read-only, 31 REQs). Outputs: `iac/docs/hds-audit-caa-2026-10-15.pdf` (both accounts, first pass, too noisy)
and `iac/docs/hds-audit-caa-upper-2026-10-15.pdf` (upper only, the one to reuse). Findings snapshot: memory `hds_audit_caa_upper_2026_10_15`.

## 0. Scope first (user feedback, 2026-10-15)
Pin the target before any agent starts: **account + region + environments + repos**. CAA: `upper` = account 144905517910, eu-west-3, stage + prod + share (this is HDS);
`lower` = 691064586749, us-west-2, dev/test/infra (NOT HDS, exclude; keep only as "change path" if it applies upper, e.g. the Atlantis host). Another client = ask which env carries health data.

## 1. Get the sheet (Google Drive MCP, read-only)
- `read_file_content` returns only a sample of each tab: not enough.
- `download_file_content` with `exportMimeType: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` returns JSON `{content: <base64>}` saved to a tool-results file when large.
  `jq -r .content <file> | base64 -d > dl/hds.xlsx` then `python3 -I` + openpyxl (`data_only=True`) dumps every tab to JSON. csv export = first tab only, also base64.
- Put the xlsx in its own dir (`dl/`), keep scripts elsewhere, run python with `-I` (untrusted download rule).
- Tabs: `1. HDS → ISO 27001 Mapping`, `REQ13` (shared-responsibility matrix, 13 technical claims = best audit target), `HDS Controls Tracker` (status, %, notes per REQ), `Dashboard`, `Sheet5`.

## 2. Triage the 31 REQs
Infra-testable (13): 04 backups, 05 risk events A-H, 13 matrix rows 1-13, 14/22 processors, 15/16 access traces, 23 access methods, 24 change control, 27 reversibility, 28 EEA residency, 29 non-EEA remote access, 30 foreign-law/keys.
Not provable from infra (18, list with sheet status, do NOT score): 01-03, 06-12, 17-21, 25, 26, 31 (contract/legal/HR/training/governance).

## 3. Subagents (read-only, parallel, background)
Write one shared brief (template: `BRIEF.template.md` next to this file) + the requirements JSON to the scratchpad. Launch three at once:
| name | agent type | scope |
|---|---|---|
| tf | general-purpose | terraform + argocd, `origin/main` code, pinned eis-* module tags |
| ansible | general-purpose | ansible repo + unmerged upper branches (`git show origin/<branch>:path`) |
| live | iac-live-verifier | AWS read-only, ReadOnly SSO profile, 17-region sweep, KMS origin, S3/RDS/EKS/CloudTrail/Backup/GuardDuty/Config/Inspector/IAM |
Each writes `evidence/<name>.json` (schema in the brief: req, aspect, verdict COMPLIANT|PARTIAL|NON_COMPLIANT|NO_EVIDENCE, confidence 0-100, envs, evidence[], gaps[]) and returns <=25 lines.
Cost reference: ~650k subagent tokens for the 3-agent pass; ~130k for a time-boxed upper-only delta pass.
Then a **delta pass** (one iac-live-verifier) for items the first pass skipped; see the item list in memory `hds_audit_caa_upper_2026_10_15`.

## 4. Merge + score
- Live result decides the verdict, code explains the cause. Verdict at REQ level = PARTIAL if any decisive sub-aspect is partial or worse; REQ conf = lowest decisive sub-aspect.
- Confidence = sure-ness from data seen, not a compliance %. 80-100 live-confirmed; 50-79 code + partial live; <50 inference / outside readable scope. "Guaranteed" = COMPLIANT + conf>=80.
- Show sheet status vs audit (tracker "Complete" mostly = documents drafted, say so). Always include a "what holds up" box and a limits section.
- Matrix claims that came out false in CAA: "exclusively EEA regions" (lower), "CMK via external HSM" (all keys Origin=AWS_KMS), "continuous vuln scanning" (Inspector EC2 off), least-privilege+MFA only partly provable.

## 5. PDF (no reportlab/weasyprint/wkhtmltopdf on this Mac)
Python builds HTML (`build_report_example.py` = the upper-only generator: ROWS tuples + delta merge + CSS), then:
```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf=<out.pdf> file://<abs>/report.html
pdftoppm -r 80 -f N -l N -png <out.pdf> <prefix>      # visual check; then Read the PNG with offset:0 limit:300
```
Save PDF under `iac/docs/` (session folder) and send with SendUserFile. Read tool on the PDF itself is blocked by the 350-line hook: render PNG instead.

## Gotchas
- **prod-guard**: any command text containing a `/prod/` path is denied (also for subagents). Do not work around; prod facts come from live AWS + design ADRs (mark ADR as intent, not proof). Offer `/guards` or a user-run snippet if prod TF is essential.
- **SSO expires mid-run** (~17-20 min into the live agent). Tell live agents to run ALL read calls in one early script, save raw output, record coverage gaps, never `aws sso login`. Re-run of the missed checks needs the user to log in.
- Management account (SCPs, IdC assignments, MFA) and EIS hub account (TGW routes) are unreadable from CAA profiles: those rows stay NO_EVIDENCE / inference. Say so in the limits.
- Some KMS key policies deny DescribeKey to ReadOnly: origin unverified, report count.
- Do not `rm -f dir/*` scratch PNGs: Blast Radius holds multi-file deletes. Overwrite the same filenames.
- Do not print secret values/env var values; list key names only.
- Never claim certification; scores are auditor estimates.
