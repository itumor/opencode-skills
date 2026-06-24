---
name: s3-static-content-istio-gateway
description: End-to-end playbook for serving private S3 static content (PDFs, SPA assets) to EIS private networks through the Istio cluster gateway — eis-s3 map bucket with VPC-read policy + CORS, S3 gateway VPC endpoint prerequisite, istio-gateway-cluster externalServices entry, verification curls, and developer write access via IdC. Use when a customer asks for an S3 bucket "with public/read access" for portal static files, when adding a new externalServices S3 host, or when a ppdf/pbroker-style URL must be stood up on any EIS cluster. Reference: COEXT-104484 (aws0caadevportal-pdf on aws0caadeveks01 + canary aws0iacdevportal-pdf on aws0iacdeveks01); COEXT-105216 (aws0caatestportal-broker/member on aws0caatesteks01, single caa-uat path); COEXT-105289 (aws0caatestportal-pdf ppdf-eis on aws0caatesteks01 — UAT clone of 104484, single pdfs/ prefix).
---

# Private S3 static content via Istio cluster gateway

Pattern: bucket is **never public** (BPA 4×true). Anonymous `s3:GetObject` is allowed only with `Condition: {StringEquals: {"aws:sourceVpc": <vpc>}}`. Clients hit `https://<name>.<cluster-domain>/...`; the Istio ingress gateway (private ALB → NodePort → Envoy) rewrites and proxies to `<bucket>.s3.<region>.amazonaws.com` over the **S3 gateway VPC endpoint**, which is what makes the `aws:sourceVpc` key appear. Direct internet access → 403.

Delivered example: `https://ppdf-eis.dev.aws0.caa-eis.cloud/consent-pdf/x.pdf` → S3 key `pdfs/consent-pdf/x.pdf` in `aws0caadevportal-pdf`.

UAT clone (COEXT-105289): same pattern, `https://ppdf-eis.test.aws0.caa-eis.cloud/consent-pdf/x.pdf` → `aws0caatestportal-pdf`. **"UAT" = terraform `lower/test/` stage** (stage=`test`, prefix `aws0caatest`); there is NO `uat` dir. The ticket may name the bucket `aws0caauat*` — wrong; the stage prefix is the real name (matches sibling `aws0caatestportal-broker/member`). The test stage's `s3.tf` was on `eis-s3 v2.0.0` with **no** `cors_rule` wiring — bump to v2.1.0 + add the `cors_rule = try(each.value.cors_rule, [])` line (CUSTOM markers) just like dev before CORS works. Prereqs (S3 gateway VPC endpoint, `portals_policy_custom.json`) already existed from COEXT-105216. Delivered MRs: credit-agricole !71 + argocd !290; write access = `PortalPDFS3ReadWrite` permission set extended with the UAT bucket ARN.

## 0. Prerequisites / preflight

1. **S3 gateway VPC endpoint in the stage VPC** — REQUIRED. Check:
   `aws ec2 describe-vpc-endpoints --filters Name=service-name,Values=com.amazonaws.<region>.s3`
   - CAA dev has one (`vpce-018f2f6fb6b0bd369`); **iac dev did NOT** until COEXT-104484.
   - If missing: add `aws_vpc_endpoint.s3` (Gateway type, private+intra route tables) in `lower/<stage>/core/` — copy `credit-agricole/.../dev/core/vpc_endpoints.tf`. Free, additive. On eis-iac apply with `-target=aws_vpc_endpoint.s3` (core drift rule).
   - **A sibling lower stage is NOT a clean copy of dev.** COEXT-105216: `lower/test/core/vpc_endpoints.tf` was MISSING and `lower/test/services/s3.tf` LACKED the `policy=templatefile(...)` block dev had. Always `diff` test-vs-dev `core/vpc_endpoints.tf` + `services/s3.tf` before assuming the policy passthrough exists; add whichever is absent.
2. **eis-s3 module version**: `v2.0.0` already has the `policy` passthrough — sufficient for read-only portals with NO CORS (COEXT-105216 broker/member). Only bump to **≥ v2.1.0** when you need `cors_rule` passthrough (COEXT-104484 portal-pdf). Wrapper `s3.tf` must pass the `policy_file` templatefile (vars: project_prefix, bucket_name, vpc_id) and, for v2.1.0, `cors_rule = try(each.value.cors_rule, [])`. Template/client ships cors from MR !13 onward; older projects need the 2-line bump (single-line `# CUSTOM` markers).
3. istio-gateway-cluster component enabled on the cluster; cluster ingress domain from `clusters/<c>/values.yaml`.

## 1. Terraform — bucket in the s3 map (NOT a custom module block)

`lower/<stage>/services/terraform.tfvars` (HCL) or `.tfvars.json`:

```hcl
portal-pdf = {
  policy_file = "portals_policy_custom"   # files/s3/portals_policy_custom.json — sourceVpc GetObject
  versioning  = { enabled = true }
  server_side_encryption_configuration = { rule = { apply_server_side_encryption_by_default = { sse_algorithm = "AES256" } } }
  lifecycle_rule = [{ id = "expire-noncurrent-versions", status = "Enabled",
    noncurrent_version_expiration = { days = 90 }, abort_incomplete_multipart_upload_days = 7 }]
  cors_rule = [{ allowed_headers = ["*"], allowed_methods = ["GET", "HEAD"],
    allowed_origins = ["*"], expose_headers = ["ETag"], max_age_seconds = 3000 }]
}
```

