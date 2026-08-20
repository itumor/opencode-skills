---
name: argocd-ci-pipeline-diagnosis
description: Diagnose a red or slow GitLab CI pipeline in iac/argocd/argocd (render_manifests, pluto, checkov, kubeconform) and safely optimize the helm dependency fan-out. Use when an argocd MR pipeline fails on a chart download, DNS/network error, or takes >5 min per job; or when working GENESIS-429530 pipeline performance.
---

# ArgoCD CI pipeline: diagnosis and safe optimization

Repo: `/Users/eramadan/gitwork/iac/argocd/argocd` — GitLab project id **1547**, `iac/argocd/argocd`.
Owning perf ticket: **GENESIS-429530** (P0, Open). Background: memory `argocd-render-helm-dep-fanout`.

```bash
export GITLAB_HOST=sfo-cvdevopsgit01.eqxdev.exigengroup.com
unset GITLAB_TOKEN     # NEVER set it — a stale value overrides glab's own working token
```

## Pipeline shape

`.gitlab-ci.yml` (~1281 lines). Stages: render → validate → policy → test → security.

| Job | Script | Notes |
|---|---|---|
| `precheck_render_inputs` | — | runs `bash -n scripts/ci/render-all-helm.sh` (line 68) |
| `render_manifests` | `scripts/ci/render-all-helm.sh` | produces `.out/rendered.yaml`; `resource_group: manifest-firewall` |
| `pluto` | `scripts/ci/pluto-helm.sh` | deprecated-API scan |
| `checkov` | `scripts/ci/checkov-helm.sh` | slowest job |
| `kubeconform`, `kube_linter`, `kyverno`, `helm_unittest`, `quality_summary` | inline | all `needs: render_manifests` → **6 gates skip when render fails** |
| `*_playground` variants | same scripts, `CHARTS_ROOT=components-playground` | 18 fixed charts — **use as a load-free network probe** |

Four jobs pre-add the same 7 helm repos then `helm repo update` (lines 80–87, 325–332, 591–598, 732–739).

## Step 1 — Triage before you theorize

Do NOT call anything transient/flaky yet. See memory `feedback_partition-failure-populations`.

```bash
# full history with durations — status alone carries no signature
for p in 1 2 3; do glab api "projects/1547/jobs?per_page=100&page=$p"; done > /tmp/alljobs.json
```

Then partition:

1. **Pull the error line from every failure**, not just statuses. Group by signature, report counts per group. Two groups ⇒ two incidents, handle separately.
2. **Read duration independently of status.** Baseline green is **222–486 s**. Network-class failures ran **653–1280 s**. A failure at normal duration is almost never a network failure — in Aug 2026, 19 of 25 failures were a YAML bug at normal duration and only 6 were network.
3. **Check the playground sibling** to separate environment from workload: `render_manifests_playground` ~33–40 s healthy, **>100 s means you are inside a degradation window**.
4. **Check the MR state first** — `plan`/`apply` style comments on a merged/closed MR return confusing errors, and a red gate on an already-merged MR may be moot.

```bash
glab api "projects/1547/jobs/<id>/trace" > /tmp/t.log     # always redirect to a file
grep -E "^(Rendered|Skipped|Errors) |\[ERROR\]|i/o timeout|Could not resolve" /tmp/t.log
```

## Step 2 — Recognize the known failure modes

**A. Chart download / DNS timeout.** `dial tcp: lookup github.com on 192.168.8.24:53 ... i/o timeout`.
Resolver `192.168.8.24` = `hera.exigengroup.com` (BIND 9.9.12); container src `10.202.0.2` on runner **23** `sfo-cvdevopsgitwork01.sjclab.exigengroup.com`. Nine components pull tarballs from `github.com` — external-secrets is not special. A github.com tarball needs **two** names resolved: `github.com` **and** the redirect target **`release-assets.githubusercontent.com`** (not `objects.githubusercontent.com`).

