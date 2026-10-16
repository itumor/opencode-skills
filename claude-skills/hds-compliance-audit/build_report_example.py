import json, html, os, re
SP = os.path.dirname(os.path.abspath(__file__))
reqs = {r['REQ #'].replace(' ', ''): r for r in json.load(open(f'{SP}/hds_reqs.json'))}
E = html.escape
V = {'C': ('COMPLIANT', '#1a7f37'), 'P': ('PARTIAL', '#b7791f'), 'N': ('NON-COMPLIANT', '#c62828'), 'U': ('NO EVIDENCE', '#6b7280')}

def sheet(req):
    r = reqs.get(req)
    if not r:
        return '-'
    return r.get('Status', '-').replace("Complete/Waiting for Auditor's review", 'Complete (awaiting auditor)')

# (req, aspect, verdict, conf, src, seen, gaps, env)
ROWS = [
 ('REQ04', 'Backups in ISMS scope and managed in IaC', 'P', 80, 'T L',
  'AWS Backup vault aws11caasharevault, COMPLIANCE lock (min 30 d); daily 35 d / weekly 90 d / monthly 3 y plans; 39 recovery points; RDS prod + stage enrolled.',
  'No cross-region or cross-account copy. EKS state/PVCs, MSK, OpenSearch, prod S3 portals and most EC2 not enrolled. No Velero on prod EKS. Upper EC2 fleet carries no Backup tag in code.', 'prod stage share'),
 ('REQ05', 'A  Media failure', 'P', 80, 'T L',
  'Multi-AZ RDS cluster (3 members), 3-AZ EKS/MSK, deletion protection, Vault Lock backups.',
  'Single region eu-west-3, no DR copy, 0 restore jobs ever, MSK/OpenSearch/PVC not backed up.', 'prod stage'),
 ('REQ05', 'B  Loss of control of media', 'P', 80, 'T L',
  'EBS default encryption ON; RDS/S3/EBS encrypted; Vault Lock.',
  'Core stores on AWS-managed keys (aws/rds, aws/ebs, SSE-S3, backup vault). 10/17 prod volumes on aws/ebs. 1 unencrypted stage volume (prometheus PVC).', 'prod stage share'),
 ('REQ05', 'C  Information-flow disruption', 'P', 50, 'T L',
  'Internal ALB/NLB, CloudFront+WAF in front of portals, TGW hub egress, client PrivateLink.',
  'Single EIS hub TGW path (other account, not assessable). No CloudWatch alarms or EventBridge rules in CAA code.', 'prod stage'),
 ('REQ05', 'D  Access-control failure', 'P', 75, 'T L',
  '0 IAM users, SSO + CyberArk SCA/SIA roles, EKS private endpoint, RDS IAM auth, pod/node egress restricted.',
  'Prod MSK accepts unauthenticated clients. SSH/RDP to share hosts open from 10.0.0.0/8 + 192.168.0.0/16. Jenkins is cluster-admin on EKS. No AWS Config in prod.', 'prod stage share'),
 ('REQ05', 'E  Uncontrolled interventions', 'P', 70, 'T L',
  'CloudTrail (multi-region, validated, Object Lock 365 d), GuardDuty, EKS audit logs; Atlantis needs approved+undiverged.',
  'GitLab CE: no approval rules (self-approve possible), maintainers push to main, pipeline success not required. Prod AdministratorAccess applied from a us-west-2 Atlantis host.', 'prod stage share'),
 ('REQ05', 'F  Unforeseen use', 'P', 60, 'T L',
  'GuardDuty with S3 data, RDS login, EKS audit, EBS malware; CloudFront EU geo-whitelist.',
  'No DB read/write audit (pgaudit role,ddl only), no S3 data events, GuardDuty runtime off and not centrally aggregated for prod.', 'prod stage share'),
 ('REQ05', 'G  HW/SW failure vs BCP', 'P', 80, 'T L',
  'Multi-AZ, deletion protection, backups 35 d / 90 d / 3 y.',
  'No DR region, no restore testing, no Velero on prod EKS, upper clusters not in the ArgoCD repo (rebuild path not in GitOps).', 'prod stage'),
 ('REQ05', 'H  Exposure to non-EU legislation', 'N', 70, 'T L',
  'All upper workloads only in eu-west-3; no IGW; app PII envelope-encrypted with a CAA-owned key; CloudFront EU geo-whitelist.',
  'No external key control: all keys Origin=AWS_KMS, core stores on AWS-managed keys. Prod admin plane in the US (Atlantis us-west-2, Identity Center and org CloudTrail us-east-1).', 'prod stage share'),
 # REQ13
 ('REQ13', 'Row 1  Physical: "deployment exclusively in EEA regions"', 'C', 75, 'T L',
  '17-region sweep: every upper workload (RDS 6, EKS 2, MSK 2, OpenSearch 1, ECR 72, backups) is in eu-west-3.',
  'Outcome true; enforcement is not evidenced (no region-deny SCP observable, 17 regions enabled, SCPs unreadable). Global services sit in us-east-1 (CloudFront, ACM, WAF, Route53).', 'prod stage share'),
 ('REQ13', 'Row 2  Hardware infrastructure (AWS-owned)', 'C', 40, 'T', 'EIS claims no responsibility; only managed compute/storage used.', 'Nothing to verify at EIS layer.', 'all'),
 ('REQ13', 'Row 3  Hypervisor security (AWS-owned)', 'C', 40, 'T', 'EIS claims no responsibility; Nitro instance families used.', 'Nothing to verify at EIS layer.', 'all'),
 ('REQ13', 'Row 4  Virtual networking: VPC, private subnets, strict SGs, WAF geo', 'P', 80, 'T L',
  'All 4 LBs internal, EKS endpoint private, no IGW/NAT in workload VPCs, CloudFront WAF with 4 enforcing groups, EU geo-whitelist.',
  'SG sources are broad CIDRs (10/8, 192.168/16). WAF and CloudFront logging OFF. Flow logs on prod VPC only. CloudFront-only origin lock unverifiable.', 'prod stage share'),
 ('REQ13', 'Row 5  Host OS: continuous vuln scanning, hardening, auto-patching', 'N', 80, 'T L',
  'Inspector ECR on, but 2,061 critical / 23,845 high image findings untriaged.',
  'Inspector EC2 scanning disabled; 0/18 EC2 SSM-managed; no patch baselines or compliance data; no SSM Patch Manager by design. Upper host config exists only in unmerged Ansible branches, so hardening cannot be audited.', 'prod share'),
 ('REQ13', 'Row 6  Middleware: Kafka, DB, integration endpoints secured', 'P', 85, 'T L',
  'RDS: force_ssl, ssl_min_protocol_version TLSv1.3, IAM auth, not public, deletion protection. MSK: TLS client-broker + in-cluster, no public access.',
  'Prod MSK Unauthenticated.Enabled=true (SASL/IAM off); the SG is the only control.', 'prod stage'),
 ('REQ13', 'Row 7  Encryption at rest: EBS + S3 + app-level DEK', 'P', 85, 'T L',
  'EBS default encryption ON; S3 default SSE; RDS/MSK/OpenSearch encrypted.',
  'Mostly AWS-managed keys (prod RDS aws/rds; 10/17 prod volumes aws/ebs). 1 unencrypted stage volume. App-level DEK for C4 objects not verifiable from infra.', 'prod stage share'),
 ('REQ13', 'Row 8  Encryption in transit: TLS 1.2+', 'P', 80, 'T L',
  'CloudFront 11/11 TLSv1.2_2021, ALB TLS13-1-2-Res-2021-06 + HTTP redirect, RDS TLS1.3 minimum.',
  'No S3 policy enforces TLS version. Mesh mTLS not enforced in GitOps (Istio default PERMISSIVE); prod cluster unreachable to confirm.', 'prod stage'),
 ('REQ13', 'Row 9  IAM infra: least privilege, MFA, audit logging', 'P', 70, 'T L',
  '0 IAM users / 0 access keys; SSO-only admin; CloudTrail on.',
  'MFA and SSO assignments live in the management account (unverifiable). Standing AdministratorAccess (SSO 12 h, Atlantis cross-account, CyberArk SCA); no permission boundaries; no IAM password policy.', 'prod stage share'),
 ('REQ13', 'Row 10  IAM application: RBAC + SSO (Keycloak)', 'U', 25, 'T L',
  'Keycloak is CAA-hosted; OpenSearch FGAC+SAML on.', 'Application RBAC not in infra repos or AWS APIs; prod cluster RBAC unreachable from here.', 'prod'),
 ('REQ13', 'Row 11  Incident response: APM, intrusion detection, RCA', 'P', 85, 'T L',
  'GuardDuty (7 protection features) + Security Hub in eu-west-3; Datadog EU1 APM/log shipping.',
  'No Config recorder in prod (Security Hub controls mostly no-data). No alarms/EventBridge on findings. GuardDuty not delegated for prod, runtime off, 3/17 regions. Datadog org for upper is named CAA-DEV.', 'prod stage share'),
 ('REQ13', 'Row 12  Backup & DR: orchestration, retention, immutable storage', 'P', 90, 'T L',
  'Vault Lock COMPLIANCE min 30 d; Object Lock COMPLIANCE on CloudTrail 365 d, BAM logs 7 y, Config 365 d; retention as claimed.',
  'Immutable copy is same account + region as the source. No restore testing (0 restore jobs). Prod Object-Lock backup bucket empty. Most resources not enrolled.', 'prod stage share'),
 ('REQ13', 'Row 13  Change management and reversibility', 'P', 50, 'T L',
  'Atlantis approved+undiverged, autoplan; no force_destroy on buckets; snapshots and versioning.',
  'No CAB or client-consent hook; no exit runbook in repo; prod RDS on AWS-managed key means cross-account snapshot hand-over needs a re-encrypt copy.', 'prod stage'),
 ('REQ14/22', 'Third-party processors visible in infra', 'P', 65, 'T L',
  'Datadog EU1 (lambda forwarder datadoghq.eu, SecurityAudit role); CyberArk SCA/SIA roles; Fivetran hybrid agent.',
  'No HDS/EEA evidence for Datadog (receives EKS audit + RDS logs), CyberArk (brokers Admin into the HDS account) or Fivetran. CyberArk/Fivetran tenant regions not visible. Matches the sheet blocker on sub-processor evidence.', 'prod stage share'),
 ('REQ15/16', 'CloudTrail (access/admin trace)', 'P', 90, 'T L',
  'aws11caasharetrail: multi-region, validated, CMK, Object Lock COMPLIANCE 365 d, delivering; org Control Tower trail also on.',
  'Management events only; no S3 or Lambda data events. Org trail not CMK-encrypted and kept in us-east-1. No metric filters/alarms. 365 d only.', 'prod stage share'),
 ('REQ15/16', 'Database access trace (pgaudit)', 'P', 90, 'T L',
  'pgaudit loaded; prod log_connections/disconnections on; postgresql log export, 365 d retention (prod).',
  'pgaudit.log = role,ddl: no record of who read/modified health-data rows. Stage log retention NEVER, log_connections unset. Sheet REQ16 reads as if access-trace audit is built: not supported at DB level.', 'prod stage'),
 ('REQ15/16', 'EKS audit logs', 'C', 90, 'T L',
  'api, audit, authenticator, controllerManager, scheduler enabled on prod and stage; 365 d.', 'Log group not CMK-encrypted.', 'prod stage'),
 ('REQ15/16', 'Network traces (VPC flow logs, LB logs)', 'P', 90, 'T L',
  'Prod VPC flow logs ALL to S3 (365 d); prod ALB logs 365 d.',
  'No flow logs on stage or share VPC (CyberArk PSM/SIA, Jenkins, OpenSearch, Datadog). NLB access logs off. Stage ALB logs 90 d.', 'prod stage share'),
 ('REQ15/16', 'Edge/application access logging', 'P', 55, 'T',
  'ALB logs present.', 'CloudFront access logs OFF, WAF full request logging OFF. BAM 7-year WORM export not built.', 'prod stage'),
 ('REQ15/16', 'Host audit trail (auditd, log shipping, time sync)', 'U', 35, 'A',
  'Upper hosts are not in Ansible on main; two unmerged branches (COEXT-108807, COEXT-109332) cover them.',
  'Neither branch configures auditd, log shipping or time sync. Live host state not reachable (SSM disabled by design). Cannot confirm either way.', 'share'),
 ('REQ23', 'Access methods (SSO, MFA, SSM/CyberArk, RBAC, no static keys)', 'P', 75, 'T L A',
  '0 IAM users, 0 keys; CyberArk SCA/SIA roles; SSM disabled by design, sessions recorded via CyberArk SIA; EKS private; RDS IAM auth on.',
  'SSH/RDP reachable from all EIS-internal networks, so the CyberArk path can be bypassed with the shared Secrets Manager instance key. CyberArk SIA mechanism still undecided in branch comments. MFA unverifiable. No IAM password policy. Break-glass Client VPN config not found. Upper jnk03 was built from untracked local role copies.', 'prod stage share'),
 ('REQ24', 'Change control (MR, Atlantis, approvals)', 'P', 75, 'T L A',
  'Atlantis: plan needs undiverged, apply needs approved+undiverged, no custom workflows, automerge off.',
  'GitLab CE has no approval rules (self-approve possible); maintainers can push to main; pipeline success not required; no CODEOWNERS. The upper apply role is AdministratorAccess assumed by an Atlantis host in the lower account (us-west-2). Console admin bypasses MR/Atlantis and there is no Config timeline to detect it. Upper Atlantis basic-auth password equals its username in an unmerged branch.', 'prod stage share'),
 ('REQ27', 'Reversibility: export, exit, deletion', 'P', 50, 'T L',
  'S3 versioning (11/14 buckets), RDS snapshots, Fivetran-to-Redshift copy path; Glue/SFTP export defined but commented.',
  'No documented exit runbook in repo. COMPLIANCE locks (Vault 30 d to 3 y, Object Lock up to 7 y) block erasure on termination: disclose in the deletion clause. AWS-managed RDS key complicates snapshot hand-over.', 'prod stage'),
 ('REQ28', 'EEA residency of workloads and data', 'C', 90, 'T L',
  'Live 17-region sweep: all DSCP-bearing resources in eu-west-3; backups, ECR, logs in eu-west-3.',
  'Global services in us-east-1 (CloudFront 11, ACM 6, WAF 4, Route53 7, 2 TLS-material secrets). CloudFront PriceClass_100 includes North America POPs. 6 prod KMS keys unreadable (multi-region flag unverified).', 'prod stage share'),
 ('REQ28', 'Audit-log and control-plane residency', 'P', 90, 'T L',
  'Local trail aws11caasharetrail in eu-west-3.',
  'Org CloudTrail copy of all prod management events in us-east-1 (log archive 410575283064). Terraform plans/applies run from a us-west-2 host. Identity Center in us-east-1.', 'prod stage share'),
 ('REQ28', 'Technical region lock (SCP region-deny)', 'U', 60, 'L',
  'SCPs unreadable from the member account; read calls succeed in all 17 regions.',
  'Most likely no region-deny control (inference). Needs the management account.', 'prod stage share'),
 ('REQ29', 'Non-EEA remote access paths', 'P', 50, 'T L',
  'No VPN/DX/Client VPN inside the CAA account; private subnets, no IGW; CyberArk SIA for host sessions.',
  'allow_eis_vpn=true still on (marked "provisioning-only"); the shared TGW route table learns 10.0.0.0/8 from the EIS corporate VPN, so prod is routable from the global EIS network. No geo restriction on operators. Hub account unreachable, so TGW routes unverified.', 'prod stage share'),
 ('REQ30', '"CMK via external HSM / client-controlled key"', 'N', 85, 'T L',
  '21/27 upper KMS keys inspected: Origin=AWS_KMS, no custom key store, no CloudHSM, no imported/XKS. App PII uses a CAA-owned plain AWS KMS key (CAA account, eu-west-3).',
  'External-HSM claim not implemented. Prod RDS (main DSCP store), MSK, OpenSearch, backup vault and most EBS use AWS-managed keys that neither EIS nor CAA controls. 6 prod CMKs unreadable.', 'prod stage share'),
 ('REQ30', 'Encryption at rest coverage and key custody', 'P', 85, 'T L',
  'Prod RDS StorageEncrypted; EBS default on; S3 SSE; CloudTrail/log buckets on CMK.',
  'Coverage good, custody not: AWS-managed keys on core stores.', 'prod stage share'),
]

