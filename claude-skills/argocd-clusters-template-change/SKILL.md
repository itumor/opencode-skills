---
name: argocd-clusters-template-change
description: "Safely change the EIS ArgoCD cluster-values Copier template (iac/argocd/template/clusters) — add or fix a question, absorb a cluster's hand-edits back into the template, or make copier update safe for a live cluster. Use when asked to 'add X to the clusters template', 'parameterize this per-cluster value', 'why does cluster Y differ from the template', 'backfill cluster Z to the current template version', or when reviewing an MR that touches copier.yml or template/{{ project_slug }}/. Also use before enabling any copier validator, and before any copier update against a live cluster. Encodes the two invariants that silently destroy config (config/dir lock-step, Helm list replacement), the Copier-9 gotchas that make a change look correct while doing nothing, the live-parity proof that measures coverage, and the four answers that change live state if left at their defaults. Reference run: GENESIS-429534 (MR !12, V2.2.0, 95 questions, all nine live clusters proven renderable)."
---

# Changing the ArgoCD clusters Copier template

Template: `iac/argocd/template/clusters` (own git repo, semantic-release, `tagFormat: "V${version}"`).
Consumer: `iac/argocd/argocd` — `clusters/<cluster>/` per-cluster values trees for the multi-cluster hub.

**In the argocd repo, merge is deploy.** A template change is inert until someone runs
`copier update`, but the moment they do, the rendered diff goes live on the next ArgoCD
sync. Everything below exists because of that.

---

## The two invariants that silently destroy configuration

### 1. Config key ↔ values dir must stay in lock-step

`apps/appsets/all-components-appset.yaml` builds its component list from a git **directory**
generator over `clusters/<cluster>/*`. Therefore:

| Situation | What happens |
|---|---|
| Config key, no values dir | **No Application at all.** Silent no-op, not an error. |
| Values dir, no config key | Application IS created, but namespace = dir name and syncWave 0. |

This is not theoretical. `kubernetes-dashboard`, `observascope-minio`, `metallb`, `etcd` and
`coredns` were "configured" on 6–7 clusters each and deployed **nowhere** — 32 of the 46 dead
config keys in the hub repo, unnoticed across nine clusters. `aws0prefdeveks01/velero-ops` is
the other direction.

So: adding a component means **three** things — config entry (namespace **and** syncWave), a
values dir, and a `ci/scenarios/*.yml` entry that turns it on. `ci/check-lockstep.py` enforces
the first two on every render. Run it against the *old* tag first to see it reproduce the bug
you are fixing; that is how you know the gate works.

### 2. Helm replaces lists, merges maps

A key the template emits **as a list** must be answer-driven. There is no free valueFile slot
in the appset (it layers exactly three), so an override elsewhere would obliterate the
template's own entries rather than extend them.

The cautionary case is live: `aws0caatesteks01/oidc/values.yaml` restates ~900 lines of
`rbac.bindings` to change one group, and in doing so **drops the chart's
`oc-cluster-editor-2` binding**. Nobody noticed.

Trap keys, by name: `rbac.bindings`, `oneSuiteDashboardConfig.namespaces`, `secrets`,
`alb.targetGroupARNs`, `externalServices`, `endpoints`, `channels`, `routes`.

For a key the template does **not** emit, use the `extra_values` answer (free-form, keyed by
file path). It may only introduce **new top-level keys** — extending an existing one produces a
duplicate YAML key, and PyYAML, Helm and Kubernetes all keep the *last* silently, replacing the
whole mapping. `ci/check-duplicate-keys.py` makes that a hard failure.

---

## Copier gotchas that make a change look correct while doing nothing

| Gotcha | Detail |
|---|---|
| `validate:` / `pattern:` / `max_length:` | **Not Copier 9 keys.** Silently discarded. Only `validator:` works. See [[copier-validate-keys-inert]]. |
| Activating a dormant validator | Can block live data. The inert `^[a-z0-9]{3,5}$` on `project_code` would have made `aws0fvdemoeks01` (`fv`, 2 chars) unrenderable. **Render every existing consumer before enabling a validator.** |
| `when: false` questions | Never validated — copier skips them deliberately. Don't add a validator to `region_code`. |
| `{% import %}` root | Resolves from the template **repo root**, not `_subdirectory`. Shared macros go in `includes/` with `_exclude: [includes]`. This is what collapsed the oidc RBAC bodies 503 → 73 jinja lines. |
| `to_nice_yaml` on an empty list | Emits a bare `[]` on its own line → **invalid YAML**. Every dump needs `{% if answer %}` around it. The `minimal-poc` CI scenario (all lists empty) is the guard. |
| `to_nice_yaml` default indent | Is 4, which mangles nested sequences. Always `to_nice_yaml(indent=2) | trim | indent(N, first=True)`. The `| trim` is load-bearing under `trim_blocks`. |
| Macro trailing newline | A macro whose body ends before `{% elif %}`/`{% endif %}` emits an extra newline. Use `{%- elif %}` / `{%- endif %}` or you get a blank line per invocation. |
| Generating jinja from Python | If you build template text with `%`-formatting, `{{{{` stays `{{{{` — that is **not** an escape. Only `str.format` treats braces specially. Produces `expected token ':', got '}'`. |
| Question count | 95 and climbing. The fleet workflow is `--data-file <cluster>.yml`; keep the interactive path viable for the ~12 identity questions only. |

