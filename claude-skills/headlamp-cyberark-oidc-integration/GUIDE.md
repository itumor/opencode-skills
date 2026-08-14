# Headlamp ↔ CyberArk Identity OIDC Integration Guide

**Reference implementation:** COEXT-108018 — CAA UAT, cluster `aws0caatesteks01`, completed 2026-08-10.
**Audience:** the next engineer integrating Headlamp with CyberArk Identity ("Idira") on any EIS cluster.
**Outcome:** Headlamp access gated exclusively by CyberArk (login + session recording), Kubernetes RBAC driven by AD group membership delivered in the CyberArk id_token.

---

## 1. Architecture

```
Browser
  → https://headlamp-monitoring.<domain>/c/main        (direct link OR CyberArk portal tile)
  → Headlamp backend /oidc?cluster=main                 (starts OIDC flow)
  → CyberArk /OAuth2/Authorize/<app_id>                 (authenticate; app assignment enforced)
  → Secure Web Sessions gate (auth.alero.io)            (requires SWS browser extension if
                                                         "Step recording" policy is on the app)
  → redirect back to https://headlamp-…/oidc-callback?code=…&state=…
  → Headlamp backend exchanges code at /OAuth2/Token/<app_id>   ← THE PATCHED STEP (see §5)
  → id_token stored in HttpOnly cookie (headlamp-auth-main.0, SameSite=Strict,
    path /clusters/main)
  → every k8s API call forwards the token; the EKS cluster's OIDC identity provider
    (CyberArk issuer) validates it; RBAC matches the token's `groups` claim
```

Two independent trust relationships must BOTH point at CyberArk:
1. **Headlamp's OIDC client** (the login flow) — configured via the headlamp-oidc secret.
2. **The EKS cluster's OIDC identity provider** (token validation for kubectl/API) — configured via Terraform. Forgetting #2 gives a fully working login that ends in k8s `401 Unauthorized`.

---

## 2. Prerequisites (request these FIRST — external-team lead time)

| Item | Owner | Notes |
|---|---|---|
| AD groups `headlamp_<env>_admin` / `_rw` / `_r` | AD team (Jira CV Support) | Plain names end up in the token — record exact spelling |
| CyberArk OIDC app (`<env>_headlamp_oauth_client_oidc`) | CyberArk admin (Denys Z.) | See §3 for the exact settings to request |
| App access granted to the 3 AD groups | CyberArk admin | Users NOT in the groups get `access_denied — user not allowed access to app` |
| Test user added to one AD group | AD team | Nothing is testable end-to-end without this |
| SWS browser extension (if Step-recording policy on the app) | each end user | Chrome Web Store: "CyberArk Secure Web Sessions Extension" (`ohfinlfcbaehgokpmkjcmkgdcbgamgln`) — this is DIFFERENT from the CyberArk Identity extension; both coexist |

## 3. CyberArk app settings to request (exact)

- **Redirect URI (exact string, no trailing slash):** `https://headlamp-monitoring.<cluster-domain>/oidc-callback`
  (Headlamp's callback path is fixed; the host derives from the ingress FQDN. CyberArk's whitelist accepted both with/without trailing slash in our tests, but register the exact string.)
- **Logout:** Headlamp has no dedicated logout endpoint — give the base FQDN as post-logout redirect.
- **Client secret: ALPHANUMERIC-ONLY.** Hard requirement — see §5. If CyberArk generates one with `!$?@^…`, regenerate until clean, or the integration WILL fail with `invalid_grant`.
- **Groups claim:** CyberArk emits `groups` in the id_token containing AD group NAMES (verified live: `"groups": "headlamp_caa-uat_admin"`). Not advertised in the discovery doc, but present. NOTE: a single-group user gets a **string**, not an array — k8s accepts both, but verify a multi-group user once available.
- Discovery endpoint for verification (no auth needed):
  `https://<tenant>.id.cyberark.cloud/<app_id>/.well-known/openid-configuration`
  The `issuer` value (WITH its trailing slash) is what goes everywhere downstream.

## 4. Headlamp OIDC secret (AWS Secrets Manager → ESO → pod env)

Secret path: `<cluster>/monitoring/headlamp/headlamp-oidc`. Exactly this JSON shape:

