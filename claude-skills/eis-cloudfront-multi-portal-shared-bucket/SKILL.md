---
name: eis-cloudfront-multi-portal-shared-bucket
description: >-
  Use when wiring multiple eis-cloudfront distributions (portals, tenant sites) to share ONE
  eis-s3 bucket via origin_path isolation — the org's real convention (broker/member on
  aws0caadevportals/aws0caatestportals), not one bucket per distribution — AND when naming the
  portal hostname itself (p<role>-<tenant>, e.g. pbroker-caa-stage). Covers the bucket-policy
  grouping pattern, hostname naming, proving the design on eis-iac dev first, the
  versioned-bucket-destroy trap when renaming an applied bucket, rebasing a dependent MR across
  the rename, and E2E verification (WAF Bot Control UA spoofing, VPN split-horizon DNS
  workaround, bucket-policy inspection). ALSO use when a customer wants their OWN domain on a
  portal (e.g. a .pt name), or a self-signed/placeholder/CSR-imported cert must front
  CloudFront — mirror distribution, day-1 placeholder alias, tfvars-only cutover, one-CSR rule.
  Reference: COEXT-108811 (MR !161/!175), COEXT-110386 (MR !184).
---

# Multi-portal, one shared S3 bucket, `origin_path` isolation

End-state: N `eis-cloudfront` distributions, ONE `eis-s3` bucket, each distribution's `origin_path` is the only thing separating its content from the others'. This is the org's actual convention (confirmed live: `aws0caadevportals`/`aws0caatestportals` hold `<tenant>/broker/…` and `<tenant>/member/…` prefixes) — **not** one dedicated bucket per portal, which is a plausible-looking but wrong reading of "each portal has its own distribution"-style design decks. See [[eis_cloudfront_portals_design_decisions]] for the full decision record and why an earlier attempt at this got the topology backwards.

## Why shared-bucket + `origin_path` is actually safe

`eis-cloudfront`'s exported OAC bucket-policy statement scopes `Resource` to `"${bucket_arn}${origin_path}/*"` (confirmed in `main.tf`), not the whole bucket — so this is real IAM-level isolation between portals sharing a bucket, not just CloudFront-routing isolation. The only way to break this is leaving `origin_path` empty (`""` resolves to a whole-bucket grant) — make it a **required, non-empty** field on your consumer variable, with a regex validation matching the module's own (`^/[^/].*[^/]$`, at least 3 chars, no trailing slash).

## The HCL pattern

```hcl
variable "portals" {
  type = map(object({
    bucket_key  = string
    hostname    = string
    origin_path = string   # REQUIRED, non-empty — see above
  }))
  validation {
    condition     = alltrue([for p in var.portals : can(regex("^/[^/].*[^/]$", p.origin_path))])
    error_message = "origin_path must be non-empty, start with '/', not end with '/' — empty grants the whole bucket."
  }
  validation {
    condition     = length(distinct([for p in var.portals : "${p.bucket_key}${p.origin_path}"])) == length(var.portals)
    error_message = "two portals must not share bucket_key+origin_path."
  }
}

module "cloudfront_portals" {
  source   = "git::.../eis-cloudfront.git?ref=vX.Y.Z"
  for_each = var.portals

  name = each.key   # NOT each.value.bucket_key — must be unique per instance, and bucket_key is now shared across portals

  s3_origin = {
    bucket_regional_domain_name = "${module.s3[each.value.bucket_key].name}.s3.${local.region}.amazonaws.com"
    bucket_arn                  = module.s3[each.value.bucket_key].arn
    origin_path                 = each.value.origin_path
  }
  # ... aliases, certificate_arn, geo_restriction, web_acl_arn, dns_records as usual
}

# Bucket policy grouped by BUCKET, not by portal — one aws_s3_bucket_policy per
# physical bucket, merging every sharing portal's OAC statement. Two policy
# resources on the same bucket is a last-writer-wins anti-pattern.
locals {
  portals_by_bucket = {
    for bk in distinct([for p in var.portals : p.bucket_key]) :
    bk => [for k, p in var.portals : k if p.bucket_key == bk]
  }
}
data "aws_iam_policy_document" "portals_bucket" {
  for_each = local.portals_by_bucket
  source_policy_documents = [for k in each.value : module.cloudfront_portals[k].s3_origin_bucket_policy_json]
  statement { # DenyInsecureTransport, Resource = [module.s3[each.key].arn, "${...}/*"]
  }
}
resource "aws_s3_bucket_policy" "portals" {
  for_each = local.portals_by_bucket
  bucket   = module.s3[each.key].name
  policy   = data.aws_iam_policy_document.portals_bucket[each.key].json
}
```

