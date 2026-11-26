---
name: eis-ui-same-origin-behind-cognito-alb
description: Use when an EIS/Genesis UI behind an ALB with authenticate-cognito (or any per-hostname login in front of the ALB) works on VPN but fails outside it - login shows "Cannot read properties of undefined (reading 'json')" or "Cannot read properties of null (reading 'customerNumber' / 'details')", API calls get 302 to amazoncognito.com, CORS preflight fails, "Failed to fetch", login POST 404 - or when asked to "make the UI call its API same-origin", "add prefix routes to the VirtualService", "roll the cap-ui fix to the other UIs", "which UIs work outside the VPN", "status table with screenshots of all UIs", "what must CI/CD change for the Cognito login". Covers proof of cause, the planner/verifier script, the same-origin fix (env values + Istio prefix routes with :443 twins), Haiku fan-out for apply and browser checks, review rules, the status table, rollback. Reference run COEXT-113157 (ppg-fv01, 14 UIs, 2026-11-20/23).
---

# EIS UI same-origin fix behind a Cognito ALB

## Symptom and cause

- UI on `https://<ui>-<ns>.<zone>` loads after the Cognito login, then its own login fails outside the VPN.
- Cause: the UI calls its APIs on OTHER hostnames. The ALB rule `authenticate-cognito` keeps its session cookie per hostname.
  The CORS preflight (OPTIONS, no cookies) and any fetch without `credentials: 'include'` get a 302 to Cognito.
- On VPN the hostnames resolve to the internal ALB with no Cognito rule, so everything works there.

Prove it first (off VPN): the failing browser request is cross-host, and
`curl -sk -o /dev/null -w '%{http_code} %{redirect_url}' -X OPTIONS https://<api-host>/...` gives 302 to `amazoncognito.com`.

## Do not

- Add an unauthenticated ALB bypass rule for the API hosts. Keep Cognito on UI and API.
- Add a second VirtualService for the same host: Istio does not merge them safely, the `/` catch-all wins.

## Fix

Per UI: (1) env values that point at an API host become `https://<ui-host>/<service>` (path after the host kept);
(2) the UI VirtualService gets, before `/`, one rule per API with prefix `/<service>/` AND a twin `/<service>:443/`,
both `rewrite.uri: /` to `<service>:<port>` with `x-forwarded-host` / `x-forwarded-proto` set.

## Run it: the script does the prep (no agents needed)

`~/.claude/scripts/ui-same-origin.py` (`--selftest` offline). VPN on for `plan`, `apply.sh` and `verify`.

```bash
python3 -I ~/.claude/scripts/ui-same-origin.py plan --context <ctx> --namespace <ns> --tag <ticket-key> --out <evidence-dir>/plan
python3 -I ~/.claude/scripts/ui-same-origin.py verify --context <ctx> --namespace <ns> --tag <ticket-key>
```

- `plan` is read-only. Per UI it writes `vs-add-routes.jsonpatch.json`, `vs-restore.merge.json`, `env-before.txt`,
  `env-new.txt`, `apply.sh`, `rollback.sh`, and prints what it skipped and why. It never writes workload JSON (passwords).
- It already applies the review rules below (UI links, websockets, templates, missing targets, `:443` twins) and is
  idempotent: a second run after apply reports nothing to do.
- `verify` probes every tagged route; a route that returns HTML is broken; `/` must be the last rule.
- UIs are picked by VirtualService name (`--ui-regex`, default `ui|cssr`). Read the printed list before applying.

Order: `plan` -> read the summary and the skipped/gap lines -> pilot two UIs (one with a readable config, one large) ->
the rest -> `verify` -> browser check off VPN -> status table.

## Review rules (the script encodes them; know them to judge its output)

- **Only API hosts get a route.** Links to another UI stay: `*_UI_HOST`, `*_UI_ORIGIN`, `V20_BILLING_HOST`, `BILLING_HOST`,
  and any value whose target VirtualService is itself a UI. Proxying a UI under a prefix breaks it.
- **The apps append `:443` to their API base value** (`GENESIS_HOST`, `MEMBER_DXP_HOST`, `EMPLOYER_DXP_HOST`, `BROKER_DXP_HOST`, ...).
  The browser calls `/<service>:443/...`; with no twin rule it falls to `/` and gets the UI page with status 200.
  That broke three logins on 2026-11-23. Twins on EVERY route from the start.
