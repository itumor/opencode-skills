---
name: kube-linter-scanning
description: Generic KubeLinter usage for static analysis of Kubernetes YAML and Helm charts — running scans, reading a check ID like "no-read-only-root-fs" or "unset-cpu-requirements", building a custom .kube-linter.yaml config, ignoring a check per-object via annotation, and the difference between KubeLinter (build-time YAML linting) and kube-bench/kube-hunter (runtime/live-cluster checks). Use whenever the user mentions KubeLinter, kube-linter, a lint finding on a Deployment/Pod spec about missing resource limits or privilege escalation, "lint our k8s manifests", or wants Helm-rendered output checked before it's applied — even if they just say "the manifest linter complained." Not tied to any one company's config; check for a repo-local .kube-linter.yaml first.
---

# KubeLinter

KubeLinter is a static analyzer for Kubernetes YAML manifests and Helm charts — it inspects the *desired-state spec* for common misconfigurations (missing resource limits, containers running as root, no liveness probe, mounting the host network/PID namespace, etc.) before anything is ever applied to a cluster. It complements, not replaces, runtime tools: KubeLinter never talks to a live API server.

## Running it

```bash
kube-linter lint deployment.yaml
kube-linter lint ./manifests/                 # recurse a directory
helm template mychart | kube-linter lint -    # lint rendered Helm output via stdin
kube-linter lint --format json ./manifests/   # machine-readable for CI
```

Always lint the *rendered* output for Helm charts, not the raw templates — a `{{ .Values.resources }}` block looks fine as text but the real question is what it renders to for the values you actually ship.

## Reading a finding

```
manifests/api.yaml: (object: <namespace>/api apps/v1, Kind=Deployment) container "api" does not have a read-only root file system (check: no-read-only-root-fs, remediation: ...)
```

Each finding names the check ID, the offending object, and a remediation hint. Common built-in checks worth knowing by name: `unset-cpu-requirements` / `unset-memory-requirements`, `no-read-only-root-fs`, `privileged-container`, `run-as-non-root`, `no-liveness-probe` / `no-readiness-probe`, `host-network` / `host-ipc` / `host-pid`, `latest-tag` (image tag `:latest` or unpinned), `dangling-service` (Service selector matches no Pods).

## Config file

```yaml
# .kube-linter.yaml
checks:
  addAllBuiltIn: true
  exclude:
    - "unset-memory-requirements"   # repo-wide opt-out, use sparingly

customChecks:
  - name: "require-team-label"
    template: "label"
    params:
      key: "team"
```

`kube-linter lint --config .kube-linter.yaml ...` picks it up explicitly, or KubeLinter auto-discovers a `.kube-linter.yaml` in the current directory. Prefer excluding checks narrowly (a specific object, via inline ignore) over `checks.exclude` repo-wide — a repo-wide exclude blinds the linter to that class of issue for every future manifest too.

## Ignoring a check on one object

```yaml
metadata:
  annotations:
    ignore-check.kube-linter.io/unset-memory-requirements: "this is a batch job with unpredictable memory, intentional"
```

The annotation value is a free-text justification — keep it, it's the only record of *why* later.

## KubeLinter vs kube-bench vs kube-hunter — don't conflate them

| Tool | Checks | When it runs |
|---|---|---|
| **KubeLinter** | Your manifests/Helm output against best-practice rules | Build/CI time, no cluster needed |
| **kube-bench** | The cluster's own control-plane/node config against CIS Kubernetes Benchmark | Runs on/against a live cluster |
| **kube-hunter** | Active penetration testing — tries to actually exploit exposed cluster components | Runs against a live cluster, from inside or outside |

A "security scan" ask that's actually about hardening the *live cluster's* control plane config needs kube-bench, not KubeLinter — KubeLinter has no visibility into how the cluster itself was provisioned, only into the manifests you feed it.

## CI integration pattern

Run `kube-linter lint --format json` on rendered manifests, gate the pipeline on any finding above a chosen severity (KubeLinter checks don't carry a numeric severity by default — bucket them into blocking vs advisory via your own `checks.include`/`exclude` split), and keep the PR-facing output compact — the human-readable format is fine for a handful of findings but unreadable past ~10.