```json
{
  "OIDC_CLIENT_ID":     "<client id from CyberArk app>",
  "OIDC_CLIENT_SECRET": "<ALNUM-ONLY secret>",
  "OIDC_ISSUER_URL":    "https://<tenant>.id.cyberark.cloud/<app_id>/",
  "OIDC_SCOPES":        "openid profile email"
}
```

- `OIDC_ISSUER_URL` must byte-match the token `iss` claim — **keep the trailing slash**.
- Do NOT copy `scopes_supported` wholesale (`address phone` are useless; Headlamp prepends `openid` itself, so listing it again produces a harmless-but-ugly duplicate).
- After changing the secret: force ESO re-sync (`kubectl annotate externalsecret headlamp-oidc-secret -n monitoring force-sync="$(date +%s)" --overwrite`) then `kubectl rollout restart deployment headlamp -n monitoring`.
- **Landmine:** if the secret resource is Terraform-managed (ours was: `cognito.clients.<x>` in `lower/infra/services`), a later apply of that stack SILENTLY REVERTS your value. Detach the secret from the old module or the integration dies on the next unrelated apply.

## 5. THE HAND-PATCHED CODE (custom Headlamp image) — why and what

### 5.1 The bug chain (proven live, 2026-08-10)

1. Headlamp's backend uses Go's `golang.org/x/oauth2` with `AuthStyle` auto-detect.
2. Auto-detect sends the FIRST token request as **HTTP Basic** with credentials passed through `url.QueryEscape` (RFC 6749 §2.3.1 says to form-urlencode them).
3. **CyberArk's token endpoint does not url-decode Basic credentials.** If the client secret contains any character outside `[A-Za-z0-9._~-]`, the escaped secret no longer matches → `access_denied: invalid client creds or client not allowed` — **and CyberArk invalidates the single-use authorization code on that failed attempt**.
4. The library automatically retries with form params (correctly encoded) — but the code is already burnt → `invalid_grant: "supplied code does not match known request"`. This is the error Headlamp logs and shows. 100 % reproducible; the style cache never helps because Headlamp builds a fresh `oauth2.Config` per login.
5. Even with an alnum-only secret (making the escaping a no-op), relying on Basic remains fragile: CyberArk's own docs specify credentials "transmitted with proper URL encoding in the token endpoint request **body**" (`client_secret_post`) for the auth-code grant.

### 5.2 Upstream status (researched exhaustively, Aug 2026)

- **No Headlamp version through v0.44.0 / `main` exposes any auth-style control.** Full OIDC flag set: `oidc-client-id`, `oidc-client-secret`, `oidc-validator-client-id`, `oidc-idp-issuer-url`, `oidc-callback-url`, `oidc-validator-idp-issuer-url`, `oidc-scopes`, `oidc-skip-tls-verify`, `oidc-ca-file`, `oidc-use-access-token`, `oidc-use-cookie`, `oidc-use-pkce` — no auth-style flag.
- go-oidc (all versions ≤ v3.20.0) never sets `AuthStyle` and never reads `token_endpoint_auth_methods_supported` — and CyberArk's discovery doc omits that field anyway. **Upgrading Headlamp changes nothing.**

### 5.3 The patch (2 sites, ~4 lines)

Base: `kubernetes-sigs/headlamp` tag `v0.40.0`.

**`backend/cmd/headlamp.go`** (login flow, ~line 731):
```go
 		verifier := provider.Verifier(oidcConfig)
+		// EIS patch (COEXT-108018): force client_secret_post — CyberArk Identity does not
+		// url-decode Basic-auth credentials, so AuthStyleAutoDetect's Basic-first attempt
+		// fails client auth and burns the single-use authorization code.
+		endpoint := provider.Endpoint()
+		endpoint.AuthStyle = oauth2.AuthStyleInParams
 		oauthConfig := &oauth2.Config{
 			ClientID:     oidcAuthConfig.ClientID,
 			ClientSecret: oidcAuthConfig.ClientSecret,
-			Endpoint:     provider.Endpoint(),
+			Endpoint:     endpoint,
```