- Bucket name = `<project_prefix><key>` (e.g. `aws0caadev` + `portal-pdf`). AWS appends NOTHING — prefix is the uniqueness.
- `portals_policy_custom.json` is shared with portal-member/broker; copy it into `files/s3/` if the project lacks it.
- BPA stays default-true: a `Principal:"*"` statement conditioned on `aws:sourceVpc` is evaluated **non-public** by S3 Block Public Access.
- CORS needed when the UI `fetch`es cross-origin (different gateway host); plain `<a href>` links don't need it — ticket asked, keep it.

## 2. ArgoCD — one externalServices entry

`clusters/<cluster>/istio-gateway-cluster/values.yaml`:

```yaml
externalServices:
  - name: ppdf-eis            # host becomes ppdf-eis.<cluster-domain>
    service:
      hostname: <bucket>.s3.<region>.amazonaws.com
      path: pdfs              # S3 key prefix prepended by the VS rewrite
```

Renders ServiceEntry (MESH_EXTERNAL/DNS) + DestinationRule (TLS SIMPLE/SNI) + VirtualService on `cluster-gw`. Rewrite semantics (`components/istio-gateway-cluster/templates/external-services.yaml`):
- uri with a dot (`^\/(.*\..*)$`) → `/<path>/<match>` — `/consent-pdf/x.pdf` → `/pdfs/consent-pdf/x.pdf` (nested folders just work)
- dot-less uri → `/<path>/index.html` (SPA fallback; harmless for docs)

