---
name: keycloak-oidc-idp-simulator
description: Use when an app's SSO/OIDC login POC is blocked on the real IdP (CyberArk Identity apps not created yet, "simulate CyberArk", "test login without CyberArk", "Keycloak as stand-in IdP", "let me log in with my EIS/AD account to the POC"), or when adding/changing the pref-dev Keycloak simulator (components-playground/cyberark-sim), its realm, test users or EIS AD (LDAPS) federation. Reference build COINT-21591 POC-B (Argo CD), 2026-10-29.
---

# Keycloak as OIDC IdP stand-in (pref-dev)

Proves the APP side (login flow, PKCE, groups claim, RBAC, CLI SSO, logout, timeout) against any standards OIDC IdP. Never claim it proves CyberArk: SWS recording, MFA, real claim format (single-group STRING), real issuer stay open.

Reference: `iac/argocd/argocd` `components-playground/cyberark-sim` (+ `components-playground/argo-cd` oidc.config), MRs !578 !579 !580 !582, doc `iac/docs/COINT-21591-poc-b-keycloak-sim.md`, memory `coint21591-poc-b-cyberark-oidc`.

## Build (one MR, playground first)
1. Component = wrapper chart, dependency codecentric `keycloakx` (7.4.0 -> Keycloak 26.8.1; pin `image.digest`, get it from the quay registry API, not memory).
   - `command: [/opt/keycloak/bin/kc.sh, start-dev, --import-realm]`, `database.vendor: dev-file`, `cache.stack: custom` (default jdbc-ping needs a DB), `proxy.mode: xforwarded`, `http.relativePath: "/"`, `KC_HOSTNAME=https://<host>` (literal: subchart `tpl` cannot see parent values).
   - Realm JSON in `files/`, ConfigMap mounted at `/opt/keycloak/data/import`; secrets as `${ENV}` placeholders (Keycloak substitutes env vars on import), env from one ExternalSecret.
   - VirtualService on `istio-system/cluster-gw` routing ONLY `/realms/<realm>/` and `/resources/` (admin console + master realm unreachable); admin work via `kubectl exec ... kcadm.sh`.
2. Realm: shape it like the real IdP. For CyberArk: `groups` claim with plain AD names from a CLIENT protocol mapper (`oidc-group-membership-mapper`, full.path false), NO `groups` client scope (CyberArk's discovery lists none). Do not define `clientScopes` in the import: it replaces the built-in ones (profile/email/basic) and breaks `sub`/`invalid_scope`.
   - Clients: web (confidential, PKCE S256, exact redirect) + CLI (public, PKCE, `http://localhost:8085|8086/auth/callback`).
   - `bruteForceProtected` + `failureFactor: 3`, `waitIncrementSeconds: 900`; `accessTokenLifespan: 300` makes timeout tests fast.
   - Local test users per role + one in no group + one in two groups.
3. EIS AD federation (optional, real users): `components.org.keycloak.storage.UserStorageProvider` ldap provider, `vendor ad`, `editMode READ_ONLY`, `ldaps://exigengroup.com:636`, bind `CN=ldap,CN=users,DC=exigengroup,DC=com` (SM `aws0prefdeveks01/sonarqube/ldap` property `password`), `useTruststoreSpi always`, AD root CA PEM mounted in `/opt/keycloak/conf/truststores`. `customUserSearchFilter` = OR of `(memberOf=<group DN>)` so only POC members can authenticate; group-ldap-mapper with `groups.ldap.filter (cn=<prefix>*)`, `groups.dn` = the OU, `groups.path /ad` (avoids clash with same-named local groups). Define the user-attribute mappers (username sAMAccountName, email mail, givenName, sn) explicitly. Group DNs: memory `macos-ldapsearch-ignores-cacert`.
4. App side: issuer = `https://<host>/realms/<realm>` (same URL for browser and pod: internal ALB hairpin works on pref-dev), clientID/cliClientID + allowedAudiences, PKCE, `logoutURL` = end_session with `{{token}}`/`{{logoutRedirectURL}}`, RBAC `policy.default: ""`. Swap to the real IdP later = issuer/client IDs/secret only.
5. Secrets: user creates the SM secret BEFORE merge with a generator one-liner that prints only the ARN (`python3 -I -c '...secrets.choice...' | aws secretsmanager create-secret ... --secret-string file:///dev/stdin`); verify keys + `[A-Za-z0-9]` + lengths with a pipe that never prints values. Test-user passwords: `... | jq -r .<key> | pbcopy`, never echo.

## Verify before handing the MR back
- Render with the cluster values too: `helm template <c> <chart> -f clusters/<cluster>/values.yaml -f clusters/<cluster>/<c>/values.yaml` (cluster-wide keys like `secretPath` override yours: memory `argocd-cluster-values-key-collision`).
- Local boot with the pinned image, dummy env, realm + CA mounted: logs `Realm '<r>' imported`; admin API: client secret substituted (not literal `${`), group membership, mapper list (no duplicates), `testLDAPConnection action=testConnection` 204 (dummy bind -> `AuthenticationFailure` is expected). `docker rm -f` after.
- Security review first, then ready: if hardening commits are still coming, keep the MR Draft (memory `feedback-out-of-band-prereqs-before-mr-handoff`).

## Live checks after merge + hub refresh
- `curl .../realms/<r>/.well-known/openid-configuration` issuer exact; app `/auth/login` = 303 to Keycloak with `code_challenge_method=S256`; admin paths 404.
- In pod: `kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"` (env, never printed), then `get realms/<r>`, `get components -q type=org.keycloak.storage.UserStorageProvider`, `create testLDAPConnection -s action=testAuthentication -s bindCredential="**********" -s componentId=<id>` (stored credential), `get users` (lists AD users matching the filter, not proof they logged in).
- Groups: Argo CD's server log omits `groups` (memory `argocd-server-log-omits-groups-claim`); use UI User Info or `clients/<id>/evaluate-scopes/generate-example-id-token?userId=`.

## Gotchas
- A realm ConfigMap change does not restart the pod: `kubectl --context pref-dev -n cyberark-sim delete pod <name>-keycloakx-0` (user runs; re-import from git). Follow-up: checksum annotation.
- PR-Agent claimed `--import-realm` was removed in Keycloak 25+: false (26.8.1 `--help` lists it); verify bot claims against the pinned image.
- Squash-merged branch + follow-up commits = conflict: new branch from `origin/main`, cherry-pick, new MR (no force push).
- Login with the AD username (sAMAccountName), not the email; 3 wrong passwords lock the Keycloak user for 15 min (AD account unaffected).