# ---- delta merge (optional) ----
DELTA = []
dp = f'{SP}/evidence/upper_delta.json'
if os.path.exists(dp):
    vm = {'COMPLIANT': 'C', 'PARTIAL': 'P', 'NON_COMPLIANT': 'N', 'NO_EVIDENCE': 'U'}
    for x in json.load(open(dp)):
        DELTA.append((x['req'], '+ ' + x['aspect'], vm.get(x['verdict'], 'U'), int(x['confidence']), 'L',
                      ' | '.join(x.get('evidence', [])[:2]), ' | '.join(x.get('gaps', [])[:4]) or '-', re.split(r' \(', x.get('envs', ''))[0].replace('+', ' ')))
ADJ = f'{SP}/upper_adjust.json'   # manual overrides written after reading delta
if os.path.exists(ADJ):
    adj = json.load(open(ADJ))
    ROWS = [r for r in ROWS if not any(r[1].startswith(x) for x in adj.get('drop', []))]
    for r in adj.get('add', []):
        ROWS.append(tuple(r))
    DELTA = [d for d in DELTA if not any(d[1][2:].startswith(x) for x in adj.get('drop_delta', []))]
ROWS = ROWS + DELTA

def chip(v):
    n, c = V[v]
    return f'<span class="chip" style="background:{c}">{n}</span>'