**Folder layout decision:** the `path`/host scheme is customer-driven — ask, don't assume:
- COEXT-104484 (portal-pdf): rejected per-tenant folders — ONE host + ONE shared prefix (`pdfs/` with `consent-pdf/` + `footer-pdf/`).
- COEXT-103502 dev portals: per-tenant — `pbroker-<ns>`/`pmember-<ns>` for 5 namespaces (caa-dev01, caa-int01, caa-mt01, caa-qaa, eis-internal).
- COEXT-105216 UAT portals: a SINGLE tenant path `caa-uat`. **The env *deployers* pick the namespace name** (visible in the stage's SecretsManager paths), not IaC — confirm with them / the env-prep ticket.

**externalServices route regardless of whether the namespace exists.** `path` is just an S3 key prefix and the host lives on the istio-system `cluster-gw` — no `<ns>` namespace object is needed. So Part B (Istio) can ship AHEAD of the env-prep ticket that creates the app namespaces (COEXT-105216 shipped while caa-test had only platform namespaces).

Local render check before MR:
`helm template istio-gateway-cluster components/istio-gateway-cluster -f components/istio-gateway-cluster/values.yaml -f clusters/<c>/values.yaml -f clusters/<c>/istio-gateway-cluster/values.yaml | grep -E "name: <name>-(vs|svce|dstrule)"`

DNS/TLS: wildcard `*.<cluster-domain>` already covers new hosts (proven by existing entries). After merge: auto-sync ~3min, or force:
`kubectl --context <hub> -n argocd patch application istio-gateway-cluster-<cluster> --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}},"operation":{"sync":{"prune":true}}}'`

## 3. Order of operations

TF bucket apply **before** ArgoCD merge (ServiceEntry targets the bucket hostname). Then upload test object → merge ArgoCD MR → sync → curl.

## 4. Verification

```bash
curl -i https://<name>.<domain>/consent-pdf/test.pdf                  # 200, application/pdf, %PDF body
curl -i -H "Origin: https://x" https://<name>.<domain>/...            # access-control-allow-origin: *
curl -i https://<bucket>.s3.<region>.amazonaws.com/<key>              # 403 from internet (privacy proof)
kubectl --context <cluster> -n istio-system get serviceentry,destinationrule,virtualservice | grep <name>
```
403 via the gateway ⇒ sourceVpc unmet ⇒ check the S3 gateway endpoint + its route-table associations.

**The gateway host resolves to a PRIVATE ALB — often unreachable from your laptop.** The authoritative `200` test is in-cluster (and it's the real sourceVpc path anyway). Upload a test object, then curl the ingress gateway with a `Host` header (COEXT-105216, no sidecar so the request isn't mesh-intercepted):
```bash
aws s3 cp x.html s3://<bucket>/<path>/index.html --profile <prof>     # write via your SSO/bld role, NOT the bucket policy
kubectl --context <cluster> -n default run gwtest --rm -i --restart=Never \
  --image=curlimages/curl:8.5.0 --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
  --command -- curl -s -w '\nHTTP %{http_code}\n' \
    -H 'Host: <name>.<domain>' http://istio-ingressgateway.istio-system/index.html   # 200 + body
# /index.html (has dot) → S3 key <path>/index.html ; / (dot-less) → <path>/index.html (SPA fallback). Remove the test object after.
```

## 5. Developer write access (identity-side, zero TF)

- Bucket policy carries NO write statements. Write = IdC permission set inline policy: Put/Get/DeleteObject on `arn:aws:s3:::<bucket>/*` + ListBucket on bucket.
- **AD/IdC group requests go to EISHELP (OPS team), NEVER COEXT** — Access Request type; see memory [[eishelp-ad-group-requests]] for exact fields. Naming: group `<service>_<project>_<access>` (`portal_pdf_caa_rw`), permission set CamelCase (live: `PortalPDFS3ReadWrite`).
- Activates the moment IdC assignment lands — no terraform re-apply (that's WHY identity-side beats the gated bucket-policy lookup: templatefile can't take dynamic ARNs anyway, and `aws:PrincipalArn`-wildcard conditions count as PUBLIC for BPA).
- CI `bld` EC2 role usually already covers `<prefix>*portal-*` buckets.

## Gotchas (all hit during COEXT-104484)

1. **eis-s3 v1.0.x → v2.1.0 bump on a shared `module.s3`** (inner s3-bucket 4.6.0→5.9.1): benign diffs on existing buckets only — `+ skip_destroy` on BPA, SSE re-assert with `blocked_encryption_types ["SSE-C"]→[]`. Gate with a plan; use `-target=module.s3` to exclude unrelated stack drift (eis-iac full plan drags EKS addon/NG changes).
2. **Stale feature branch = orphan DESTROY hazard**: a branch cut before a module bump on main plans `destroy` of live resources the branch's module version doesn't know (we nearly destroyed the live RDS credentials secret). Rebase onto main before any apply.
3. **Atlantis plan role & Secrets Manager**: plan role = ReadOnlyAccess + state-access policy; SM `GetSecretValue` only on `<prefix>*/*` patterns in `bootstrap/files/iam/state_access.json` (was `*eks*/*` only — widened in CAA !69). Managed `aws_secretsmanager_secret_version` with plain `secret_string` reads the secret at EVERY refresh; fleet convention is `secret_string_wo` + `secret_string_wo_version` (never read back). New modules writing secrets must either use `_wo` or extend the plan-role pattern.
4. **`glab mr merge` default merge-commit message breaks module-repo main pipelines** (commit-msg lint `type(scope): JIRA-### - msg`). Squash or set message `chore(merge): NOJIRA-001 - merge branch 'x' into 'main'`. semantic-release also fails EGITNOPERMISSION → manual `git tag vX.Y.Z && git push origin tag && glab api projects/:id/releases -X POST`.
5. **Atlantis extra args work**: `atlantis plan -p <proj> -- -target=module.s3` — targeted plan+apply path when full plan is blocked. Fresh push supersedes saved plans; re-comment after every push.
6. Jira: Resolve transition (id `5`) requires `resolution` (`Fixed`) and takes `customfield_47242` Resources Changed (`Cloud resources extended w/o cost change` for empty buckets + free gateway endpoint). Log effort via `POST /issue/<k>/worklog {timeSpent:"3h",...}`. To assign to the reporter, `PUT /issue/<k>/assignee {"name":"<reporter>"}` after transitioning. Issue link type name is `Related` (not "Relates").
7. **New lower stage ≠ dev clone** (COEXT-105216): test stage was missing both `core/vpc_endpoints.tf` and the `services/s3.tf` `policy` block. Diff sibling stages before assuming the policy passthrough + S3 endpoint exist (see Preflight #1–#2).
8. **"Add the X folder like dev" = content, not IaC** (COEXT-105289 reopen): an S3 "folder" is just an object key prefix — it exists only because objects were uploaded under it. The bucket TF config (policy/CORS/versioning/SSE) is identical across stages, so a missing folder is NEVER a Terraform/ArgoCD change. Fix with a content mirror: `aws s3 sync s3://<devbucket>/<prefix>/ s3://<stagebucket>/<prefix>/ --exclude test.pdf` (admin profile, server-side, same acct/region). Confirm dev↔stage prefix parity with `aws s3 ls s3://<bucket>/<root>/` first. portal-pdf holds TWO content prefixes — `consent-pdf/` AND `footer-pdf/` (each `customer/`+`partner/` per-language PDFs); mirroring one doesn't bring the other.
9. **Spaces in object keys → curl `HTTP 000`** (connection/request-line failure, NOT a 403). URL-encode spaces as `%20`. `HTTP 000` = curl couldn't form the request; only a real `403` means the sourceVpc/policy path is wrong.
10. **Poisoned `test.pdf` artifact**: dev's portal-pdf `test.pdf` objects are print-to-PDF captures of an OLD S3 *AccessDenied* page (PDF `/Title` = the dev gateway host). Syncing them into a new stage makes the test URL render a scary "AccessDenied" XML that is the **file content**, not a live error — it still returns `200 application/pdf` and opens in the browser PDF viewer (page thumbnail = genuine PDF). Tell: a true 403 renders as raw text, never inside the PDF viewer. Fix by overwriting with a clean minimal PDF (`--exclude test.pdf` on the sync avoids copying the junk). After overwrite, users must hard-refresh — browser caches the old object; bucket is versioned so it's reversible.
