---
name: eis-opensearch-irsa-sigv4
description: >
  Provision an AWS-managed OpenSearch domain in an EIS environment that EKS workloads reach
  with their IRSA workload role over SigV4 — no fine-grained access control, no master user,
  no static credentials. Use when a ticket asks to "provide an AWS env with OpenSearch",
  move apps off SOLR, "grant each workload role es:ESHttp* on the domain", wire
  genesis.search.backend=opensearch / eis.platform.opensearch.auth.type=aws, or stand up a
  VPC-private search domain for a client/POC env. Covers the eis-opensearch v1.0.1+ module
  wiring, the ArnLike access-policy pattern that decouples the domain from the workload list,
  the service-linked-role race on the first VPC domain in an account, the irsa_custom
  unknown-value cascade, and the signed/unsigned E2E proof.
---

# OpenSearch for EKS workloads over IRSA + SigV4

Reference delivery: **GENESIS-439567**, v20-sandbox `aws0v20devos01` for the Amber apps.
See [[project_genesis439567_opensearch_amber]] for that run's live state.

## 1. Decide the auth model first — it drives everything

If the ticket says *"each application accesses OpenSearch through its workload IAM role using
temporary credentials and SigV4"*, then:

- **FGAC off.** The domain access policy is the only authorization layer.
- **No master user, no Secrets Manager credential.** Nothing to rotate.
- **No Dashboards login for humans.** Say this out loud to the requester — with FGAC off a
  person hitting the endpoint gets 403. If the test team needs Dashboards, that is a
  different design (FGAC + an IAM master role, or SAML) and should be agreed before build.
- SAML requires FGAC, so `advanced_security_enabled`, `create_saml_options` and
  `saml_enabled` all move together to `false`.

## 2. Use the module, and know its version floor

`eis-opensearch` **v1.0.0+** is what makes this shape possible — before it, the module forced
FGAC on, rejected `GENESIS-` issue keys, and could not emit an access-policy `condition`.
Pin **v1.0.1 or later**: v1.0.0's upstream pin (`terraform-aws-modules/opensearch ~> 2.9.0`)
requires `hashicorp/aws >= 6.41`, which would force a stack-wide provider bump on a fleet
sitting at 6.28/6.38. v1.0.1 re-pins upstream to `~> 2.5.0` (`>= 6.28`).
See [[eis-opensearch-module-genesis439567-release]].

Key inputs that differ from the module's production-shaped defaults:

```hcl
opensearch_advanced_security_enabled = false   # no FGAC
opensearch_create_saml_options       = false   # SAML requires FGAC
opensearch_saml_enabled              = false
opensearch_custom_endpoint_enabled   = false   # else needs route53_private_zone_id + ACM ARN
opensearch_dedicated_master              = false  # small/POC domains
opensearch_multi_az_with_standby_enabled = false  # needs 3 AZs + 3 dedicated masters
opensearch_enable_index_slow_logs  = false
opensearch_enable_search_slow_logs = false
opensearch_enable_audit_logs       = false     # AUDIT_LOGS REQUIRES FGAC — leaving this
                                               # true with FGAC off fails at apply
```

`ES_APPLICATION_LOGS` has **no toggle** — the module always publishes it, so expect one
CloudWatch log group plus a log-resource-policy even when you asked for no logging.

## 3. The access-policy pattern worth copying

Do **not** hardcode workload role ARNs in the domain policy. Grant to a role-name *pattern*:

```hcl
opensearch_access_policy_principal_type        = "AWS"
opensearch_access_policy_principal_identifiers = ["*"]
opensearch_access_policy_actions = [
  "es:ESHttpGet", "es:ESHttpHead", "es:ESHttpPost", "es:ESHttpPut", "es:ESHttpDelete",
]
opensearch_access_policy_conditions = [{
  test     = "ArnLike"                     # NOT StringLike — see below
  variable = "aws:PrincipalArn"
  values   = ["arn:aws:iam::<acct>:role/<eks_name>-amber-*-Role"]
}]
```

Because IRSA role names are deterministic (`eis-eks` sets
`iam_role_name = "${var.eks_name}-%s-Role"` with `use_name_prefix = false`), **adding another
app later is a tfvars edit that never re-applies the domain.** That property is the whole
point of the pattern — it decouples domain lifecycle from the app roster.

**`ArnLike`, not `StringLike`.** `aws:PrincipalArn` is an ARN-typed condition key; a
`StringLike` on it raises the IAM Access Analyzer finding
`STRING_LIKE_OPERATOR_WITH_ARN_CONDITION_KEYS`. `ArnLike` matches the same values.

## 4. IRSA roles when the app names aren't known yet

These tickets usually sequence OpenSearch *before* the app deploy, so the namespace and
ServiceAccount don't exist yet. `eis-eks` supports wildcards in the trust subject on
**v2.3.0 and later** (`trust_condition_test = strcontains(...,"*") ? "StringLike" : "StringEquals"`).