counts = {k: 0 for k in V}
for r in ROWS:
    counts[r[2]] += 1
n_rows = len(ROWS)
avg = round(sum(r[3] for r in ROWS) / n_rows)
hi = len([r for r in ROWS if r[3] >= 80]); mid = len([r for r in ROWS if 50 <= r[3] < 80]); lo = len([r for r in ROWS if r[3] < 50])
guar = [r for r in ROWS if r[2] == 'C' and r[3] >= 80]

SECTIONS = [('REQ04', 'REQ 04: ISMS scope covers backups'), ('REQ05', 'REQ 05: Eight mandatory risk events'),
 ('REQ13', 'REQ 13: Shared-responsibility matrix, claim by claim'), ('REQ14/22', 'REQ 14 / 22: Processors and sub-contractors'),
 ('REQ15/16', 'REQ 15 / 16: Access traces and audit'), ('REQ23', 'REQ 23: Access-control methods'), ('REQ24', 'REQ 24: Change control'),
 ('REQ27', 'REQ 27: Reversibility'), ('REQ28', 'REQ 28: EEA data residency'), ('REQ29', 'REQ 29: Non-EEA remote access'),
 ('REQ30', 'REQ 30: Foreign-law exposure and key custody')]

def sheetcell(rq):
    return '<br>'.join(E(f"{p.replace('REQ','')}: {sheet(p if p.startswith('REQ') else 'REQ'+p)}") for p in rq.split('/'))

