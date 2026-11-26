# Brief: prepare same-origin change for ONE UI Helm release (COEXT-113157)

You prepare files only. You change NOTHING in the cluster.

## Background

Cluster context `fv-demo`, namespace `ppg-fv01`. Every kubectl call: `kubectl --context fv-demo -n ppg-fv01 ...`.

Problem: a UI on hostname `<ui>-ppg-fv01.demo.aws0.fv.eisdemo.cloud` calls APIs on OTHER hostnames
(`<api>-ppg-fv01.demo.aws0.fv.eisdemo.cloud`). On the public ALB each hostname needs its own Cognito login,
so these cross-host browser calls fail outside the VPN.

Fix already proven on release `cap-ui`: the UI calls the API through its OWN hostname with a path prefix,
and the UI's Istio VirtualService gets one extra rule per API that strips the prefix and routes to the API service.

Reference (read these first, they show the exact format to copy):
- `/Users/eramadan/gitwork/iac/docs/coext-113157-evidence/backup-2026-11-20/vs-add-routes.jsonpatch.json`
- `/Users/eramadan/gitwork/iac/docs/coext-113157-evidence/backup-2026-11-20/vs-restore.merge.json`
- `/Users/eramadan/gitwork/iac/docs/coext-113157-evidence/backup-2026-11-20/rollback.sh`
- `/Users/eramadan/gitwork/iac/docs/coext-113157-evidence/backup-2026-11-20/env-before.txt`

## Hard rules

- READ-ONLY on the cluster: only `kubectl get` and `curl` GET. Never `patch`, `apply`, `set`, `edit`, `delete`, `rollout restart`, `helm upgrade`.
- You WRITE scripts but never RUN `apply.sh` or `rollback.sh`.
- Secrets: the workload YAML contains passwords. Save it to a file, never print it, never `cat` it.
  Print only env vars whose value contains `-ppg-fv01.demo.aws0.fv.eisdemo.cloud`. Never print Secret data.
- zsh shell: do not name a variable `path` or `status`. Use absolute paths. Parse JSON with `jq` on a saved file.
- Stay inside your output directory. Do not touch other releases.
- If something does not fit the pattern, do not guess: write it down under "Anomalies" and continue.

## Inputs (given in your task)

- `RELEASE`: Helm release name
- `VS`: the UI VirtualService name
- `UI_HOST`: the UI hostname
- `OUT`: `/Users/eramadan/gitwork/iac/docs/coext-113157-evidence/prep-2026-11-23/<RELEASE>/` (create it)

## Steps

1. **Find the workload.** The Deployment or StatefulSet that serves the UI (the VS route for `/` names the Service; the
   Service selector leads to the pods; the pod owner is the workload). Record kind, name, container name, replica count.
2. **Backup.** Save to `OUT`: `vs.before.yaml` (the VirtualService) and `workload.before.yaml` (the workload). Do not print them.
3. **Cross-host env values.** From the workload's container `env` (and any ConfigMap used by `envFrom`/`valueFrom`),
   list every variable whose value contains `-ppg-fv01.demo.aws0.fv.eisdemo.cloud` and does NOT point at `UI_HOST`.
   Write `env-before.txt` as `NAME=value` lines (only these variables).
   Ignore for the change, but list in the report: `WEBSOCKET_DXP_HOST`, `GENESIS_INFRA_WEBSOCKET_APP_URL`, `EISCORE_BASE_URL`.
   If a value comes from a ConfigMap and not from the container `env`, say so under Anomalies (then `kubectl set env` would not be the right tool).
4. **Target per API host.** For each distinct API hostname from step 3: find the VirtualService that has this host,
   read its route destination (Service name and port number) and whether it has only one `/` rule. Check the Service exists.
   No VirtualService for a host = Anomaly, leave that variable unchanged.
5. **Browser use check (time box 10 minutes).** With `curl -sk https://UI_HOST/...` find what the browser gets:
   the index page, any runtime config JSON it loads (cap-ui serves `/cap/dxp.json`), or values inlined in served JS/HTML.
   For each variable from step 3 say: value SEEN in browser-served content (give the URL), NOT SEEN, or UNKNOWN.
   If curl gets a 302 to `amazoncognito.com`, the VPN is off: report it and skip this step.
6. **Prefix check.** Prefix per API = `/<service-name>/` (example `/dxp-gateway/`). For each prefix:
   check the UI VirtualService has no existing rule that matches it, and record what
   `curl -sk -o /dev/null -w '%{http_code}' https://UI_HOST/<service-name>/core/v1/version` returns today.
7. **Generate files in `OUT`** (same format as the reference files):
   - `vs-add-routes.jsonpatch.json`: one `add` op at `/spec/http/0` per API. Rule name `coext-113157-<service-name>`,
     `match` prefix `/<service-name>/`, `rewrite.uri` `/`, `route[0].destination` = Service name + port number,
     `route[0].headers.request.set` = `x-forwarded-host: UI_HOST` and `x-forwarded-proto: https`.
   - `vs-restore.merge.json`: `{"spec":{"http":[ ...the ORIGINAL http list exactly... ]}}`.
   - `env-new.txt`: `NAME=value` lines; in each value replace `https://<api-host>` with `https://UI_HOST/<service-name>`
     (and `wss://<api-host>` with `wss://UI_HOST/<service-name>`), keep any path after the host unchanged.
     Only variables with a valid target from step 4.
   - `apply.sh`: `kubectl patch virtualservice VS --type=json --patch-file ...`, then
     `kubectl set env <kind>/<name> --containers=<container> NAME=value ...` with the new values, then `rollout status --timeout=600s`.
   - `rollback.sh`: `kubectl patch virtualservice VS --type=merge --patch-file vs-restore.merge.json`, then
     `kubectl set env` with the OLD values, then `rollout status`.
   Scripts use `set -euo pipefail`, bash shebang, the absolute `OUT` path, and `--context fv-demo -n ppg-fv01` on every call.
   Validate both JSON files with `jq . <file>`.

## Report (your final message, under 300 words, no YAML dumps)

- Workload: kind/name, container, replicas
- Table: env var | old host | Service:port | prefix | seen in browser content (yes/no/unknown + where)
- Runtime config URL found (if any)
- Files written
- Anomalies (anything that does not fit, anything you could not verify)
