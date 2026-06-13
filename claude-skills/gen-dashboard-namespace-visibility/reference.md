# gen-dashboard Config Reference (EIS fleet)

App: "Kubernetes Dashboard API" (FastAPI, python). Chart `components/gen-dashboard` in `iac/argocd/argocd`, wraps `deployment-template` subchart (renders a **StatefulSet** → pod `gen-dashboard-app-0` in ns `monitoring`). Image tag = app version (`/api` returns it, e.g. 2.0.16).

## Three config resources (all in ns `monitoring`)

| Resource | Template | Content | Consumed |
|---|---|---|---|
| CM `dashboard-config` | `cm-dashboard-config.yaml` | `config.yaml`: namespaces allowlist, dashboardAuth (UI login), defaults, externalServices | via K8s API, hot-reload ~1min |
| CM `dashboard-templates` | `cm-templates.yaml` | `dashboard-templates.yaml`: ~45 service-type templates | via K8s API |
| Secret `dashboard-auth` | `secret-ms-auth.yaml` | `auth.yaml` (b64): basic/oauth templates for authenticating TO monitored services | via K8s API |

No volume mounts — SA `dashboard-controller` reads/writes these via API (RBAC resourceNames-scoped). Never `rollout restart` for config changes.

## dashboard-config (`oneSuiteDashboardConfig.*` values)

```yaml
oneSuiteDashboardConfig:
  namespaces: [loki, monitoring]   # allowlist; helm REPLACES list — repeat defaults
  dashboardAuth:
    type: ldap                     # none | basic | ldap — gates UI login only, read APIs stay unauth
    basic: {username: qa, password: qa}   # or secretRef {name,namespace,passwordKey,usernameKey}
    ldap:                          # AD bind; rwGroups = AD groups with dashboard write
      rwGroups: [oc-team, Genesis_DevOps_CI, PNTDevOps, dashboard_gen_rw]
  defaults:
    prometheusUrl: http://prometheus-server.monitoring.svc.cluster.local:80
    grafanaUrl: ""
    maxParallelIngressValidations: 5      # template default 20, component values 5
    timeout: 3s
    validationSchedulerInterval: 1m       # health-check re-validation cadence
  externalServices:                # off-cluster tiles (JIRA, WIKI): base_url, health_check_url, version_json_path
```

**Displayed namespaces = allowlist ∩ namespaces that EXIST on the cluster.** A configured-but-not-yet-created namespace is silently absent (NOT drift — e.g. caa-test01 pre-provisioned 2026-06-03). A created-but-not-configured namespace is hidden (e.g. afa-poc on fvdemo).

## dashboard-templates (service-type matching)

Each template: `name`, `assigned-services` (VirtualService NAMES, optional per-entry `namespace`), `auth` (ref into dashboard-auth templates: `type: basic|oauth`, `name`), `health-check` path, `attributes` (version/build/branch/platform scraped via `endpoint` + `json-path`), `links` (swagger/scheme/open-api), `login-url`, `tcp_ports` (TCP check instead of HTTP — Kafka 9092, ZK 2181, PG 5432, DSE 9042).

Flow: app lists Istio VirtualServices in allowed namespaces → matches VS name against `assigned-services` → tile gets template's health-check/attributes/links → unmatched VSs land in **"Unassigned"** group with plain URL check. Key templates: `Amber-MS-BasicAuth` (~95 core MS, `/api/common/revision/v1`), `Amber-MS-OAuth`, `Amber-UI-application` (~60 UIs, health=`/`), `DXP` (`/core/v1/version`), `OpenL` (`/admin/healthcheck/readiness`).

To onboard a NEW service type fleet-wide, edit `components/gen-dashboard/templates/cm-templates.yaml` directly (data is hardcoded there, not values-driven) — append under `templates:` mirroring this exact key structure:

```yaml
      - name: FooBar
        assigned-services:
          - name: foobar-foobar-app-vs        # VirtualService name; optional: namespace: <ns>
        auth:                                  # optional — ref into dashboard-auth
          type: basic
          name: default
        health-check: /health
        attributes:
          - name: version
            endpoint: /info
            json-path: version                 # nested: body/success/eisVersion
        links:
          - name: swagger
            endpoint: /swagger-ui/index.html
        login-url: /
```

## auth (TO monitored services) — `auth.*` values