def table(req):
    rows = [r for r in ROWS if r[0] == req]
    if not rows:
        return ''
    h = f'<p class="sheetline"><b>Sheet status:</b> {sheetcell(req) if req != "REQ13" else "Complete (awaiting auditor), per the tracker"}</p>'
    h += '<table class="t"><tr><th style="width:16%">Aspect</th><th style="width:10%">Verdict</th><th style="width:6%">Conf.</th><th style="width:7%">Env</th><th style="width:29%">What we saw</th><th>Gaps</th></tr>'
    for r in rows:
        env = r[7].replace(' ', ', ') if len(r) > 7 else ''
        h += f'<tr><td><b>{E(r[1])}</b></td><td>{chip(r[2])}</td><td class="c">{r[3]}</td><td class="c">{E(env)}</td><td>{E(r[5])}</td><td>{E(r[6])}</td></tr>'
    return h + '</table>'

OUT = {'REQ01': 'ISO 27001 certificate / HDS conditions', 'REQ02': 'ISMS context', 'REQ03': 'Interested parties / legal framework',
 'REQ06': 'Sub-processor TOM change control', 'REQ07': 'French-language interfaces and support', 'REQ08': 'French SoA', 'REQ09': 'IS objectives',
 'REQ10': 'Staff and processor awareness', 'REQ11': 'Per-client contact list', 'REQ12': 'HDS certificate disclosure', 'REQ17': 'Contract: certificate scope',
 'REQ18': 'Contract: services', 'REQ19': 'Contract: data-subject rights', 'REQ20': 'Contract: referent', 'REQ21': 'Contract: KPIs and penalties',
 'REQ25': 'Contract: guarantees', 'REQ26': 'Contract: data-use prohibition', 'REQ31': 'Public transfer mapping'}