**`backend/pkg/auth/auth.go`** (token-refresh flow, ~line 188):
```go
 	conf := &oauth2.Config{
 		ClientID:     clientID,
 		ClientSecret: clientSecret,
 		Endpoint: oauth2.Endpoint{
-			TokenURL: tokenURL,
+			TokenURL:  tokenURL,
+			AuthStyle: oauth2.AuthStyleInParams,
 		},
 	}
```

### 5.4 Build + ship

```bash
git clone --depth 1 --branch v0.40.0 https://github.com/kubernetes-sigs/headlamp
# apply the two edits above
cd headlamp/backend
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o ../headlamp-server-patched ./cmd

cat > ../Dockerfile.patch <<'EOF'
FROM ghcr.io/headlamp-k8s/headlamp:v0.40.0
COPY --chown=headlamp:headlamp headlamp-server-patched /headlamp/headlamp-server
EOF
cd .. && docker build --platform linux/amd64 -f Dockerfile.patch -t headlamp-patched:v0.40.0-eis.1 .

aws ecr create-repository --repository-name eis/headlamp --profile <acct-profile> --region us-west-2
aws ecr get-login-password --profile <acct-profile> --region us-west-2 | \
  docker login --username AWS --password-stdin <acct>.dkr.ecr.us-west-2.amazonaws.com
docker tag headlamp-patched:v0.40.0-eis.1 <acct>.dkr.ecr.us-west-2.amazonaws.com/eis/headlamp:v0.40.0-eis.1
docker push <acct>.dkr.ecr.us-west-2.amazonaws.com/eis/headlamp:v0.40.0-eis.1
```

EKS node role needs `AmazonEC2ContainerRegistryReadOnly` (standard on eis-eks node groups).

Deploy via argocd repo, `clusters/<cluster>/headlamp/values.yaml`:
```yaml
headlamp:
  image:
    registry: <acct>.dkr.ecr.us-west-2.amazonaws.com
    repository: eis/headlamp
    tag: v0.40.0-eis.1
```
(Reference: argocd MR !354. Verified log fingerprint of the patched build: source paths log as `github.com/kubernetes-sigs/headlamp/backend/...` instead of `/headlamp/backend/...`.)

**Maintenance note:** re-apply the patch on every Headlamp version bump until upstream ships the option (§8).

## 6. EKS identity provider cutover (Terraform)

In `lower/<stage>/services/terraform.tfvars`, replace `oidc_preset = "cognito"` with:

```hcl
oidc = {
  cyberark = {
    client_id      = "<client id>"
    issuer_url     = "https://<tenant>.id.cyberark.cloud/<app_id>/"   # trailing slash!
    groups_claim   = "groups"
    username_claim = "email"
  }
}
```

**Critical operational facts:**
- **EKS allows exactly ONE OIDC identity provider per cluster.** This is a CUTOVER: Cognito-issued tokens stop granting k8s access the moment cognito is disassociated (old `kub_dashboard_*` dashboards path dies — that is usually the point, but announce it).
- **Terraform destroys the old config and creates the new one IN PARALLEL — and EKS rejects the create while the old one is still disassociating** (`InvalidParameterException: Multiple Identity provider configs are not supported`). The failed run leaves the cluster with ZERO IdPs. **Recovery: simply re-plan + re-apply once the destroy has finished** (the create then succeeds alone). Plan for this two-step apply; there is no ordering knob in the module today.
- Each associate/disassociate takes ~10-25 min; budget ~40 min total.
- If other unrelated drift pollutes the plan, use a targeted plan: `atlantis plan -p <project> -- -target='module.eks["01"].module.eks.aws_eks_identity_provider_config.this'`
- **Applied-but-unmerged MR trap:** if another MR was `atlantis apply`'d on this directory but never merged, your plan will try to REVERT its live resources ("not in configuration"). Merge that MR into main first, rebase, re-plan. Read every destroy line before applying.

## 7. RBAC bindings (argocd repo)

`clusters/<cluster>/oidc/values.yaml` → `rbac.bindings`. Subjects must equal the **plain AD group names** from the token's `groups` claim (NOT the `exigengroup.com//S-1-5-21-…` SID format — that was Cognito's SAML passthrough formatting):