**Don't guess per-app ServiceAccount names.** GENESIS-439567's first pass pinned two
placeholder SAs (`amber-core`/`amber-ms-customer`) before the real namespace existed. When it
came up, it had ~90 per-microservice SAs (`billing-app`, `persona-provider-search`, ...) —
none matched. If the requester can't name every SA yet, wildcard `service_account` rather than
invent names that won't exist.

Pin whichever of {namespace, service_account} you actually know; wildcard the other — never
both:

```hcl
workloads = {
  shared = { namespace = "certification2", service_account = "*" }
}
```

Wildcarding **both** grants the role to any SA in any namespace on the cluster. Guard against
that specific combination in `variables.tf`, not a blanket ban on `service_account = "*"`
(that also blocks the legitimate namespace-pinned case):

```hcl
validation {
  condition = alltrue([
    for k, v in var.opensearch : alltrue([
      for wk, wv in v.workloads : !(wv.namespace == "*" && wv.service_account == "*")
    ])
  ])
  error_message = "workloads[*] must not wildcard both namespace and service_account."
}
```

**The wiring layer may already prefix the workload key.** If your stack composes the
`irsa_custom` key as `"amber-${wk}"` (v20-sandbox's `locals.tf`/`outputs.tf` does this, to
keep the domain's `-amber-*-Role` ArnLike pattern matching), your `workloads` map key must be
*bare* (`shared`, not `amber-shared`) — the prefix is added for you. Double-prefixing still
plans/applies fine, it's just an ugly role name (`aws0...-amber-amber-shared-Role`).

**Confirm the literal target namespace — don't infer it from an example.** An SA dump the
requester pastes to illustrate the naming pattern may come from a *different*, already-live
namespace than the actual deploy target. GENESIS-439567: the ~90-SA list was from
`certification`; the real target was `certification2`, which didn't exist yet
(`kubectl get ns` to confirm). Expect "not deployed yet" when you offer to run the E2E test —
that's not a blocker, it means the trust is correctly scoped to something that doesn't exist
to abuse yet.

## 5. Two traps that will show up in your plan

**The `irsa_custom` unknown cascade.** Adding *any* `irsa_custom` entry makes every consumer
of `eks.irsa.<x>.arn` render as `(known after apply)` — the EFS file-system policy typically
appears as being wholly deleted. Compose such ARNs from the cluster key instead. Full
mechanism and fix: [[eks-irsa-output-unknown-cascade]].

**Dependency cycle on the domain ARN.** The IRSA policy needs the domain ARN and the domain
policy needs the role ARNs. Break it by composing the domain ARN as a *string* from
account + region + computed name — never read it off `aws_opensearch_domain.*.arn`.

Also expect unrelated pre-existing drift to surface: touching lock files pulls other stacks
into Atlantis plan scope. Read every plan, including dirs your diff never touched
([[feedback_tf-plan-read-change-lines]], [[s3-ssec-block-stripped-by-terraform]]).

## 6. Verify the engine version before you promise it

A module regex accepting `OpenSearch_3.5` proves nothing about what AWS offers:

```bash
aws opensearch list-versions --profile <p> --region <r> --query 'Versions' --output text
```

`list-versions` has **no paginator**, so `--page-size` is rejected here — an exception to the
usual [[awscli-max-results-disables-pagination]] advice. If the requested version isn't
offered, say so on the ticket rather than quietly shipping a different one.

## 7. First VPC domain in an account fails once — that's expected

`ValidationException: ... you must enable a service-linked role ...`. The failed apply itself
triggers the SLR's async creation; simply re-run. Everything else in the apply already
landed. Details: [[opensearch-vpc-domain-provisioning-gotchas]].

## 8. Prove it end to end — both directions

A signed request returning 200 is only half the test.

```bash
aws opensearch describe-domain --domain-name <domain> --profile <p> \
  --query 'DomainStatus.{ver:EngineVersion,nodes:ClusterConfig.InstanceCount,proc:Processing,ep:Endpoints}'
```
Assert the version, node count, `Processing: false`, and a **VPC-only** endpoint.

Then from a throwaway pod whose SA is annotated with the workload role: a SigV4-signed
request must return **200**, and the same request **unsigned must return 403**. If the
unsigned call succeeds, the access policy is open and the design has failed. Run the negative
case using the node's own instance role — a principal that exists but does not match the
ArnLike pattern — which proves the condition is doing the work, not merely that signing works.

## 9. Hand off

Give the requester the endpoint, the workload role ARNs, and the exact ServiceAccount
annotation. App-side config (`genesis.search.backend=opensearch`,
`eis.platform.opensearch.endpoint`, `auth.type=aws`, shards/replicas) is delivery-owned, not
IaC — don't set it and don't claim it's done.

**Merge the MR.** An applied-but-unmerged MR leaves the resources live with no code on
`main`, so the next plan off `main` shows them as destroys
([[terraform-applied-unmerged-mr-trap]]).