SC = [('04', 'Backups in ISMS scope', 'P', 80), ('05', 'Eight risk events (A-H)', 'P', 70), ('13', 'Shared-responsibility matrix (13 rows)', 'P', 75),
 ('14', 'Processor cert-loss procedure', 'P', 65), ('15', 'Client access to traces', 'P', 80), ('16', 'Internal audit of access traces', 'P', 80),
 ('22', 'Sub-contractor disclosure', 'P', 65), ('23', 'Access-control methods', 'P', 75), ('24', 'Change control', 'P', 75), ('27', 'Reversibility', 'P', 50),
 ('28', 'EEA residency', 'C', 85), ('29', 'Non-EEA remote access', 'P', 50), ('30', 'Foreign-law mitigation / keys', 'N', 85)]
SC_SHEET = {'05': 'Remediation 75%', '14': 'Remediation 75%', '15': 'Transferred to owner 50%'}

MISMATCH = [
 ('REQ04', 'PARTIAL', 'Backups cover RDS only; no off-account/region copy; EKS/MSK/OpenSearch/S3 not enrolled.'),
 ('REQ13', 'PARTIAL, 1 claim false', 'EEA-only claim holds for upper (outcome), "external HSM" absent, "continuous vuln scanning" absent, least privilege + MFA only partly provable.'),
 ('REQ16', 'PARTIAL', 'DB reads not audited, no S3 data events, no flow logs on stage/share.'),
 ('REQ22', 'PARTIAL', 'Datadog / CyberArk / Fivetran HDS and region evidence missing (also an open sheet blocker on REQ14).'),
 ('REQ23', 'PARTIAL', 'SSH/RDP from 10/8; shared-key bypass of CyberArk; unauthenticated Kafka.'),
 ('REQ24', 'PARTIAL', 'Self-approval possible, direct push to main, no required pipeline, prod applied from a US-hosted Atlantis.'),
 ('REQ27', 'PARTIAL', 'No exit runbook in repo; locks block erasure; key custody blocks snapshot hand-over.'),
 ('REQ28', 'COMPLIANT for workloads', 'Consistent with the sheet for upper: everything runs in eu-west-3. Open: no enforced region lock; control plane and org trail in the US.'),
 ('REQ29', 'PARTIAL', 'Corporate-VPN route into prod still enabled; no geo restriction on operators.'),
 ('REQ30', 'NON-COMPLIANT on keys', '"Client-controlled KMS" exists only at app level and is plain AWS KMS. No external HSM.'),
 ('REQ05 / 14 / 15', 'PARTIAL', 'Consistent: the sheet already shows these as open (risk register, sub-processor evidence, access-request procedure).'),
]

