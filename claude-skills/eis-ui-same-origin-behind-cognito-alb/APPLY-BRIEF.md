# Brief: apply ONE prepared change and verify it (COEXT-113157)

You apply one prepared, reviewed change to a live Kubernetes cluster and verify it. The user asked for this
change (kubectl pilot, no GitOps). Do exactly the steps below, nothing else.

Cluster context `fv-demo`, namespace `ppg-fv01`. Every kubectl call: `kubectl --context fv-demo -n ppg-fv01 ...`.

The change: prefix routes are added to the UI's VirtualService, and some env values of the UI workload are
repointed to the UI's own hostname, so the browser calls the APIs same-origin. The single UI pod restarts once.

## Inputs (given in your task)

- `RELEASE`, `VS` (VirtualService name), `UI_HOST`
- `OUT` = `/Users/eramadan/gitwork/iac/docs/coext-113157-evidence/prep-2026-11-23/<RELEASE>/`
  holding `apply.sh`, `rollback.sh`, `vs-add-routes.jsonpatch.json`, `vs-restore.merge.json`, `env-new.txt`, `env-before.txt`

## Rules

- Do not edit the scripts. Do not touch any other resource, release or namespace.
- Never print the workload YAML/JSON or any Secret (they hold passwords). Never print the whole container env.
  To show env, print only the variables named in `env-new.txt`.
- zsh shell: do not name variables `path` or `status`; use absolute paths; temp files go in `OUT`, not `/tmp`.

## Steps

1. **Pre-check.** `kubectl ... get virtualservice VS -o json | jq '.spec.http|length'` must be exactly `1`.
   If not 1: STOP, apply nothing, report.
2. **Before-snapshot of the browser config** (for comparison): for each URL in the task's "config URLs",
   `curl -sk --max-time 20 URL -o OUT/config-before-<n>` and note size + `shasum -a 256`.
3. **Apply once:** `bash OUT/apply.sh`.
   - Fails at the VirtualService patch: stop and report (nothing else changed).
   - Rollout does not become Ready (rollout status fails or times out, or the pod is in CrashLoopBackOff):
     run `bash OUT/rollback.sh` once, confirm the pod is Ready again, report.
4. **Verify** (VPN is on, curl reaches the internal ALB):
   a. VirtualService rule count and rule names in order; the `/` rule must be last.
   b. Pod is `1/1 Running`; note how long the restart took.
   c. For each new prefix in `vs-add-routes.jsonpatch.json`:
      `curl -sk --max-time 20 -o /dev/null -w '%{http_code} %{content_type}' https://UI_HOST/<prefix>/core/v1/version`
      and the same path on the ORIGINAL host for that API (the old value in `env-before.txt` / `rollback.sh`).
      Same status and content type on both = route works. `text/html` through the UI host while the original
      host returns JSON = route NOT working. If the original host returns 404 for that path too, also compare
      `/actuator/health` on both.
   d. Browser config after: fetch the same config URLs again to `OUT/config-after-<n>`, compare size + sha256
      with before. If the file is readable JSON, list which keys now point at `UI_HOST` and which still point
      at another `-ppg-fv01` host. If it is encrypted (starts with `U2FsdGVkX1`), only say changed / unchanged.
      Unchanged = the env change does not reach the browser config: say so clearly.
   e. `curl -sk --max-time 20 -o /dev/null -w '%{http_code}' https://UI_HOST/` still serves the UI.
   f. Save after-state: `kubectl ... get virtualservice VS -o yaml > OUT/vs.after.yaml` (do not print it).

## Report (final message, under 250 words)

- Applied yes/no; rollback run yes/no; pod restart time
- Table: prefix | via UI host | via original host | match
- Browser config: changed / unchanged, which keys moved
- Anything unexpected
