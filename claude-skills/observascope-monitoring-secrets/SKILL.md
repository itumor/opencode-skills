---
name: observascope-monitoring-secrets
description: Create/verify the per-cluster monitoring secrets that ArgoCD's observascope-oss + gen-dashboard components read via External Secrets Operator — <cluster>/monitoring/observascope-oss/{objstore,ldap,slack-api-urls} and <cluster>/monitoring/gen-dashboard/registry. Use when onboarding a cluster's monitoring stack ("add the component secrets", wiki step 4.1), when Thanos/Grafana/Alertmanager won't start on a new cluster, when an ExternalSecret in namespace monitoring won't sync, when asked where these secret values come from, or when adopting an already-hand-seeded objstore secret into Terraform. Covers the ESO dataFrom.extract key contract, the exact objstore.yml byte shape, which values are derivable vs genuinely human-sourced, and the Terraform-managed objstore path shipped in client template v2.7.0.
---

# observascope-oss / gen-dashboard monitoring secrets

Four secrets per cluster. **Only `objstore` is Terraform-managed** (template v2.7.0+). The other
three hold real credentials and stay out-of-band.

## The ESO contract (get this wrong and it fails at pod-start, not sync-time)

`argocd/argocd/components/observascope-oss/templates/secrets.yaml` — when a `secrets:` entry has
no `properties:`, ESO uses `dataFrom.extract`, so **every top-level key of the AWS/Vault secret is
copied verbatim** into the k8s Secret `<name>-secret` in namespace `monitoring`. A misspelled key
does not error; it lands under the wrong name and the consumer fails later.

| Secret | Required top-level key(s) |
|---|---|
| `objstore` | exactly one: `objstore.yml` |
| `ldap` | exactly one: `ldap-toml` (full Grafana `ldap.toml` text) |
| `slack-api-urls` | **one key per Slack channel name**, value = webhook URL |
| `gen-dashboard/registry` | one: `config` (a `.dockerconfigjson` blob) |

Backend is per-cluster: `argocd/argocd/clusters/<cluster>/values.yaml` →
`secretBackend.backendType` (`SecretsManager` | `vault`). Only `aws0v20perfdeveks01` is Vault
(path prefix `secret2/data/rnd/cicd/3.0/`). Read it; never assume.

## Where each value comes from

**`objstore` — 100% derivable, do NOT hand-create it any more.** Terraform owns it. Fields:
`bucket`, `aws_sdk_auth: true` (IRSA, no access keys), `endpoint`, `signature_version2: false`.
Ground-truth byte shape — key order matters for adoption parity, and there is **no `region` key**:

```yaml
type: s3
config:
  bucket: aws06nnljdevobservascope
  aws_sdk_auth: true
  endpoint: s3.ap-northeast-1.amazonaws.com
  signature_version2: false
```

Bucket name = `<prefix_short><key>` from the `eis-s3` module, e.g. `aws02afadevobservascope`.
`prefix_short` = `<region_code><project_code><stage>` from `eis-env-common-utility`
(`us-east-1`→`aws02`, `us-west-2`→`aws0`, `ap-northeast-1`→`aws06`). **Region trap:** use the
project's own region, not the tfstate backend bucket's region — they differ.

**`ldap` — human-sourced, and only if the cluster actually uses LDAP.** Gate on
`grafana.ldap.enabled` / `auth.ldap.enabled` and on `- name: ldap` being in that cluster's
`secrets:` list. caa uses it; nnlj/axajp do not (Cognito OAuth instead). CN group names
(`grafana_<code>_admin`, `grafana_<code>_rw`) and the OU come from **the Jira ticket where the AD
groups were created**. The bind DN / bind password / LDAP host are documented **nowhere in the
repo** — get them from whoever owns EIS corporate AD. Never guess a host.

**`slack-api-urls` — channel names derivable, webhooks are not.** Read the channel list from
`argocd/argocd/clusters/<cluster>/observascope-oss/values.yaml` →
`observascope-oss.alertmanager_slack.channels[].name`. The webhook URL only comes out of the Slack
OAuth install flow in a browser — no API mints it. `oc-global-alerts` is the same URL fleet-wide,
so usually only the new `oc-<cluster>-alerts` needs a fresh one.

**`gen-dashboard/registry`** — shared EIS Nexus pull credential, not per-cluster material. Copy it
from a known-good cluster rather than retyping a docker config.

Helper for the three human-sourced ones:
`solutions/onesuite-provisioning/toolkit/scripts/observascope-secrets.sh` (idempotent, never puts
secrets in argv). Note it is being actively extended; re-read it before relying on any flag.

## Terraform-managed objstore (client template v2.7.0+)

`lower/<stage>/services/observascope.tf` + `variable "observascope"`. **Off by default.** Opt in
per project — use a `*_custom.auto.tfvars` so it stays outside `copier update`'s 3-way merge:

```hcl
observascope = { manage_objstore = true }
```