PRIORITY = [
 ('1', 'REQ30 / REQ05 H', 'Put CMKs on prod RDS, MSK, OpenSearch, backup vault and EBS and settle the external-HSM story, or correct the REQ13 matrix wording. As written it overstates.'),
 ('2', 'REQ24 / REQ29 / REQ05 H', 'Stop prod Admin being applied from the us-west-2 Atlantis host (move the apply role to an EEA runner, or scope it down). Flip allow_eis_vpn=false and cut the 10.0.0.0/8 learned route to prod.'),
 ('3', 'REQ13 r6 / REQ05 D', 'Prod MSK: enable IAM or SCRAM client auth. Today the network is the only control.'),
 ('4', 'REQ23', 'Narrow the share SSH/RDP prefix lists (10/8, 192.168/16) so the CyberArk path cannot be bypassed with the shared key; decide the SIA mechanism; narrow Jenkins cluster-admin.'),
 ('5', 'REQ15/16', 'pgaudit read/write on DSCP tables, S3 data events for DSCP buckets, flow logs for stage + share, WAF/CloudFront logs, Config recorder (SCP exception), alarms on GuardDuty findings.'),
 ('6', 'REQ04 / REQ13 r12', 'Cross-account or cross-region backup copy, restore-testing plan, Velero on prod EKS, enrol MSK/OpenSearch/S3/EC2.'),
 ('7', 'REQ13 r5', 'Enable Inspector EC2 + SSM patch baselines (or document the CyberArk-SIA-only model and its patch path); triage the 2,061 critical ECR findings; merge the upper Ansible branches so host config is auditable.'),
 ('8', 'REQ24', 'GitLab: protect main from direct push, require pipeline success and approvals, add CODEOWNERS.'),
 ('9', 'REQ14/22', 'Collect HDS and region evidence from Datadog, CyberArk, Fivetran; the Datadog org used for upper is named CAA-DEV.'),
]

LIMITS = [
 'The second live pass lost its SSO session partway. Not done: cross-region snapshot/backup-vault sweep (16 regions), AWS Backup copy rules, OpenSearch security-group rules, instance-profile policies (why 0/18 hosts register in SSM). A re-run needs a fresh `aws sso login` by you.',
 'Open question for the owner: account 413776100306 appears in two role trusts (CloudWatch cross-account sharing, Network Manager) and is not the org, lower, TGW or CyberArk account.',
 'EKS aws-auth ConfigMap not readable (private endpoint): who holds human cluster-admin on prod/stage is unverified. Authentication mode is API_AND_CONFIG_MAP, so two admin paths exist.',
 'Prod Terraform was not read: the harness prod-guard blocks any command containing a /prod/ path. Prod facts come from live AWS (strong) plus the design ADRs (intent only, never counted as proof).',
 'Management account 455655288646: SCPs, IAM Identity Center assignments and MFA settings are not visible. Region lock and MFA verdicts are NO EVIDENCE or marked inference.',
 'EIS network hub account 729852324759: Transit Gateway routes and Client VPN config unreachable, so who can route to prod is only partly known (REQ29 confidence 50).',
 'Prod/stage EKS: no kube context here (private endpoint). In-mesh mTLS, RBAC bindings and aws-auth are unverified.',
 '6 prod KMS key policies deny DescribeKey to the ReadOnly role; their origin and multi-region flag are unknown.',
 'SaaS tenant regions (Fivetran, CyberArk) and application-level controls (Keycloak RBAC, application DEKs, BAM) are not visible from AWS or the repos.',
 'Upper host configuration is in two unmerged Ansible branches only; audited from branch code, not from the hosts.',
 'The Atlantis host that applies upper changes lives in the lower account (us-west-2). It is in scope here only as the upper change path; the lower environment itself is out of scope.',
 'Snapshot date 2026-10-15. Terraform at origin/main (CAA 8ae6502). Live state read with the CAA-Upper-ReadOnly profile; no resource was changed.',
 'The tracker "Complete / awaiting auditor" status mostly means documents drafted. This audit tests technical state, so a mismatch does not prove the paperwork wrong.',
 'The 18 contract, legal, HR, training and governance REQs (01-03, 06-12, 17-21, 25, 26, 31) cannot be proven from infrastructure and are not scored.',
]

css = """@page{size:A4;margin:16mm 13mm}*{box-sizing:border-box}
body{font-family:-apple-system,"Helvetica Neue",Arial,sans-serif;font-size:9.2pt;color:#1b1f24;line-height:1.38}
h1{font-size:22pt;margin:0 0 2pt}h2{font-size:13.5pt;margin:16pt 0 5pt;padding-bottom:3pt;border-bottom:2px solid #1b1f24;page-break-after:avoid}
h3{font-size:10.5pt;margin:11pt 0 3pt;page-break-after:avoid}.sub{color:#555;margin-bottom:10pt}
.chip{color:#fff;font-weight:700;font-size:7.3pt;padding:1.5pt 5pt;border-radius:8pt;white-space:nowrap;display:inline-block}
.cards{display:flex;gap:7pt;margin:8pt 0}.card{flex:1;border:1px solid #d0d4da;border-radius:5pt;padding:7pt 8pt}
.card .n{font-size:20pt;font-weight:700;line-height:1}.card .l{font-size:8pt;color:#555}
table.t{border-collapse:collapse;width:100%;margin:3pt 0 8pt;font-size:8.2pt}
table.t th{background:#eef0f3;text-align:left;padding:3.5pt 4pt;border:1px solid #cfd3d9;font-size:7.8pt}
table.t td{border:1px solid #d7dbe0;padding:3.5pt 4pt;vertical-align:top}table.t tr{page-break-inside:avoid}
td.c{text-align:center}.sheetline{margin:2pt 0 3pt;font-size:8.4pt;color:#333}
.note{background:#fff8e6;border-left:3px solid #b7791f;padding:5pt 8pt;margin:6pt 0;font-size:8.6pt}
.good{background:#eaf6ee;border-left:3px solid #1a7f37;padding:5pt 8pt;margin:6pt 0;font-size:8.6pt}
ul{margin:3pt 0 3pt 14pt;padding:0}li{margin:2pt 0}.small{font-size:8pt;color:#555}.pb{page-break-before:always}"""

