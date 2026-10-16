---
name: caa-upper-webservices-inventory
description: Use when asked for the full list of web UIs/services in Credit Agricole upper (stage/prod/share) — e.g. for CyberArk/SSO integration, "is Grafana/Solr/Kafka UI there", "confirm wiki list". Read-only; IaC first, then live cluster.
---

# CAA upper web-service inventory

1. Wiki baseline (read-only): `curl -s -H "Authorization: Bearer $CONFLUENCE_TOKEN" "https://wiki.eisgroup.com/rest/api/content/908892676?expand=body.storage"` (strip tags). Known: Jenkins (share), Headlamp + OneSuite Dashboard (stage, prod).
2. IaC (`projects/aws/credit-agricole/terraform/upper/{stage,prod,share}`): grep `eks.tf`, `msk.tf`, `share/services/{ec2,cyberark}.tf`. Facts: observability = Datadog (no Grafana); MSK has no UI; Solr only an S3 prefix; share has Vault + CyberArk. Prod paths are blocked by prod-guard for reads — use non-prod/ask user.
3. Upper clusters are not in `argocd/argocd/clusters`; repo cannot list ingress hosts. Live check required (VPN, upper EKS context, see `aws-kubectl-readonly-access`): gateway/VirtualService/Ingress hosts + `kubectl get svc -A | grep -iE 'solr|grafana|kafka'`.
4. Report: table tool / URL / env / SSO needed; mark each row IaC-verified vs live-verified. Never call a list "final" from IaC alone. Portals (broker/member/pbroker/pmember/dxp-gateway) are app endpoints — ask whether CyberArk scope includes them.