- **Prefix = Kubernetes Service name**, which can differ from the hostname (`dxp-payment-hub-app` vs host `dxp-payment-hub-mfe-app`).
- **Targets with no VirtualService** are already dead: leave the value, list it as a gap.
- **Not covered:** per-domain host templates (`__domain__-<ns>...`), websocket values, `EISCORE_BASE_URL`.
- A value that already has a path keeps it (`.../product-studio` -> `<ui>/product-studio/product-studio`). That is correct.

## Where the browser gets the API host

| UI family | Runtime config | Readable |
|---|---|---|
| cap-ui, pet, dental | `/<base>/dxp.json` (`/cap`, `/pet`, `/dental`) | yes |
| admin-ui | `/dxp.json` | yes |
| ui-billing | `/dxp.json/` (trailing slash; `/dxp.json` holds nightly defaults) | yes |
| tooling-ui | `/studios/backend-origins.json` | yes |
| cssr-app, persona portals | `/dxp.json` | AES blob (`U2FsdGVkX1`): compare size/sha before and after |
| work-ui | no file found; it does call `GENESIS_HOST` in the browser | - |

Generated from container env at pod start, so `kubectl set env` (or a Helm value) changes it after one restart.

## Judging a result: status codes lie

- **A 200 proves nothing. Read the content type and the exact path.** A prefix path on the UI host returns 200 `text/html`
  (SPA fallback) when no rule matches. The UI then fails on a null field, which looks like a data problem and is a routing miss.
- Compare every called path with the rule prefixes. Called `/x:443/...` and only `/x/` has a rule = routing.
- 401 JSON through the UI host = route works, if the original host answers the same without a login.
- On the UI's own host under a prefix that HAS a rule, JSON error body = backend, user or data (not this fix).
- A login form with its own rules (provider portal: 10-digit password, reCAPTCHA) is not this fix.

## Haiku fan-out (the user wants agents to do the repetitive work; main session orchestrates and reviews)

One shared brief file per phase + a few input lines per agent, `model: haiku`, all in one message. Templates in this dir
(they carry the COEXT-113157 paths and hostname suffix: copy into the ticket's evidence dir and adapt):

| Phase | Brief | Notes |
|---|---|---|
| Apply + verify one UI | `APPLY-BRIEF.md` | pre-check rule count, run `apply.sh` once, self-rollback if the pod is not Ready |
| Browser check off VPN | `E2E-BRIEF.md` | own tab each; stop at any login form |
| Why does login fail | `DIAG-BRIEF.md` | read-only on the open tab; verdict rules above are in the brief |
| Screenshot + state | `SNAP-BRIEF.md` | saves `<ui>.jpg`, reports state and calls; feeds the status table |
| Prep by agents (old way) | `BRIEF.md` | only if the script cannot be used |

What Haiku got wrong, so review every time:
- added routes for UI links; used `mapfile` (not in macOS bash 3.2); read the wrong config file;
- called a routing miss "backend answer" because the status was 200;
- dumped workload JSON outside its dir, decoded Secret values although told not to print them.
Read each agent's "unexpected" line: the `:443` defect was first visible there.

Haiku `general-purpose` agents have the claude-in-chrome tools and can share one Chrome, one tab each.
One Cognito sign-in by the user covers every hostname; each UI still has its own app login, which only the user does.
kubectl needs VPN on, the browser check needs VPN off: the user toggles. Plan the work in two batches around that.

## Deliverables

- Status table: one row per UI with URL, state outside VPN, calls OK/fail/cross-host, note, screenshot link
  (example `docs/coext-113157-status-2026-11-23.md`). Say which rows you checked yourself and which come from agents.
- CI/CD change request: values + routes + twins + gaps (example `docs/coext-113157-cicd-change-request.md`).
  kubectl changes are drift; the next Helm deploy reverts them. The chart library (`eis-deployment-template`) had no
  `rewrite` option in the copy we could read: confirm with the CI/CD team.

## Safety

- Nobody types or submits credentials or clicks a CAPTCHA except the user.
- Workload backups hold plain passwords: do not create them; if they exist, never print or share.
- Each UI pod restarts once (20-100 s) on the env change. Route-only changes need no restart.
- Rollback per UI = `rollback.sh` (merge-patch the original `spec.http` list back + old env values).

## When this run teaches something new

Add it here in the same session: a new rule goes into "Review rules" AND into `SKIP_NAME_RE` / `plan_ui` of the script
with a selftest case, so the next run does it without anyone remembering.