`bucket_key` defaults to `"observascope"`, matching the `s3` map key.

### Greenfield cluster (no secret exists yet)

1. `git fetch --prune`; ensure the project is on template >= v2.7.0 (`copier update --vcs-ref vX --defaults --trust`).
2. Add the opt-in tfvars. Run `pre-commit run --files <changed>`.
3. **Merge gate — prove it does not already exist**, or apply fails `ResourceExistsException`:
   ```bash
   aws secretsmanager describe-secret --profile <p> --region <r> \
     --secret-id <cluster>/monitoring/observascope-oss/objstore
   ```
   Expect `ResourceNotFoundException`.
4. Expect plan `2 to add` (secret + version). `secret_string` shows `(known after apply)` when the
   bucket is created in the same apply — so verify the **shape** afterwards, not just presence.

### Adopting an already-hand-seeded cluster (nnlj, caa, axajp — NOT yet done)

Import **both** resources. Importing only the secret makes the next apply `PutSecretValue` over
the live value. Capture the live body first and diff it — hand-seeded secrets can each differ.

```bash
SP=$(yq -r '.secretPath' argocd/argocd/clusters/$C/observascope-oss/values.yaml)   # never construct it
aws secretsmanager get-secret-value --secret-id "$SP/objstore" --query SecretString --output text | jq -r 'keys[]'
ARN=$(aws secretsmanager describe-secret --secret-id "$SP/objstore" --query ARN --output text)  # ARN incl. random -XXXXXX suffix
aws secretsmanager list-secret-version-ids --secret-id "$ARN" \
  --query "Versions[?contains(VersionStages,'AWSCURRENT')].VersionId | [0]" --output text
```
`import` id for the version is `<arn>|<version-uuid>`. **Acceptance gate:** the *version* shows no
change and the stage is `0 to add, 0 to destroy` — a benign in-place `~ tags` on the secret is
expected (provider `default_tags` hitting a previously untagged secret). Do not demand a literally
empty plan.

## Three structural traps in the Terraform (each verified the hard way)

1. **Never put the knob on `var.eks`.** It is a strict `map(object({...}))` and Terraform
   *silently discards* undeclared attributes — the knob reads empty forever, plan stays clean, and
   the secret lands outside the ESO IRSA scope. Use a separate `variable "observascope" { type = any }`
   merged over defaults (the `velero` idiom), or declare it with `optional()`.
2. **Build the YAML inside the resource body, not a top-level `local`.** Locals are evaluated on
   every plan walk regardless of `for_each`, so a local indexing `module.s3[...]` fails
   `Invalid index` in any stage lacking that bucket key *even with the feature off*.
3. **`recovery_window_in_days = 0`.** The payload is fully reconstructible from code, so a recovery
   window buys nothing — and a non-zero window name-squats the path, so a destroyed-and-rebuilt
   stage cannot recreate the secret and monitoring stays down for the whole window.

Use a heredoc, not `yamlencode()` — yamlencode sorts keys alphabetically and won't reproduce the
fleet's byte order, which is what makes adoption a no-op.

## Verify (do all three)

```bash
# 1. key contract
aws secretsmanager get-secret-value --profile <p> --region <r> \
  --secret-id <cluster>/monitoring/observascope-oss/objstore \
  --query SecretString --output text | jq -r 'keys'      # exactly ["objstore.yml"]

# 2. the bucket it names actually exists
aws s3api head-bucket --profile <p> --bucket <parsed bucket>

# 3. ESO actually synced it (the real proof)
kubectl get externalsecret,secret -n monitoring | grep -E 'objstore|ldap|slack-api-urls|registry'
kubectl describe externalsecret objstore-secret -n monitoring | tail -15   # SecretSynced True
```

The secret is **inert until the cluster has an `argocd/argocd/clusters/<cluster>/` directory** —
creating it ahead of ArgoCD onboarding is fine and expected.

## Plan-role gotcha that looks like your bug but isn't

`terraform plan` failing to refresh **any** `aws_secretsmanager_secret_version` with
`AccessDeniedException ... secretsmanager:GetSecretValue` is an IAM gap, not a resource problem:
the Atlantis *plan* role gets `ReadOnlyAccess`, which **excludes** `GetSecretValue`. The only grant
is `lower/infra/bootstrap/files/iam/state_access.json`. Template <= v2.5.0 scoped it
`${project_prefix}*eks*/*` — requiring a literal `eks`, so RDS-style secrets were denied. Widened
to `${project_prefix}*/*` in v2.6.0. Fixing it needs a **`lower-infra-bootstrap` apply**, not just
a merge. See memory `atlantis-plan-role-cannot-read-secrets`.

## Reference run

COEXT-107164 / AFA (`aws02afadeveks01`, acct 060116865631, us-east-1): template MR !42 (v2.7.0),
project MR !7 merged + applied 2026-08-27, secret live and byte-verified. nnlj / caa / axajp still
hand-seeded and NOT adopted.
