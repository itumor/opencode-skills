---
name: argocd-ci-pipeline-diagnosis
description: Diagnose a red or slow GitLab CI pipeline in iac/argocd/argocd (render_manifests, pluto, checkov, kubeconform) and safely optimize it. Use when an argocd MR pipeline fails on a chart download or DNS/network error; when the pipeline is slow and you need the critical path rather than a guess; when auditing which jobs are ungated or missing `needs:`; when sharding a slow job with `parallel:`; or when working GENESIS-429530 pipeline performance.
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
| `pluto` | `scripts/ci/pluto-helm.sh` | deprecated-API scan; re-renders all 155 charts itself |
| `checkov` | `scripts/ci/checkov-helm.sh` | slowest job; since !376 `parallel: 5`, shards derived in-script |
| `kubeconform`, `kube_linter`, `kyverno`, `helm_unittest`, `quality_summary` | inline | all `needs: render_manifests` → **6 gates skip when render fails** |
| `*_playground` variants | same scripts, `CHARTS_ROOT=components-playground` | 18 fixed charts — **use as a load-free network probe** |

Four jobs pre-add the same 7 helm repos then `helm repo update` (lines 80–87, 325–332, 591–598, 732–739).

Since **MR !376** the production jobs carry the same `rules: changes:` gate the playground
jobs always had (minus `components-playground/**`), and both `checkov` jobs have explicit
`needs:`. If you see a production job with no `rules:` again, that is a regression — run the
gate audit in Step 3b.

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

## Step 3b — Wall-clock work: find the critical path, never guess it

A red pipeline and a slow pipeline are different problems. For slow, **runner-seconds are
not the target — the critical path is.** Pull the job graph with offsets:

```bash
PID=<pipeline id>
glab api "projects/1547/pipelines/$PID/jobs?per_page=100" > /tmp/j.json
python3 - <<'PY'
import json, datetime
t = lambda s: datetime.datetime.fromisoformat(s.replace('Z', '+00:00'))
d = json.load(open('/tmp/j.json'))
c = min(t(j['created_at']) for j in d)
for j in sorted(d, key=lambda x: t(x['started_at'])):
    print(f"{j['name']:<32}{j['status']:<9}q={j.get('queued_duration') or 0:>4.0f}"
          f" dur={j.get('duration') or 0:>5.0f}  +{(t(j['started_at'])-c).total_seconds():.0f}s"
          f" -> +{(t(j['finished_at'])-c).total_seconds():.0f}s")
print('wall', max((t(j['finished_at'])-c).total_seconds() for j in d),
      ' runner-s', sum(j.get('duration') or 0 for j in d))
PY
```

On `2181948` this showed every job finished by **+160 s** except `checkov`, which ran
**+161 → +680**. One job was 76 % of the wall. Anything you optimize elsewhere is invisible.

Ask three questions per job, **in this order** — the first two are free, the third costs money:

1. **Must it run at all?** → `rules: changes:`
2. **Must it wait?** → `needs:`
3. Only then: make it faster.

### The gate audit — highest-yield check in this repo

```bash
python3 - <<'PY'
import yaml
d = yaml.safe_load(open('.gitlab-ci.yml'))
for k, v in d.items():
    if isinstance(v, dict) and 'stage' in v:
        n = v.get('needs')
        ns = '(none -> waits for whole previous stage)' if n is None else \
             [x['job'] if isinstance(x, dict) else x for x in n]
        print(f"{k:<32}{v['stage']:<10}rules={'yes' if 'rules' in v else 'NO!':<4} needs={ns}")
PY
```

`rules=NO!` means the job runs on **every** pipeline. Then cross-check each against what the
job actually reads. Two real findings from this exact audit:

- **Seven production jobs were ungated while every playground job was gated.** Renovate
  (`solutions/renovate/argocd.json` disables `components/**`) only ever touches
  `components-playground/**`, so **65 % of MR pipelines ran the entire production half for
  nothing.** Fix = give the ungated jobs the gate `render_manifests_playground` already
  uses, minus the playground path. Gate a `needs:` cluster **identically** so non-optional
  needs appear and disappear together.
- **`checkov` had no `needs:` at all**, so it inherited stage ordering and idled ~160 s —
  while pulling 8 artifacts it never opened. It reads only the repo checkout.

Quantify the wasted population before writing anything — classify MR pipelines by the MR's
changed roots and weight by pipeline count, not MR count (bot MRs re-run nightly):