## Hostname naming — check the live Istio gateway config, don't invent one

The `aliases`/`hostname` label is a SEPARATE naming question from the bucket/origin_path structure above, and got this wrong once already (shipped as `broker-portal`/`member-portal`, no precedent anywhere, caught by review). The real, live, org-wide convention is `p<role>-<tenant>` — e.g. `pbroker-caa-stage`, `pmember-caa-stage` — confirmed consistent across every existing environment's `argocd/argocd/clusters/<cluster>/istio-gateway-cluster/values.yaml`. **Before naming a new portal hostname, grep the live Istio gateway `values.yaml` for the same role/tenant family first.** See [[caa_portal_hostname_convention]] for the full convention, its origin (the client's own architecture doc), and why upper environments use `<stage>.aws11.caa-eis.cloud` while the client's own equivalent domain (`caci.group.gca`) is lower-only by design (D-24) — don't port that domain to upper, only the naming pattern.

One ACM certificate per CloudFront distribution (AWS API constraint) — multiple hostnames need multiple SANs on ONE cert, never multiple certs. `eis-acm` hardcodes a single wildcard SAN with no override; a genuinely different domain (not just another label under the same zone) needs a module change first. See [[eis_cloudfront_portals_design_decisions]] §6.

## Bucket naming vs the deploy-role IAM wildcard

A shared bucket typically has NO portal-specific infix (e.g. just `portals`), which may miss a `${project_prefix}*portal-*` deploy-role wildcard (the same trap already hit twice on lower, COEXT-106533/106555). **Check first** whether the relevant deploy role's IAM policy JSON already carries explicit `*<bucket-name>`/`*<bucket-name>/*` ARNs alongside the wildcard (grep the role's policy file) before assuming you need to add them — on CAA upper it already did.

## Prove it on `eis-iac` dev first

