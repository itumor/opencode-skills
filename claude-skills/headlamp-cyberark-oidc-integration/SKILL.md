---
name: headlamp-cyberark-oidc-integration
description: End-to-end playbook for putting Headlamp behind CyberArk Identity ("Idira") OIDC on an EIS EKS cluster — CyberArk app + AD groups, headlamp-oidc secret, the mandatory patched Headlamp image (client_secret_post), the EKS identity-provider cutover with its parallel destroy/create race, name-based RBAC bindings, and full E2E verification. Use when a ticket says "headlamp should work only via CA/CyberArk", when integrating any EIS dashboard with CyberArk OIDC, when a Headlamp login loops with invalid_grant "supplied code does not match known request", when a CyberArk callback returns access_denied "user not allowed access to app", when the SWS "extension isn't installed" gate blocks login, or when a working OIDC login still gets 401 from the Kubernetes API. Reference: COEXT-108018, aws0caatesteks01, 2026-08-10.
---

# Headlamp ↔ CyberArk Identity OIDC integration

Full runbook with commands, diffs, and evidence: **GUIDE.md in this skill directory**.
This file = decision-critical facts only.

## The 6 phases (order matters)

1. **External asks first** (lead time): AD groups `headlamp_<env>_{admin,rw,r}`, CyberArk OIDC app, app access granted to those groups, a test user IN a group. Redirect URI = exact `https://headlamp-monitoring.<domain>/oidc-callback`. **Client secret MUST be alphanumeric-only** (see Trap 1).
2. **headlamp-oidc secret** (SM → ESO → pod env): 4 keys `OIDC_CLIENT_ID/SECRET/ISSUER_URL/SCOPES`; issuer keeps its **trailing slash** (byte-match token `iss`); scopes = `openid profile email`. Then force ESO sync + rollout restart. If the secret resource is owned by old Cognito Terraform (`cognito.clients.*` in infra/services), DETACH it or a later apply reverts your value.
3. **Patched Headlamp image** — non-negotiable, no upstream flag exists (verified through v0.44.0; tracking [headlamp#7064](https://github.com/kubernetes-sigs/headlamp/issues/7064)). Patch = `Endpoint.AuthStyle = oauth2.AuthStyleInParams` at BOTH sites: `backend/cmd/headlamp.go` login flow (~L731 in v0.40.0) and `backend/pkg/auth/auth.go` GetNewToken refresh flow (~L188). Build backend-only (`CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build ./cmd`), overlay on official image, push to account ECR (nodes have `AmazonEC2ContainerRegistryReadOnly`), set `headlamp.image.{registry,repository,tag}` in argocd cluster values. Patched-build log fingerprint: source paths start `github.com/kubernetes-sigs/headlamp/...`.
4. **EKS IdP cutover** (Terraform, `lower/<stage>/services/terraform.tfvars`): replace `oidc_preset="cognito"` with `oidc = { cyberark = { client_id, issuer_url (trailing slash), groups_claim="groups", username_claim="email" } }`. **One OIDC IdP per EKS cluster — this kills Cognito-token k8s access; announce it.**
5. **RBAC bindings** (argocd `clusters/<c>/oidc/values.yaml`): subjects = plain AD group NAMES (`headlamp_caa-uat_admin`), NOT `exigengroup.com//S-1-5-21-…` SIDs (that format was Cognito SAML passthrough). CyberArk emits `groups` claim with names — as a scalar STRING for single-group users (k8s accepts it; multi-group shape unverified).
6. **E2E**: login via CyberArk (+SWS extension if Step-recording policy) → pods page of target namespace renders. Negative: old IdP path dead. For stakeholder proof record a screen video — **Incognito window** (else a cached session proves nothing) with the **URL bar visible** so the handoff to `<tenant>.id.cyberark.cloud` is on camera; `open -a "Screenshot"` or `screencapture -v -V 90 out.mov` (needs Screen Recording permission). Full shot list: GUIDE.md §12.

## The traps (each cost hours — read before starting)

1. **Special-char client secret = 100% login failure.** Go oauth2 auto-detect sends attempt #1 as HTTP Basic with `url.QueryEscape`d creds; CyberArk does NOT url-decode → rejects creds AND **burns the single-use code**; the automatic form-param retry then gets `invalid_grant "supplied code does not match known request"`. Style never caches (fresh Config per login). Fix = patch (phase 3) + alnum secret. Full mechanism: memory `cyberark-oidc-go-client-secret-trap`.
2. **The same `invalid_grant` log line has TWO meanings.** Headlamp ≤v0.44 never checks the callback's `error` param — an `access_denied` callback (no code) still triggers an exchange with an EMPTY code → identical log. Look at the browser's callback URL to tell them apart. `access_denied: user not allowed access to app` = CyberArk app-assignment/AD-membership missing, nothing else.
3. **EKS IdP swap: Terraform destroys+creates IN PARALLEL and EKS rejects the create** (`InvalidParameterException: Multiple Identity provider configs are not supported`) while the old config is still disassociating — leaving the cluster with ZERO IdPs. Recovery = re-plan + re-apply after the destroy completes (create alone succeeds). Budget ~40 min; expect the two-step.
4. **Applied-but-unmerged MR drift**: if another MR was atlantis-applied on the same dir but never merged, your branch (off main) plans to REVERT its live resources ("not in configuration") — we nearly destroyed the bld01 egress lockdown. Merge that MR first, rebase, re-plan. READ EVERY DESTROY LINE.
5. **Surgical applies work**: `atlantis plan -p <proj> -- -target='module.eks["01"].module.eks.aws_eks_identity_provider_config.this'` then plain `atlantis apply -p <proj>` applies the stored targeted plan — used to exclude unrelated drift the user refused to apply.
6. **`atlantis unlock` comment** on the lock-holding MR releases ALL its locks + discards plans (re-creatable later with one `atlantis plan`). Works when the classifier/UI path doesn't.
7. **SWS ≠ Identity extension.** "The Idira Secure Web Sessions extension isn't installed" needs the separate SWS Chrome extension (`ohfinlfcbaehgokpmkjcmkgdcbgamgln`), not the CyberArk Identity one. Both coexist.
8. **Login works but k8s 401s** = the cluster's IdP still points at the old issuer — phase 4 missing. Two trust relationships, not one.

## Debug toolkit (reusable anywhere OIDC)

- **Fresh code without the app consuming it**: handcraft the /Authorize URL with an unknown `state` — app rejects callback WITHOUT exchanging; grab code from URL bar, exchange manually within ~1 min.
- **Exchange without seeing creds**: `kubectl exec` (busybox wget) or throwaway `curlimages/curl` pod with `envFrom: secretRef` — `$OIDC_CLIENT_ID/$OIDC_CLIENT_SECRET` stay server-side.
- **CyberArk conflates errors**: garbage code + wrong creds BOTH return "code does not match known request" — only a fresh VALID code discriminates credential problems.
- **Secret charset check, value-blind**: `printf "%s" "$SECRET" | tr -d "A-Za-z0-9._~-"` — leftovers are what QueryEscape mangles.
- Discovery doc = `https://<tenant>.id.cyberark.cloud/<app_id>/.well-known/openid-configuration` (also `/OAuth2/GetMeta?serviceName=<app_id>`); redirect whitelist is NOT visible there — probe /Authorize with candidate redirect_uris (no auth needed; `invalid redirect` = not whitelisted).

## Related

Memories: `cyberark-oidc-go-client-secret-trap`, `project_coext108018_headlamp_caa_uat`, `reference_headlamp-oidc-fqdn-pattern`. Skills: `atlantis-lock-troubleshooting` (locks), repo skill `atlantis-debug` (credit-agricole). Upstream tracking: headlamp#7064 — retire the custom image when merged.