```bash
glab api "projects/1547/merge_requests/$IID/changes" |
  python3 -c "import sys,json;print(sorted({c['new_path'].split('/')[0] for c in json.load(sys.stdin)['changes']}))"
```

## Step 3c — Sharding a slow job

`checkov` cost is **process start-up, not helm**: 155 invocations × ~3.05 s, plus ~39 s of
container setup. Nothing inside one invocation is worth tuning; run fewer of them, or run
them in parallel.

**Use `parallel: <n>`, never `parallel: matrix` over inventory.** A matrix listing clusters
by name puts a second copy of the fleet in `.gitlab-ci.yml`; onboard a cluster and it is
scanned by nothing while the pipeline stays **green**. See memory
`gitlab-ci-static-matrix-rots`. Instead GitLab exports `CI_NODE_TOTAL`/`CI_NODE_INDEX`
(1-based) and the script derives its own slice — `checkov-helm.sh` bin-packs the live
cluster list largest-first into the least-loaded bin.

Two traps in that pre-pass:
- An **empty bin** (more shards than clusters) must `exit 0` explicitly. Leaving the filter
  variable empty reads as *no filter*, so that shard scans the whole fleet instead of nothing.
- It must only **narrow** an existing filter, never replace it, or it breaks
  `checkov_playground`, which passes `CLUSTER_FILTER=aws0prefdeveks01` deliberately.

Pick the shard count from **runner slots, not shard count**: one docker runner with 5
concurrent slots means `wall ≈ total_runner_seconds / 5` regardless, and extra shards only
re-pay the ~39 s setup. Measured here: 5 shards ≈ 262–295 s, 9 would run in two waves and
finish later. Confirm slots empirically — `concurrent-N` in any job trace:

```bash
glab api "projects/1547/jobs/$JOB/trace" | grep -m1 -oE 'runner-[a-z0-9]+-project-1547-concurrent-[0-9]+'
```

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

### Stub the expensive binaries and run the real script

For anything that selects *which* work to do (sharding, filters, exclusions), test the real
script against the real tree in a throwaway copy, with the slow binaries stubbed out. This
runs the actual code path in seconds and needs no CI round-trip:

```bash
T=/tmp/shardtest; rm -rf $T; mkdir -p $T/repo $T/bin
git archive HEAD | tar -x -C $T/repo
cp scripts/ci/checkov-helm.sh $T/repo/scripts/ci/   # the edited version
printf '#!/bin/sh\nexit 0\n' > $T/bin/helm    ; chmod +x $T/bin/helm
printf '#!/bin/sh\nexit 0\n' > $T/bin/checkov ; chmod +x $T/bin/checkov

run() { ( cd $T/repo && PATH="$T/bin:$PATH" REPO_ROOT="$T/repo" CHARTS_ROOT=components \
          CLUSTER_EXCLUDE=aws0prefdeveks01 "$@" bash scripts/ci/checkov-helm.sh 2>&1 ); }
run | grep '\[SCAN\]' | awk '{print $2}' | sort > $T/base.txt      # 155
for i in 1 2 3 4 5; do
  CI_NODE_TOTAL=5 CI_NODE_INDEX=$i run | grep '\[SCAN\]' | awk '{print $2}'
done | sort > $T/all.txt
```

Assert a **partition**, not merely "it ran": `total == distinct == baseline`. Then the two
edge cases that actually bite — add a fake tenth cluster and assert the total rises and it
lands in exactly one shard; run `CI_NODE_TOTAL=20` and assert `[SKIP]` with **zero** scans.

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

### Findings parity for a sharded job — green is not parity

Splitting a scanner across jobs can silently drop work and still go green. Sum the JUnit
testcases and failures across all shards and compare against the single-job baseline:

```bash
python3 - <<'PY'
import glob, re, xml.etree.ElementTree as ET
tc = fail = files = 0
for f in glob.glob('/tmp/shards/**/*.xml', recursive=True):
    r = ET.parse(f).getroot()
    for s in ([r] if r.tag == 'testsuite' else r.iter('testsuite')):
        tc += int(s.get('tests', 0)); fail += int(s.get('failures', 0))
    files += 1
print(files, 'files', tc, 'tests', fail, 'fail')
PY
```

Must be **identical** to the unsharded baseline — here 155 files / 25 637 tests / 812
failures / 0 errors. Identical totals from *differently composed* bins is itself the proof
the partition is complete. GitLab merges `junit:` and `sast:` reports across parallel jobs,
so the MR widgets need no change.

## Step 6 — Reference numbers

Pipeline 2085418 (MR !361) vs baseline 2084821, same runner:

| Job | Before | After | |
|---|---|---|---|
| `render_manifests` | 248 s | 72 s | −71 % |
| `pluto` | 845 s | 72 s | **−91 %** |
| `checkov` | 1593 s | 640 s | −60 % |

~2700 s → ~780 s of runner time per pipeline. Local 3-cluster A/B: dep builds 54 → 21, `helm repo add` 11 → 4, registered repos 18 → 11, helm invocations 130 → 84.


### Round 2 — MR !376, gating + `needs:` + sharding (2026-09-01)

Pipeline `2189420` vs baseline `2181948`, same runner. This MR touches `.gitlab-ci.yml`
and `scripts/ci/`, so it is in production scope and both halves ran — the worst case.

| | before | after |
|---|---:|---:|
| wall | 681 s | **262 s** (−62 %) |
| runner-seconds | 1069 | 1248 (+17 %) |
| `checkov` start | +161 s | **+8 s** |
| `checkov` | 519 s, one job | 118 / 153 / 157 / 131 / 125 s, five derived shards |

A **playground-only** pipeline — 65 % of MR traffic — now runs 5 jobs instead of 15 and
finishes in ~144 s. MR-weighted average **~185 s against 681 s**.

Predicted 160 s, measured 262–295 s. The gap is the 5-slot runner: 15 jobs totalling
~1437 runner-seconds cannot finish faster than 1437/5 ≈ 287 s no matter how the DAG is
drawn. Once slots bind, wall-clock is set by **total runner-seconds ÷ slots**, and further
sharding stops paying past ~4 shards. Model the slot floor before promising a number.


## What NOT to do

- **Don't add a GitLab `cache:` for the helm repo cache** expecting it to help. `helm repo add` fetches each index regardless and `helm repo update` (line 87) refreshes unconditionally, so it is a no-op unless that line also goes — and it caches *indexes*, not *tarballs*, so it does not reduce exposure to the download failures that actually happen.
- **Don't vendor by committing `Chart.lock` + `charts/*.tgz`.** Measured: `helm dependency build` still refreshes and can delete them. Only an **unpacked** dir plus `repository: file://../<dir>` is hermetic — that is why `components/observascope-*-chart/charts/` works (`HELM_CHARTS_LOCAL_DOWNLOAD.md:22-64`).
- **Don't treat `retry:` as the fix.** Worth adding, but the 2026-08-05 window produced four consecutive failures over 2 h 28 min.
- **Don't delete a component because its chart repo is unreachable.** There is a precedent for this (`.remember/today-2026-06-01.done.md:17`, k8s-dashboard) and it hides the real problem.
- **Don't shard with `parallel: matrix` over a cluster list.** It duplicates the fleet
  inventory into `.gitlab-ci.yml`; a newly onboarded cluster is then scanned by nothing and
  the pipeline stays green. Use `parallel: <n>` + `CI_NODE_INDEX` and derive the list in the
  script. Memory `gitlab-ci-static-matrix-rots`.
- **Don't try to dedupe checkov units by `sha256(merged values)`.** Measured: **1.00×**, zero
  savings. All 155 (component, values) pairs are distinct because every cluster's
  `values.yaml` carries cluster-specific fields. Ruled out — do not retry.
- **Don't promise a wall-clock number without modelling the slot floor.** See Round 2 above.
- **Don't assume `--framework helm` cost is helm.** It is Python start-up: ~3.05 s × 155
  invocations, vs ~0.2 s for a `helm template`. `render_manifests` renders all 155 in 54 s.
- **Don't run git checkout/commit/push from a Workflow subagent** without `isolation: 'worktree'` — memory `feedback_workflow-agent-git-isolation`.

## Escalation to network

Precise ask: from `10.202.0.0/16` (docker bridge on `sfo-cvdevopsgitwork01`) via `192.168.8.24`, these must resolve **and** be reachable on TCP/443: `github.com` + `release-assets.githubusercontent.com`, `istio-release.storage.googleapis.com`, `charts.external-secrets.io` (+ its redirect `external-secrets.io`), `charts.gitlab.io`, `aws.github.io`, `kubernetes.github.io`, `kubernetes-sigs.github.io`, `oauth2-proxy.github.io`, `runatlantis.github.io`, `vmware-tanzu.github.io`, `piraeus.io`. Request timeout/SERVFAIL/query-rate graphs for that source over the known windows, whether BIND `rate-limit`/`fetches-per-server` is engaging, and UDP conntrack headroom. `192.168.8.24` appears nowhere in the IaC tree — there is no source of truth for runner DNS to compare against.
