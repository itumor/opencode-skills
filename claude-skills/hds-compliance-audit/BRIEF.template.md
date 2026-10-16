# HDS audit brief (shared by all audit subagents). Fill the {…} slots.

Goal: test the technically verifiable HDS requirements against {CLIENT} infrastructure. READ-ONLY.
Never edit repo files, never terraform init/plan/apply, never git commit/checkout in the shared checkout, never `aws sso login`, never mutate AWS or k8s.
Evidence must be real: file:line, or the exact read-only command + key output. "Not found" claims need a repo-wide grep.

SCOPE (be explicit; out-of-scope accounts are not touched): {ACCOUNT_ID}, region {REGION}, environments {ENVS}. Repos: {REPO_PATHS}. Excluded: {EXCLUDED}.
Inputs: requirements + the sheet's claimed status `{SCRATCH}/hds_reqs.json`; REQ13 matrix `{SCRATCH}/hds_req13_matrix.json`.
Out of scope REQs (contract/legal/HR/training): 01-03, 06-12, 17-21, 25, 26, 31.

In-scope REQs and the technical question:
- REQ04 backups (incl. cross-region/outsourced) in IaC and covered?
- REQ05 risk events A media failure, B loss of control of media, C info-flow disruption, D access-control failure, E uncontrolled interventions, F unforeseen use, G HW/SW failure vs BCP, H non-EU legislation exposure: one entry each.
- REQ13 each of the 13 matrix rows: does infra enforce what the EIS column claims?
- REQ14/22 third-party processors visible (Datadog, CyberArk, Fivetran...): regions, HDS hints.
- REQ15/16 access traces: CloudTrail (multi-region, validation, KMS, lock, data events), pgaudit/log export, EKS audit, flow logs, edge logs, alerting, retention.
- REQ23 access methods: SSO/MFA, SSM/CyberArk, EKS RBAC, RDS IAM auth, static keys.
- REQ24 change control: Atlantis/MR gates, branch protection, CODEOWNERS.
- REQ27 reversibility: export paths, restore evidence, deletion vs Object/Vault Lock.
- REQ28 EEA residency of primary/backup/DR/logs/ECR/global services; region lock (SCP).
- REQ29 non-EEA remote access: TGW/VPN/CyberArk/geo restrictions.
- REQ30 foreign-law mitigations: CMK origin (EXTERNAL/XKS/CloudHSM), key custody, encryption coverage.

AWS: prefer ReadOnly SSO profile, always `--profile`, `--page-size` not `--max-results`. Run all calls in ONE early script and save raw output (SSO can expire mid-run); record AccessDenied/expired as coverage gaps.
Never print secret values, env var values or key material (key names only).

Output JSON to `{SCRATCH}/evidence/<NAME>.json`:
[{"req":"REQ28","aspect":"short label","verdict":"COMPLIANT|PARTIAL|NON_COMPLIANT|NO_EVIDENCE","confidence":0-100,"envs":"prod/stage/share","evidence":["file:line or cmd -> key output"],"gaps":["..."],"notes":""}]
Confidence = how sure from data actually seen (100 = live AND code; 50 = code only/partial env; <30 inference). NO_EVIDENCE = could not check, not the same as non-compliant.
Final message <=25 lines, caveman-terse: counts by verdict, 5 worst gaps, what you could not access. Do not paste the JSON.
