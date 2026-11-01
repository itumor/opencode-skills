---
name: spa-portal-csp-audit
description: Use when reviewing or writing a Content-Security-Policy for an EIS portal SPA behind CloudFront (aws_cloudfront_response_headers_policy, portals_csp_custom.tf), or when asked "will this CSP break the portal", "check the CSP against the portal", "which origins does the portal call", "decrypt dxp.json", "externalHost / externalDXPPath wrong". Proves each CSP directive against the LIVE bundle and the decrypted dxp.json instead of guessing from framework folklore. Reference: CAA !264 (COEXT-110654), 2026-10-27.
---

# SPA portal CSP audit

A CSP finding counts only when the shipped code shows it. On 2026-10-27, "no frame-src blocks the Keycloak iframe" (agreed by PR-Agent) was false. The real breaks were in `font-src` and `img-src`, and none of them appear in a Terraform plan.

## Steps

1. **Fetch the live bundle** for every portal and env (broker AND member, stage AND prod; builds differ).
   - Use a browser UA. WAF Bot Control blocks the curl UA.
   - Save each host's files in its own dir in the scratchpad.
   ```bash
   UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
   curl -sS -A "$UA" -o "$D/$h.html" "https://$h/"
   # then curl every src=/href= .js/.css from the index into $D/$h.js/
   ```
2. **Scan the bundle per directive:** `python3 -I csp_scan.py <dir> <host>...`. It reports:
   - external https hosts in JS
   - CSS `url(https://...)` (fonts.gstatic.com Material Icons -> `font-src`)
   - `createObjectURL` (-> `img-src blob:`, and `connect-src blob:` if pdf.js reads it)
   - `new Function`/eval (-> `'unsafe-eval'`)
   - dynamic script loaders (`maps.googleapis.com` -> `script-src`)
   - auth-iframe markers (keycloak-js `checkLoginIframe`/`silent-check-sso`, oidc `signinSilent`/`monitorSession`/`check_session_iframe`). All zero = no `frame-src` needed.
3. **Decrypt the runtime config:** `python3 -I dxp_decrypt.py <dir> <host>...`.
   - EIS portals fetch `/dxp.json`, CryptoJS AES (`U2FsdGVkX1` = `Salted__`).
   - The key is a literal in `main.js` near `resolveDxpDecryptionSecret` (S3 mode, `DXP_SHARED_SECRET`): obfuscation, not secrecy.
   - The script decrypts with `openssl enc -d -aes-256-cbc -md md5` and prints only host/URL fields. Secret-like keys are redacted, and **the key itself is never printed**.
4. **Map the config to the CSP:**
   - `externalHost` == served hostname -> the SPA calls `externalDXPPath`; it must be in `connect-src`.
   - Mismatch (CAA stage: `www.pre.…` vs served `pre.…`) -> fallback to `basePath`/`memberDXPPath` (in-VPC `*-app-caa-<env>` hosts).
   - `ssoConfig.metadataUrl` -> fetch that discovery doc and check that the authorization/token/userinfo/end_session hosts equal the Keycloak origin in `connect-src` + `form-action`.
5. **Login flow check:**
   - Full-page redirect + XHR token = only `connect-src` + navigation.
   - An advertised `check_session_iframe` does not matter unless the bundle uses `monitorSession`.
6. **Verify after the stage apply:** open the portal, log in, open eFolder/PDF screens, check that DevTools Console has no `Refused to …` errors. Then prod.

## Traps
- **Never print context around string literals to "mask" a secret.** A regex mask failed on 2026-10-27 and printed the bundle key into the transcript. Extract the value in-process and write it to a temp file for `openssl -pass file:`.
- prod-guard blocks Read/cat of any `**/prod/**` path: take the prod CSP string from the Atlantis plan note.
- Today's live CloudFront serves `Managed-SecurityHeadersPolicy` (no CSP). Breaks appear only after apply, so the plan alone is no proof.