Same pattern as every other module proof in this org: build a throwaway 2-distribution/1-bucket fixture on `eis-iac` dev before porting the shape to a real client env.
- Reuse an existing wildcard ACM cert if one already covers `*.<base-domain>` for a single-label subdomain — don't issue a new cert.
- Skip geo_restriction/WAF on the fixture if those are already proven by another fixture in the same repo — this fixture's only job is the bucket-sharing question.
- `terraform plan -out=tfplan` scoped with `-target` to just the new resources (avoids dragging along unrelated environment drift like EKS addon/AMI version bumps into your apply — this dir's plans commonly carry that noise).
- **Local apply on `eis-iac/terraform` only works from the actual canonical checkout path** — a relocated/renamed git worktree gets refused by the harness's R1 guard even when its path literally contains `projects/aws/eis-iac/terraform` as a prefix. See [[harness_apply_guard_gotchas]]. Don't waste time on worktree path tricks; hand the exact `terraform apply tfplan` command to a human if you can't run it yourself, same as any other repo.

## Renaming an ALREADY-APPLIED bucket-per-portal design to shared-bucket

This is a destroy+recreate of everything (buckets, distributions, OAC, CloudFront functions, Route53 records, bucket policies) — confirmed via the `tf-plan-auditor` agent on a real case: `16 add / 22 destroy`, zero stateful resources, every line traceable to the rename. Two things to check before applying:

1. **Rebase onto `main` first if the branch is stale** — a sibling MR that merged while yours sat open (e.g. a node-group resize) will show up as unrelated forced-replacement noise in your plan otherwise. Dispatch `tf-plan-auditor` to classify every changed resource as yours-vs-environment-carried before applying anything with a surprising destroy count.
2. **If the old buckets have ANY content — even your own earlier E2E test files — `terraform destroy` fails with `BucketNotEmpty`.** `eis-s3` has no `force_destroy`. Purge versions + delete markers first (needs write/Admin creds, not ReadOnly): see [[s3_versioned_bucket_purge]] for the one-shot `delete-objects` payload. Then re-request the apply — it resumes and completes the remaining destroys.
3. **A second, dependent MR left open across the rename (e.g. one adding `dxp_host`/API-path fields to the same `var.portals` object) will hit real conflicts on rebase**, not a clean auto-merge — `variables.tf`'s object-type block and `terraform.tfvars`'s map both need every field/validation from both sides unioned by hand, not picked from one side. The module call file itself may auto-merge cleanly if the two MRs touch disjoint arguments — but "auto-merged" only proves no textual conflict, re-read it and re-run `terraform validate` + `pre-commit` before trusting it. See [[eis_cloudfront_portals_design_decisions]] "Rebasing a dependent MR" for the full walkthrough.

## E2E verification recipe (the parts that aren't obvious)

```bash
# 1. Upload distinct marker content per portal prefix
aws s3 cp - s3://<bucket>/<origin-path>/index.html <<< "PORTAL-A MARKER" --profile <profile>
aws s3 cp - s3://<bucket>/<origin-path-b>/index.html <<< "PORTAL-B MARKER" --profile <profile>

# 2. Invalidate both distributions, poll until Completed
aws cloudfront create-invalidation --distribution-id <id> --paths "/*" --profile <profile>

# 3. If a WAF with Bot Control (managed_rule_groups incl. AWSManagedRulesBotControlRuleSet)
#    is in BLOCK mode in front of these distributions, plain curl gets a WAF 403
#    ("Request blocked", NOT an S3/OAC 403) before ever reaching your isolation logic.
#    Spoof a real browser UA:
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
curl -sS -A "$UA" https://<hostname>/

# 4. If testing from corp VPN and the env has both a public+private hosted zone of the
#    identical name with a private wildcard record, your resolver will hit the PRIVATE
#    zone instead of CloudFront — see [[caa_upper_public_edge_constraints]], NOT CAA-specific.
#    Force the real CloudFront IP without touching /etc/hosts:
CF_IP=$(dig +short <distribution-id-domain>.cloudfront.net | head -1)   # the raw *.cloudfront.net domain, not the alias
curl -sS -A "$UA" --resolve <alias-hostname>:443:$CF_IP https://<alias-hostname>/

# 5. Confirm real isolation, not just "it looks right":
#    - direct S3 on both prefixes -> expect 403 (OAC-only, no bypass)
curl -o /dev/null -w "%{http_code}\n" https://<bucket>.s3.<region>.amazonaws.com/<origin-path>/index.html
#    - cross-path attempt through the WRONG distribution -> expect 403 (origin_path is
#      server-side fixed per distribution, not viewer-controllable — this is a genuine
#      structural guarantee, not just a happy-path result)
curl -o /dev/null -w "%{http_code}\n" -A "$UA" --resolve <alias-A>:443:$CF_IP_A "https://<alias-A>/../<origin-path-B>/index.html"
#    - inspect the actual bucket policy, confirm each statement's Resource is scoped
#      to its own prefix and its own distribution's SourceArn, not the whole bucket:
aws s3api get-bucket-policy --bucket <bucket> --profile <profile> --query Policy --output text | python3 -m json.tool
```

## Customer-hosted alias (a domain the CUSTOMER's DNS owns, e.g. `.pt`)

Reference: COEXT-110386, CAA upper/stage MR !184 (`pre.ca-caci-seguros.pt` / `pre.ca-caci-portugal.pt`).

**Hard CloudFront facts. Check these before proposing anything:**
- An alternate domain name needs a **publicly trusted** cert (Mozilla CA list) whose SAN covers it. Self-signed certs and client private-CA certs are rejected, so "self-signed for now" is never a stopgap on CloudFront.
- A distribution has exactly **ONE viewer cert** for all its aliases. A customer's cert for their domain can't cover your stage names, so the customer alias can't be added to an existing portal distribution. Give it **its own distribution** serving the same content.
- The cert must be in **us-east-1**. Imported RSA can be up to **4096** bits. ACM only *issues* up to 2048, which doesn't matter for an import.
- You can't Terraform a DNS record in a zone you don't host. Check who owns the zone with `dig NS <domain>` and `dig CAA <domain>`. The customer publishes the CNAME; you hand over `d*.cloudfront.net`.
- The `d*.cloudfront.net` name is random and assigned at create time, so there's nothing to give the customer before the apply. It doesn't change when you later change aliases or the cert.

**Pattern (all in the consumer, no module change needed with eis-cloudfront v1.2.1):**
1. Add a new `var.portals` entry with the same `bucket_key` + `origin_path` as the portal it mirrors, plus `mirror_of = "<that portal>"`. Relax the "unique bucket_key+origin_path" validation to non-mirror entries only, and validate that `mirror_of` points at a non-mirror with identical bucket/prefix. The OAC Sid comes from `title(name)` minus hyphens (`pt-member` → `AllowCloudFrontOACPtMember`), so there's no duplicate-Sid clash in the merged bucket policy.
2. **Day 1: placeholder alias in your own zone** on the existing wildcard cert (`pmember-caa-pt.stage…`). eis-cloudfront requires ≥1 alias + a cert, so this is how the distribution exists and the CNAME target is fixed before the customer's cert arrives.
3. Add optional `external_alias` + `certificate_arn`, validated to be set together and the ARN to be us-east-1. In the module call: `aliases = external_alias != null ? [external_alias] : [placeholder]`, `certificate_arn = coalesce(certificate_arn, <wildcard>)`, `dns_records = external_alias != null ? null : {...}` (the customer publishes the record). The cutover is then tfvars-only.
4. Add an output mapping `{ for k, m in module.cloudfront_portals : k => m.distribution_domain_name }` so the Atlantis apply comment prints the CNAME targets.

**The cert (CSR path):** the customer's public CA signs a CSR. Either side can generate it. **Agree on ONE CSR first**: two CSRs means two private keys, and only one gets signed (this happened). Typical subject: `C/O/OU/CN` (the CA asked for CN, and OV public CAs want O/C), with SANs for every alias and `basicConstraints=CA:FALSE`. Once the signed cert and chain are back: `aws acm import-certificate --region us-east-1`, and later renewals re-import to the same ARN. After import, ACM never exports the key again. Store the key using the account's existing convention (CAA: Secrets Manager `aws11caa/ssl/<domain>`, see [[caa_ssl_secret_convention]]). Keep it out of TF state.

**Expected first plan:** N× (distribution + OAC + spa-rewrite function + A/AAAA for the placeholder), `~` the bucket policy in place (it renders as all statements removed → `(known after apply)` because the new distribution ARNs are unknown; the real policy keeps every statement), and **zero** changes to the existing portal distributions.

## Related

- [[caa_pt_portals_csr_cloudfront]] — the live .pt instance of the customer-hosted-alias pattern
- [[eis_cloudfront_portals_design_decisions]] — full decision record, the corrected topology
- [[caa_portal_hostname_convention]] — the p<role>-<tenant> hostname convention and its origin
- [[s3_versioned_bucket_purge]] — the one-shot purge technique
- [[waf_bot_control_blocks_nonbrowser_ua]] — why plain curl 403s against an enforcing WAF
- [[caa_upper_public_edge_constraints]] — VPN split-horizon DNS, generalized beyond CAA
- [[harness_apply_guard_gotchas]] — why you can't dodge the local-apply guard with a relocated worktree
- [[atlantis_job_log_browser_read]] — reading a raw Atlantis job log when given a bare job URL
- [[atlantis_single_lock_cross_mr]] — if another open MR on the same stack holds the plan lock
- [[aws_profiles]] — CAA Upper (144905517910) account access, ReadOnly vs Admin