```yaml
- name: headlamp-<env>-admin
  group: headlamp_<env>_admin     # CyberArk groups claim carries AD group names
  cluster: true
  role: { create: true, name: headlamp-<env>-admin, rules: [ ... ] }
```

(Reference: argocd MRs !350 + !355. The shared `rbac.template` only supports cluster-wide or component-namespace bindings — no arbitrary-namespace scoping without a template change, which was explicitly rejected; cluster-wide with tiered rules mirrors the established `oc-cluster-*` pattern.)

## 8. Upstream request to Headlamp (GitHub) — the plan

Goal: stop carrying the custom image. Strategy: **feature-request issue first (with our evidence), offer the PR in the issue, then submit the PR** — small config surface, likely accepted; Portainer merged the identical option ([portainer/portainer#8966](https://github.com/portainer/portainer/issues/8966)).

- Repo: `https://github.com/kubernetes-sigs/headlamp/issues/new` (Feature request)
- Related upstream context to cite: issue #3884 (`failed to append ca cert to pool`, OIDC-adjacent), x/oauth2's documented QueryEscape-in-Basic behavior.
- Proposed shape: a backend flag + Helm value, default preserving current behavior:
  `--oidc-auth-style=auto|params|header` (env `OIDC_AUTH_STYLE`, chart `config.oidc.authStyle`).
- PR content = §5.3 patch generalized behind the flag + docs + a config test. Offer to submit it in the issue; sign the CNCF CLA.

### Draft issue text (ready to paste)

> **Title:** OIDC: allow forcing token-endpoint client auth style (client_secret_post) — auto-detect burns single-use auth codes on IdPs that don't url-decode Basic credentials
>
> **Problem.** Headlamp builds its `oauth2.Config` with `Endpoint: provider.Endpoint()` and never sets `AuthStyle`, so golang.org/x/oauth2 auto-detects: it sends the first token request as HTTP Basic with `url.QueryEscape`-ed credentials (per RFC 6749 §2.3.1), and on failure silently retries with form params — **reusing the same single-use authorization code**.
>
> Against CyberArk Identity (and any IdP that compares Basic credentials without url-decoding), a client secret containing characters like `! $ ? @ ^` makes the first attempt fail client auth, the IdP invalidates the code, and the retry then fails with `invalid_grant: supplied code does not match known request`. Login fails 100 % of the time with a misleading error. Because Headlamp constructs a fresh `oauth2.Config` per login, the library's auth-style success cache never engages, so the code-burning probe repeats on every attempt.
>
> **Reproduction.** CyberArk Identity OIDC web app, client secret with special characters, standard Headlamp OIDC setup. Every login logs `failed to exchange token: oauth2: "invalid_grant" "supplied code does not match known request"`. Manually exchanging a fresh code with `client_secret_post` (curl, form body) against the same endpoint succeeds; replaying Headlamp's exact Basic-with-escaped-secret request reproduces `access_denied: invalid client creds` followed by the burnt-code `invalid_grant` on the retry.
>
> **Ask.** Expose the auth style as configuration, e.g. `--oidc-auth-style=auto|params|header` (default `auto`, preserving today's behavior), plumbed through the Helm chart. Two code sites: the login-flow config in `backend/cmd/headlamp.go` and the refresh-flow config in `backend/pkg/auth/GetNewToken`. Precedent: Portainer added exactly this option (portainer/portainer#8966). We run this as a 4-line downstream patch (`Endpoint.AuthStyle = oauth2.AuthStyleInParams`) in production today and are happy to submit a PR.

## 9. Error → cause lookup table (everything we hit, in order)

| Symptom | Actual cause | Fix |
|---|---|---|
| `{"error":"invalid_request","error_description":"invalid redirect"}` at /Authorize | redirect URI not whitelisted on the CyberArk app | register the exact `/oidc-callback` URL |
| Callback `?error=access_denied&error_description=user not allowed access to app` | user not assigned to the CyberArk app / not in the AD groups | app assignment + group membership, wait for sync |
| Headlamp log `invalid_grant "supplied code does not match known request"` after an access_denied callback | **red herring**: Headlamp ≤v0.44 never checks the `error` param and exchanges an EMPTY code | fix the access_denied; nothing is wrong with the exchange |
| Same `invalid_grant` with a REAL code, every attempt | the §5 bug chain (Basic + escaped secret + burnt code) | patched image; alnum secret as belt-and-braces |
| "The Idira Secure Web Sessions extension isn't installed" (auth.alero.io) despite having a CyberArk extension | SWS needs its OWN extension; the Identity extension is a different product | install the SWS extension, or drop the Step-recording policy |
| Login completes, then k8s calls return 401 / UI bounces to login | cluster's EKS OIDC IdP still points at the old issuer | §6 cutover |
| Terraform apply: `Multiple Identity provider configs are not supported`, cluster left with no IdP | parallel destroy+create race in the module | re-plan + re-apply (create alone succeeds) |
| `failed to append ca cert to pool` in headlamp logs | known cosmetic upstream bug (#3884); TLS provably still works | ignore |
| `refreshing token: getting refresh token: key not found` once per minute | stale browser tab polling with no session | ignore |
| CyberArk conflates errors: wrong creds + garbage code ALSO returns "code does not match known request" | you cannot probe credential validity with a garbage code | discriminate only with a fresh valid code |

## 10. Verification toolkit (reusable techniques)

- **Get a fresh code without the app consuming it:** handcraft the /Authorize URL with a `state` the app doesn't know. The app rejects the callback ("invalid request") WITHOUT exchanging; copy the code from the URL bar and test manually. Codes live ~minutes — move fast.
- **Exchange from inside the cluster without seeing the secret:** `kubectl exec` into the pod (busybox wget) or a throwaway `curlimages/curl` pod with `envFrom: secretRef` — credentials stay server-side (`-u "$OIDC_CLIENT_ID:$OIDC_CLIENT_SECRET"`).
- **Check a secret's charset without revealing it:** `printf "%s" "$SECRET" | tr -d "A-Za-z0-9._~-"` — leftover chars are the ones QueryEscape transforms.
- **E2E sign-off:** login through CyberArk → land on the pods page of the target namespace; check headlamp logs for the exchange-error signature (should be absent); negative test: confirm the old IdP path is dead.

## 11. Post-integration checklist

- [ ] Merge the Terraform MR after the (re-)apply is green
- [ ] Detach the headlamp-oidc secret from any old Cognito Terraform module BEFORE the next apply of that stack
- [ ] Remove dead legacy RBAC bindings (old SID-based groups) once confirmed
- [ ] Trim `OIDC_SCOPES` to `openid profile email`
- [ ] Spot-check a multi-group user (groups claim string vs array)
- [ ] File/track the upstream Headlamp issue (§8) — retire the custom image when merged

## 12. Producing proof-of-working evidence (screen recording)

Stakeholders asking "is it really CyberArk-gated?" want a video, not a log excerpt. macOS:

```bash
open -a "Screenshot"                                             # picker + menu-bar stop button (Cmd+Shift+5)
screencapture -v -V 90 ~/Desktop/headlamp-cyberark-proof.mov     # CLI, auto-stops after 90s
```
`screencapture -v` needs Screen Recording permission for the invoking app (System Settings → Privacy & Security → Screen Recording), granted once, then restart the terminal.

**Record in an Incognito window** — otherwise an existing Headlamp cookie AND an existing CyberArk session make the video prove nothing. Crop the capture to the browser window so the URL bar stays visible but Slack/Jira don't.

Shot list that actually constitutes proof:

| # | Show | Proves |
|---|---|---|
| 1 | Incognito, paste the `/c/main/login` URL | no pre-existing session |
| 2 | **URL bar switching to `<tenant>.id.cyberark.cloud`** | Headlamp hands off to CyberArk — the core claim |
| 3 | CyberArk login screen | — |
| 4 | "Your session is being monitored / Step recording" → Continue | SWS policy enforced |
| 5 | Lands in Headlamp with the target namespace's pods listed | k8s API accepted the CyberArk token (EKS IdP + RBAC both correct) |
| 6 | Avatar menu showing the authenticated identity | who is logged in |

Keeping the URL bar on screen throughout is the single most convincing element. Password fields are masked so recording the login is safe, but trim any frame where an MFA code or token is legible.