h = f'<!doctype html><html><head><meta charset="utf-8"><title>HDS audit CAA upper</title><style>{css}</style></head><body>'
h += '<h1>HDS Compliance Audit: CAA Upper (prod, stage, share)</h1>'
h += '<div class="sub">Scope: Crédit Agricole Assurances <b>upper</b> account 144905517910, eu-west-3. Upper = production + pre-production (stage) + shared tooling (share: CyberArk, Jenkins, OpenSearch, Datadog, backups). The lower account (dev/test/infra, us-west-2) is <b>out of scope</b>. Repos: credit-agricole terraform upper/*, ArgoCD, Ansible (upper branches). Source sheet: "April 2026 HDS Unique Controls for Implementation" (31 REQs). Audit date 2026-10-15. Read-only.</div>'

h += '<h2>1. Bottom line</h2>'
h += f'<p>The sheet marks 26 of 31 REQs complete. Within upper, <b>1 of the 13 technically testable REQs is compliant (REQ 28, EEA residency of workloads); 11 are partial and 1 is non-compliant (REQ 30, key custody)</b>. Of {n_rows} sub-aspects tested: {counts["C"]} compliant, {counts["P"]} partial, {counts["N"]} non-compliant, {counts["U"]} no evidence. Seven gaps matter most:</p><ul>'
for t in [
 '<b>No external HSM or client-held key.</b> All 21 readable upper KMS keys are AWS-generated. Prod RDS, MSK, OpenSearch, the backup vault and 10 of 17 prod volumes use AWS-managed keys. The REQ13 "CMK via external HSM" claim is not implemented.',
 '<b>Prod change and admin plane is outside the EEA.</b> An Atlantis host in us-west-2 holds AdministratorAccess on prod; Identity Center and the org CloudTrail copy sit in us-east-1.',
 '<b>Prod and stage Kafka (MSK) accept unauthenticated clients</b>, the Jenkins instance role is prod EKS cluster-admin, and prod is routable from the EIS corporate network (10.0.0.0/8 via TGW). SSH/RDP to share hosts is open from 10/8 and 192.168/16, so the CyberArk path can be bypassed.',
 '<b>Access traces cannot show who read health data, and nothing detects misuse.</b> pgaudit logs role + DDL only; no S3 data events; CloudFront (11/11), WAF (4/4) and DNS query logging off; no flow logs on stage/share; no Config recorder in prod. Zero CloudWatch metric filters, 10 OpenSearch alarms with no action, 1 SNS topic with no subscriber.',
 '<b>Backups are locked but not resilient.</b> Compliance-mode vault, but no cross-region/account copy, 0 restore jobs ever, no Velero on prod EKS, most resources not enrolled.',
 '<b>Shared keys and host layer.</b> One EBS CMK covers prod, stage and share volumes; one RDS CMK covers prod and stage. 41 of 52 secrets are on the default key and 48 never rotate. Host layer unproven: Inspector EC2 scanning off, 0 of 18 EC2 under SSM, 2,061 critical ECR image findings untriaged, upper host config only in unmerged Ansible branches.',
 '<b>Change control is soft.</b> GitLab CE allows self-approval and direct pushes to main; pipeline success is not required to merge.',
]:
    h += f'<li>{t}</li>'
h += '</ul>'
h += '<div class="good"><b>What holds up.</b> Every DSCP-bearing resource is in eu-west-3 (live 17-region sweep). No IAM users or access keys. Prod RDS is encrypted, TLS 1.3 minimum, IAM auth on, deletion protection on. EKS audit logs on, 365 d. CloudFront and ALB enforce TLS 1.2+. CloudTrail multi-region with validation and Object Lock. Backup vault in compliance-mode lock. GuardDuty on with 7 protection features.</div>'
h += '<div class="cards">'
for k, lab in [('C', 'Compliant'), ('P', 'Partial'), ('N', 'Non-compliant'), ('U', 'No evidence')]:
    h += f'<div class="card"><div class="n" style="color:{V[k][1]}">{counts[k]}</div><div class="l">{lab} (of {n_rows} aspects)</div></div>'
h += f'<div class="card"><div class="n">{avg}</div><div class="l">mean confidence (0-100)</div></div><div class="card"><div class="n">18</div><div class="l">REQs not provable from infra, not scored</div></div></div>'
h += '<h3>How to read confidence</h3>'
h += f'<p class="small">Rows prefixed "+" come from the second, upper-only live pass. Confidence = how sure the verdict is from data actually seen, not a compliance percentage. <b>80-100</b>: confirmed in live AWS, usually also in code [{hi} aspects]. <b>50-79</b>: code plus partial live, or partial coverage [{mid}]. <b>&lt;50</b>: inference, or the control sits outside what we can read [{lo}]. A row we can guarantee is fulfilled needs COMPLIANT with confidence 80+ [{len(guar)}: ' + '; '.join(E(r[1]) for r in guar) + ']. "Src": T = Terraform/ArgoCD, A = Ansible, L = live AWS. "Env" = which upper environments the finding was checked in.</p>'