```yaml
auth:
  basic.templates: [{name: default, username: qa, password: qa}]   # or secretRef
  oauth:
    defaults: {url: <keycloak token url>, client_id: system, grant_type: client_credentials, ...}
    templates: [{name: internal, secretRef: {name: common-secret, namespace: default, client_secret: GENESIS_...}}]
```
Rendered b64 into Secret `dashboard-auth` only if any templates defined. Check live: `/api/auth-templates` → `{"basic":["default"],"oauth":["internal"]}`.

## RBAC (ClusterRole `dashboard-controller-monitoring`)

list/watch/get: namespaces, nodes, pods, services, events, deployments, ingresses (networking+extensions), istio virtualservices/gateways/destinationrules, metrics.k8s.io pods. Full CRUD on own CMs (`dashboard-config`, `dashboard-templates`) + Secret (`dashboard-auth`); read `common-secret`.

## API quick map (unauth even when dashboardAuth=ldap)

| Endpoint | Returns |
|---|---|
| `/api` | `{app, version, status}` |
| `/api/namespaces` | visible ns (allowlist ∩ existing) |
| `/api/namespace/{ns}/virtual-services-grouped` | tiles grouped by template, incl. "Unassigned" |
| `/api/health-checks/namespace/{ns}` | per-VS check results (status, uri, date) |
| `/api/templates`, `/api/auth-templates`, `/api/genesis-defaults` | template defs, auth template names, per-tile check toggles |
| `/api/external-services` | external tiles + last check |
| `/api/auth/config` | `{authAllowed, authType}` |
| `/api/reload/namespace/{ns}/virtual-service/{vs}` | force re-validate one tile |
| `/openapi.json` | full schema |

## Fleet matrix (live-verified 2026-06-04)

| Cluster | Dashboard host | Extra namespaces (beyond loki+monitoring) |
|---|---|---|
| aws0caadeveks01 | dashboard-monitoring.dev.aws0.caa-eis.cloud | caa-dev01, caa-int01, caa-mt01, caa-qaa, caa-release, caa-tooling, eis-internal |
| aws0caatesteks01 | dashboard-monitoring.test.aws0.caa-eis.cloud | caa-test01 configured; ns not created yet → not displayed |
| aws0fvdemoeks01 | dashboard-monitoring.demo.aws0.fv.eisdemo.cloud | afa-fv01 (afa-poc exists, deliberately not listed) |
| aws0iacdeveks01 | dashboard-monitoring.dev.aws0.iac.aws.eislab.cloud | — (defaults) |
| aws0prefdeveks01 | dashboard-monitoring.dev.aws0.pref.eislab.cloud | — (defaults) |
| aws0v20deveks01 | dashboard-monitoring.dev.aws0.v20.aws.eislab.cloud | — (defaults) |
| aws0v20perfdeveks01 | **dashboard-monitoring.aws.eislab.cloud** (no cluster prefix — VS predates clusterNameHosts) | perf-mssql |

Fleet sweep one-liner (no kubectl/SSO needed):
```bash
for d in dev.aws0.caa-eis.cloud test.aws0.caa-eis.cloud demo.aws0.fv.eisdemo.cloud \
         dev.aws0.iac.aws.eislab.cloud dev.aws0.pref.eislab.cloud \
         dev.aws0.v20.aws.eislab.cloud aws.eislab.cloud; do
  echo "$d: $(curl -sk -m 8 https://dashboard-monitoring.$d/api/namespaces)"
done
```

## Other chart values worth knowing

- `secretName: dashboard-auth` — RBAC + secret name coupled; rename both or break.
- `envs:` app env (PORT, LOG_LEVEL, SKIP_K8S_CHECK, prometheus/otel toggles); `ms_envs` overrides.
- `smokeTest.enabled` — PostSync hook curling the service; on across the fleet.
- `monitoring.serviceMonitor.enabled: true` — metrics on :9090.
- `nodeSelector: monitoring: "true"` — pinned to monitoring nodes.
- `externalSecrets.registrySecretPath` — TWO conventions per cluster (raw nexus path no property vs monitoring/registry + `.dockerconfigjson`) — see memory gen-dashboard-registry-secret-property.
- VS name `gen-dashboard-dashboard-vs`, host `dashboard-{{ns}}.{{domain}}` → `dashboard-monitoring.<domain>`.