---

## Verification protocol

Three layers, in order. Skipping layer 1 makes layers 2–3 unreadable.

### Layer 1 — control diff at default answers

Render the same minimal answers file at the current tag and at your branch. **Only comment
changes and your intended edits may appear.** Filter comments explicitly, because the signal is
otherwise buried:

```bash
diff -ru "$BASE/<slug>" "$HEAD/<slug>" | grep -E '^([+-][^+-]|Only)' | grep -vE '^[+-]\s*#'
```

### Layer 2 — CI gates

```bash
bash ci/mock-test.sh    # all scenarios: no unrendered markers, no leaked literals,
                        # YAML parses, no duplicate keys, lock-step passes
```

Keep the matrix as a **bash loop inside `ci/mock-test.sh`**, not a GitLab `parallel:matrix` —
one job, one `pip install`, and a local run reproduces CI exactly. The previous matrix attempt
was reverted (`3df854a`) because it did neither.

The leaked-literal guard catches removed toxic defaults and deleted dead blocks. Exclude
`.copier-answers.yml` from it — that file is a verbatim echo of the scenario input, not
template output.

### Layer 3 — live-parity proof (this is the coverage measurement)

Render **every** live cluster from its own `.copier-answers.yml` and compare by **parsed-YAML
equality, per file**. A text diff is useless here: `to_nice_yaml` style, key ordering and
comment moves swamp it.

```bash
for C in $(ls "$ARGO/clusters"); do
  copier copy --defaults --trust --data-file "$ARGO/clusters/$C/.copier-answers.yml" \
    --vcs-ref HEAD . "$W/$C" || echo "RENDER FAIL $C"
done
```

Then per file: `yaml.safe_load(live) == yaml.safe_load(new)`. Where they differ, flatten both to
dotted paths and print only the keys that disagree. Classify every residual into exactly one of:

1. **Intended** — a block you deliberately deleted.
2. **Correction** — the render fixes stale live data (e.g. a `domainSuffix` that no longer
   matches its own cluster's domain). Say so in the MR; it is a live change.
3. **Order-only** — same set, different sequence. No manifest effect for one-object-per-entry
   lists, but it shows in the diff, so name it.
4. **Layering-equivalent** — the template puts a key in the cluster-wide file where the live
   cluster has it in the component file. Helm merges maps, so the result is the same.
5. **Known limitation** — see below.
6. **Real gap** — fix it. Expect several; the GENESIS-429534 run found **seven** defects this
   way that all three CI gates had missed.

Report the result as a per-cluster table (`N of M files identical`). That is the answer to
"have we covered everything", and it is the only honest one.

### Generating or previewing a `.copier-answers.yml` — `tools/answers.py`

`tools/answers.py` (this repo, MR [!13](https://sfo-cvdevopsgit01.eqxdev.exigengroup.com/iac/argocd/template/clusters/-/merge_requests/13),
branch `NOJIRA-001_copier_answers_tool`, **open, not yet merged as of 2026-08-25**) packages
the Layer 1/3 "scratch-render, inspect the resolved answers" pattern above into a reusable
tool, and generalizes it to **new** clusters, not just existing ones:

- discovers ~18-20 answers straight from AWS instead of hand-typing them — account id, EKS
  cluster+version, internal ALB DNS, Istio target-group ARN, velero/Loki buckets, Cognito
  domain, hosted zone. This is exactly the set that has **no** `copier.yml` default because
  a wrong value renders valid-looking YAML that only fails at pod start
  (`target_group_arn`, `internal_alb_dns`, `aws_account_id`)
- `--from-answers <sibling>/.copier-answers.yml` seeds the rest from an existing cluster
- `--preview-answers [path]` runs the real `copier` CLI into a throwaway temp dir and
  copies out the fully-resolved `.copier-answers.yml` — same mechanism as the Layer 3
  `copier copy --data-file ...` loop above, but for a cluster with no `.copier-answers.yml`
  yet, and without needing a full `clusters/<slug>/` checkout to diff against
- `--render <argocd-repo>` does the same render and additionally installs
  `clusters/<slug>/` plus the two `bootstrap/` files (see "What the template cannot do"
  below) — the install this skill's own onboarding checklist still requires by hand today

Verified live, byte-for-byte, against `aws06nnljdeveks01` at `--vcs-ref V2.1.2` — see
[[project_argocd_copier_answers_tool]]. Once !13 merges, this is the preferred way to
produce a new cluster's initial `.copier-answers.yml` rather than hand-copying values out
of the AWS console.

---

## Before any `copier update` against a live cluster

Four answers change live state if left at their defaults. Pin them in
`.copier-answers.yml` **first**:

| Answer | Risk |
|---|---|
| `image_registry` | Six clusters use the shared `sfoeisgennexus01-docker-group.exigengroup.com`, not the per-client Nexus. Default repoints **every image pull**. |
| `velero_deploy_node_agent` | `components/velero/values.yaml` defaults it **true**, so fvdemo/iac/pref *do* run the node agent today. Default turns off file-system backups. |
| `alb_use_target_group_list` | Singular `alb.targetGroupARN` and plural `alb.targetGroupARNs` produce **different TargetGroupBinding names** (`ingress-tg` vs `ingress-tg-0`). caa/axajp/fvdemo run the list form; switching recreates the binding and briefly deregisters targets. |
| `grafana_ldap_enabled` | The template disables Grafana LDAP; caa still runs it and keeps an `ldap` secret. |

Then: **diff every rendered file**, not just the ones you expected to change.

The answers file lives **inside** the cluster dir, so:

```bash
copier update --vcs-ref V2.2.0 --trust --defaults \
  --data-file <cluster>.yml --answers-file <cluster>/.copier-answers.yml .
```

Run it from the directory that *contains* the cluster dirs (`clusters/` in the argocd repo).

**`aws0axajpdeveks01` cannot be updated as-is.** Its `_src_path` is a local absolute path on
one workstation, and it carries five answers that no longer exist
(`enable_external_services`, `enable_grafana_cognito`, `enable_oidc_rbac`, `image_registry`,
`registry_secret_path`) — artefacts of being rendered off an unmerged branch HEAD. Fix
`_src_path` and reconcile those keys first.

---

## What the template cannot do

- **A component outside the catalog** (caatest's `filebeat`/`logstash`, iac's `aws-inventory`)
  needs a config entry **and** a values directory, and **Copier cannot generate directories
  from a list answer** — the file tree is static, only path *names* can be Jinja. So these stay
  two hand-created files. The lock-step gate makes it safe: adding one half fails the render.
- **Istio version keys** (`istiod_1_29_0` and friends). An Istio minor bump is a coordinated
  fleet change and `components/istio-*/Chart.yaml` carry four aliased pins; the template key
  rename is the smaller half. Do it with the upgrade.
- **`velero.schedules`.** `components/velero` has no `schedules` values key at all —
  `templates/schedules.yaml` is a hardcoded manifest carrying iac-specific namespaces to every
  velero cluster. Chart change first.
- **Anything in `bootstrap/`.** The template only writes `clusters/<slug>/`. The bootstrap
  record and the hub cluster Secret are hand-written and have been forgotten in production
  (`3779df1` → `fd9149b`). `_message_after_copy` spells out the checklist; it is a reminder,
  not a gate.

---

## Conventions

- Branch `<TICKET>_<slug>`, off `origin/main`.
- Conventional commits, **not squashed** — `@semantic-release/release-notes-generator` sections
  them and `issuePrefixes` already covers `COEXT-`/`GENESIS-`/`NOJIRA-`/`EISSAASDEV-`.
  `feat` → minor, `fix`/`chore` → patch, `docs` → none. Release is **manual** on `main`.
- Prefer **additive**: keep existing scalar answers, add lists/extras alongside. A breaking
  rename forces answer migration on every already-templated cluster for no functional gain.
- Group `copier.yml` with banner comments (identity · networking · secrets · optional
  components · RBAC/SSO · node placement · sizing · per-cluster lists · per-component parity ·
  escape valve). At 95 questions this is the only thing keeping it navigable.
- Open the MR, **do not merge** — hand off for review (standing IaC gate).

## Related

- [[argocd-clusters-template-lockstep]] — the hub-side mechanics
- [[copier-validate-keys-inert]] — the Copier-9 validation trap
- [[project_genesis429534_template_coverage]] — the reference run and what is still open
- [[project_argocd_copier_answers_tool]] — `tools/answers.py` / MR !13, AWS-discovery +
  `--preview-answers`
- `argocd-cluster-onboarding` skill — the end-to-end onboarding this template feeds
- `argocd-ci-pipeline-diagnosis` skill — for the consumer repo's CI