h += '<h2>2. Scorecard: the 13 testable REQs (upper)</h2><table class="t"><tr><th>REQ</th><th>Topic</th><th>Sheet says</th><th>Audit verdict</th><th>Conf.</th></tr>'
for a, b, d, e in SC:
    h += f'<tr><td><b>REQ {a}</b></td><td>{E(b)}</td><td>{E(SC_SHEET.get(a, "Complete (awaiting auditor)"))}</td><td>{chip(d)}</td><td class="c">{e}</td></tr>'
h += '</table><p class="small">Roll-up rule: a REQ is PARTIAL when any decisive sub-aspect is partial or worse; REQ 30 is non-compliant because its key-custody claim is not implemented. REQ 05 stays partial, but 3 of its 8 risk events (D access control, E uncontrolled interventions, H non-EU legislation) have non-compliant mitigation; REQ 15/16 stays partial though alerting, edge and DNS logging are non-compliant. REQ-level confidence = lowest among the decisive sub-aspects, rounded. See section 4.</p>'

h += '<h2>3. Sheet status versus what upper shows</h2><table class="t"><tr><th style="width:12%">REQ</th><th style="width:22%">Audit (upper)</th><th>Why</th></tr>'
for a, b, c in MISMATCH:
    h += f'<tr><td><b>{a}</b></td><td>{E(b)}</td><td>{E(c)}</td></tr>'
h += '</table>'

h += '<h2 class="pb">4. Findings by requirement</h2>'
for key, title in SECTIONS:
    t = table(key)
    if t:
        h += f'<h3>{E(title)}</h3>' + t
extra = sorted({r[0] for r in ROWS} - {k for k, _ in SECTIONS})
if extra:
    h += '<h3>Other upper findings</h3><table class="t"><tr><th>REQ</th><th>Aspect</th><th>Verdict</th><th>Conf.</th><th>Env</th><th>Seen</th><th>Gaps</th></tr>'
    for r in ROWS:
        if r[0] in extra:
            h += f'<tr><td>{E(r[0])}</td><td>{E(r[1])}</td><td>{chip(r[2])}</td><td class="c">{r[3]}</td><td>{E(r[7])}</td><td>{E(r[5])}</td><td>{E(r[6])}</td></tr>'
    h += '</table>'

h += '<h2 class="pb">5. Not provable from infrastructure (18 REQs, not scored)</h2><p>Contract, legal, HR, training and governance requirements. Sheet status shown for reference only.</p>'
h += '<table class="t"><tr><th style="width:8%">REQ</th><th>Topic</th><th>Sheet status</th><th style="width:7%">Sheet %</th></tr>'
for k, v in OUT.items():
    pc = reqs.get(k, {}).get('% Complete', '')
    try: pc = f'{round(float(pc) * 100)}%'
    except Exception: pc = pc or '-'
    h += f'<tr><td><b>{k[3:]}</b></td><td>{E(v)}</td><td>{E(sheet(k))}</td><td class="c">{pc}</td></tr>'
h += '</table><h2>6. Suggested remediation order</h2><table class="t"><tr><th style="width:4%">#</th><th style="width:20%">REQ</th><th>Action</th></tr>'
for a, b, c in PRIORITY:
    h += f'<tr><td class="c">{a}</td><td>{E(b)}</td><td>{E(c)}</td></tr>'
h += '</table><p class="small">Audit recommendations, not changes made. Nothing was modified in any repo or account. Items 1 and 2 need decisions outside the infra team (key strategy, where Atlantis runs); some changes touch the shared EIS hub or the management account.</p>'

h += '<h2>7. Method and limits</h2><p>First pass: Terraform + ArgoCD, Ansible and live AWS auditors (read-only) on both CAA accounts. This upper-only report removes everything that applies only to the lower account, re-scores each finding for prod/stage/share, and adds a second live pass on upper-only items (S3, EKS access, snapshots, OpenSearch, share EC2, IAM, ECR, CloudFront/WAF, Backup coverage). Where sources disagreed the live result decided the verdict. The sheet was read via Google Drive, read-only.</p><ul>'
for l in LIMITS:
    h += f'<li>{E(l)}</li>'
h += '</ul><div class="note"><b>Confidence caveat.</b> Scores are the auditor\'s estimates from data seen, not measured accuracy, and not a certification opinion. HDS certification is decided by the accredited auditor.</div></body></html>'
out = f'{SP}/hds_upper.html'
open(out, 'w').write(h)
print('rows', n_rows, counts, 'avg', avg, 'hi/mid/lo', hi, mid, lo, 'delta', len(DELTA), 'extra sections', extra)