Prove transient in-band, never with "I couldn't reproduce it":
- same helm process refreshes a host's index OK then times out on that same host;
- attempt N fails and N+1 succeeds on the identical tarball;
- an **unmodified** commit goes green on the same runner minutes later.

**B. Runner cannot resolve its own GitLab host.** Job dies in `get_sources`: `unable to access 'https://sfo-devopsgit01...': Could not resolve host`. Nothing to fix in code — retry, and escalate to network. Same resolver fault as A.

**C. Truncated terraform/helm binary** → see skill `atlantis-iac-binary-recovery`.

**D. Content bug masquerading as infra.** A malformed `clusters/*/<component>/values.yaml` fails `helm template` at *normal* duration. `git log -p` the file; look for the commit whose timestamp is seconds before the first failure.

## Step 3 — The structural defect (fixed by MR !361, verify before re-fixing)

`helm dependency build` ran once per **(cluster, component)** pair — 138 invocations for **25** distinct chart dirs. With `.gitignore:11-12` (`**/*.lock`, `**/*.tgz`) nothing is cached, no `cache:` block exists, and `grep -c retry .gitlab-ci.yml` = **0**. ~2300 external calls per job; one dropped lookup fails all 138 renders.

The three changes (applied identically to all three scripts):

1. **Memoize per chart dir** (`DEPS_BUILT`). Do **not** memoize failures — leaving them unmarked makes the next cluster retry, which absorbs transient errors for free.
2. **`helm dependency build --skip-refresh`** + widen the fallback grep to `out of sync with the dependencies file|no cached repository`.
3. **Seed the repo map from `helm repo list`** at startup, so the 7 CI-pre-added upstreams aren't re-added as duplicate `ci-*` aliases.

Two traps worth knowing:
- **The original retry fallback was dead code**: it only matched `out of sync with the dependencies file`, which requires a `Chart.lock` that `.gitignore` guarantees never exists.
- **`pluto-helm.sh` / `checkov-helm.sh` never deduped at all** — the accumulator appended the source file's indentation with the URL (`ADDED_HELM_REPOS="${ADDED}${url}\n  "`), so entries after the first stored as `"  <url>"` and never matched `grep -Fxq`. `render-all-helm.sh` used an associative array and was fine. This is where pluto's −91% came from.

## Step 4 — Test locally, correctly

Local defaults do **not** match CI. See memory `reference_zsh-reserved-vars`.

- CI runs **helm 3.14.4** + **bash 5.x** (Alpine). macOS `/bin/bash` is **3.2** and cannot parse `declare -A`. Use `/opt/homebrew/bin/bash`.
- Get the real helm: `curl -sSL https://get.helm.sh/helm-v3.14.4-darwin-arm64.tar.gz | tar xz`
- The Bash tool runs **zsh**, which does not word-split unquoted vars — `helm repo add $pair` silently passes one arg. Put harnesses in a real `.sh` file and run with bash.
- `timeout` does not exist on macOS.

**Never run the render script in the live working tree.** `helm dependency build` on `components/observascope-*-chart` (remote deps + committed unpacked `charts/`) can `Deleting outdated charts` over committed files. Work in a throwaway copy:

```bash
git archive HEAD | tar -x -C /tmp/repotest    # also gives you an unpatched A/B baseline
```

Isolate helm state so `~/.config/helm` is untouched: export `HELM_REPOSITORY_CONFIG`, `HELM_REPOSITORY_CACHE`, `HELM_DATA_HOME` into a scratch dir, then pre-add the 7 repos exactly as `.gitlab-ci.yml:80-87` does.

**Count helm calls with a PATH shim** — dep-build output goes to a temp log that is discarded on success, so grepping stdout measures nothing:

```bash
cat > /tmp/shim/helm <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> /tmp/calls.txt
exec /path/to/real/helm "\$@"
SHIM
chmod +x /tmp/shim/helm; export PATH=/tmp/shim:$PATH
grep -c '^dependency build' /tmp/calls.txt
```

