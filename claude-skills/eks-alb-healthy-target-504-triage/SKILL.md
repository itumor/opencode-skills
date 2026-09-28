---
name: eks-alb-healthy-target-504-triage
description: Use when an app behind an EIS internal ALB → EKS NodePort → Istio path returns 502/503/504 or "doesn't work" and you have no kubectl access (private-only EKS endpoint, prefix-list-restricted control plane) — especially when the ALB target group says every target is healthy. Read-only AWS triage via target health, CloudTrail RegisterTargets/DeregisterTargets, ALB access logs in S3, and the ALB/node security-group NodePort window (eis-alb restrict_egress + eis-eks alb_sg_nodeport_egress, 32000-32767 in v2.7.1). Reference: CAA upper/stage aws11caastageeks01 dxp-gateway, 2026-09-24.
---

# ALB → EKS NodePort → Istio: "targets healthy, requests fail"

Read-only throughout, with a ReadOnly SSO role (CAA upper: profile `CAA-Upper-ReadOnly`). No kubectl or SSM needed. Run the steps in order; each one narrows the layer.

## 1. Target group state
```bash
aws elbv2 describe-target-health --region <r> --target-group-arn <tg-arn> \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' --output table
aws elbv2 describe-target-groups --region <r> --names <tg> \
  --query 'TargetGroups[0].{Port:Port,HCPort:HealthCheckPort,HCPath:HealthCheckPath}'
```
Note the **registered traffic port** (per target) vs the **health-check port**. If they differ, step 4 matters.

## 2. Who registers targets, and on which port
```bash
for ev in RegisterTargets DeregisterTargets; do
aws cloudtrail lookup-events --region <r> --lookup-attributes AttributeKey=EventName,AttributeValue=$ev \
  --start-time "$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)" --output json | python3 -c "
import json,sys
for e in json.load(sys.stdin)['Events']:
    ct=json.loads(e['CloudTrailEvent']); rp=ct.get('requestParameters') or {}
    print(e['EventTime'],'$ev',[(t.get('id'),t.get('port')) for t in rp.get('targets',[])],ct['userIdentity'].get('arn','')[-70:])"
done
```
- Actor `…-alb_controller-Role/…` means the AWS Load Balancer Controller is running (Helm-installed; it never shows in `aws eks list-addons`) and follows the Service NodePort automatically.
- A **port change** across events (e.g. 32080 → 31098) means the Istio Service was recreated with unpinned NodePorts.
- An empty target group can just be a transient gap during a reinstall. Check the timeline before concluding "nothing registers".

## 3. ALB access logs: the real per-request evidence
Logs live in the stack's ALB log bucket, e.g. `s3://aws11caastagealb-logs/<prefix>/AWSLogs/<acct>/elasticloadbalancing/<region>/YYYY/MM/DD/`. Skip `conn_log_*`; those are connection logs.
```bash
aws s3 sync s3://<bucket>/<prefix>/AWSLogs/<acct>/elasticloadbalancing/<r>/<YYYY/MM/DD>/ ./alblogs/ --exclude "conn_log_*" --quiet
python3 - ./alblogs <host-substring> <<'EOF'
import gzip,glob,shlex,sys
rows=[]
for f in glob.glob(sys.argv[1]+"/**/*.log.gz",recursive=True):
    for line in gzip.open(f,"rt",errors="replace"):
        if sys.argv[2] not in line: continue
        try: rows.append(shlex.split(line))
        except ValueError: pass
for p in sorted(rows,key=lambda p:p[1])[-40:]:
    # 1 time, 4 target:port, 5 req_proc, 6 target_proc, 8 elb_code, 9 target_code, 12 request
    print(p[1][:19], p[8], p[9], "tgt="+p[4], "t_tgt="+p[6], p[12][:90])
EOF
```
Reading it:
| Pattern | Meaning |
|---|---|
| `504 -` with `t_req=-1 t_tgt=-1`, ~10s apart | TCP connect to target failed: SG / NodePort / nothing listening |
| `503 -` target `-` | No registered or no healthy targets |
| `<code> <code>` with real `t_tgt` | App answered; network is fine (e.g. `404 404` on `/` = no route there) |

Log delivery lags ~5 min; re-sync before concluding "still broken".

## 4. Security-group NodePort window
```bash
aws ec2 describe-security-group-rules --region <r> --filters Name=group-id,Values=<alb-sg> \
  --query 'SecurityGroupRules[?IsEgress==`true`].[FromPort,ToPort,ReferencedGroupInfo.GroupId,Description]' --output table
aws ec2 describe-security-group-rules --region <r> --filters Name=group-id,Values=<node-sg> \
  --query 'SecurityGroupRules[?IsEgress==`false` && ReferencedGroupInfo.GroupId==`<alb-sg>`].[FromPort,ToPort]' --output table
```
With `eis-alb restrict_egress = true` + `eis-eks alb_sg_nodeport_egress = true`, both rules open only a window (v2.7.1: **32000–32767**). **Traffic port outside the window + health port inside it = green targets that 504.** Get the node SG from any node instance (`describe-instances … SecurityGroups`).

## 5. Fix
1. **Preferred:** pin the Istio ingressgateway NodePorts inside the window, matching the org convention in argocd `clusters/*/istio-ingress-cluster/values.yaml`: `status-port 32639`, `http2 32080`, `https 32443`. That's a change in whoever deploys Istio (ArgoCD values, or Jenkins Helm values on non-ArgoCD clusters like CAA stage). No Terraform.
2. **Or** widen the window, e.g. 30000–32767. **Both** sides must go through Terraform: node-SG ingress and the ALB-SG egress `eis-eks` `aws_security_group_rule.alb_nodeport_egress`. A hand-edit of the live ALB egress rule is reverted by the next apply. After any widening, check the next plan on the stack for a change on `alb_nodeport_egress`.

To see what's deployed (Service types/ports, probes) without kubectl, use the EKS audit log: memory `eks_audit_log_as_kubectl_substitute`.

## Related memory
- `alb_healthy_targets_504_nodeport_window` — the pattern in one page
- `caa_dxp_gateway_deployment_status` — the CAA stage incident and timeline
- `eks_audit_log_as_kubectl_substitute` — spec/port/probe discovery without kubectl
- `caa_upper_public_edge_constraints` — why kubectl is unavailable on CAA upper