Limit scope with `CLUSTER_EXCLUDE="a,b,c"` (single-cluster is `CLUSTER_FILTER`; pluto/checkov use `PLUTO_CLUSTER_FILTER` / `CHECKOV_CLUSTER_FILTER`).

**Exercise the cold-cache path**: `rm -rf $HELM_REPOSITORY_CACHE/*` but keep `repositories.yaml`, then confirm the fallback fires **once** and self-heals with 0 errors.

## Step 5 — Prove output unchanged, with a control

See memory `feedback_control-diff-proves-identity`. `rendered.yaml` contains four nondeterministic Helm values, so a raw diff is never zero.

1. Render baseline **twice**; diff before-vs-before → noise floor (was 44 lines).
2. Diff before-vs-after. Only the excess over the floor is signal.
3. Normalize exactly those four, require **both** pairs to hit 0:

```bash
norm() { sed -E 's#(app.kubernetes.io/random:).*#\1R#; s#(loki:\$2a\$10\$).*#\1B#;
                 s#(redis-password:).*#\1R#; s#(checksum/secret:).*#\1R#' "$1"; }
```

Report both numbers. Also assert `Rendered / Skipped / Errors` matches the green baseline (**138 / 1 / 0** with `CLUSTER_EXCLUDE=aws0prefdeveks01`).

## Step 6 — Reference numbers

Pipeline 2085418 (MR !361) vs baseline 2084821, same runner:

| Job | Before | After | |
|---|---|---|---|
| `render_manifests` | 248 s | 72 s | −71 % |
| `pluto` | 845 s | 72 s | **−91 %** |
| `checkov` | 1593 s | 640 s | −60 % |

~2700 s → ~780 s of runner time per pipeline. Local 3-cluster A/B: dep builds 54 → 21, `helm repo add` 11 → 4, registered repos 18 → 11, helm invocations 130 → 84.

## What NOT to do

- **Don't add a GitLab `cache:` for the helm repo cache** expecting it to help. `helm repo add` fetches each index regardless and `helm repo update` (line 87) refreshes unconditionally, so it is a no-op unless that line also goes — and it caches *indexes*, not *tarballs*, so it does not reduce exposure to the download failures that actually happen.
- **Don't vendor by committing `Chart.lock` + `charts/*.tgz`.** Measured: `helm dependency build` still refreshes and can delete them. Only an **unpacked** dir plus `repository: file://../<dir>` is hermetic — that is why `components/observascope-*-chart/charts/` works (`HELM_CHARTS_LOCAL_DOWNLOAD.md:22-64`).
- **Don't treat `retry:` as the fix.** Worth adding, but the 2026-08-05 window produced four consecutive failures over 2 h 28 min.
- **Don't delete a component because its chart repo is unreachable.** There is a precedent for this (`.remember/today-2026-06-01.done.md:17`, k8s-dashboard) and it hides the real problem.
- **Don't run git checkout/commit/push from a Workflow subagent** without `isolation: 'worktree'` — memory `feedback_workflow-agent-git-isolation`.

## Escalation to network

Precise ask: from `10.202.0.0/16` (docker bridge on `sfo-cvdevopsgitwork01`) via `192.168.8.24`, these must resolve **and** be reachable on TCP/443: `github.com` + `release-assets.githubusercontent.com`, `istio-release.storage.googleapis.com`, `charts.external-secrets.io` (+ its redirect `external-secrets.io`), `charts.gitlab.io`, `aws.github.io`, `kubernetes.github.io`, `kubernetes-sigs.github.io`, `oauth2-proxy.github.io`, `runatlantis.github.io`, `vmware-tanzu.github.io`, `piraeus.io`. Request timeout/SERVFAIL/query-rate graphs for that source over the known windows, whether BIND `rate-limit`/`fetches-per-server` is engaging, and UDP conntrack headroom. `192.168.8.24` appears nowhere in the IaC tree — there is no source of truth for runner DNS to compare against.
