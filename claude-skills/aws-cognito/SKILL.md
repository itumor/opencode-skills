---
name: aws-cognito
description: Generic AWS Cognito usage — User Pools vs Identity Pools (the two are not interchangeable), SAML/OIDC federation setup (metadata_url, ACS URL, audience/entity ID), app client vs app integration distinctions, the difference between assigning an app to a user and granting an RBAC group ("No access" errors), hosted UI domains, and token types (ID vs access vs refresh). Use whenever the user mentions Cognito, SAML/SSO login via Cognito, a Cognito app client, "No access" after SSO login, federating an IdP into Cognito, or Cognito User Pool vs Identity Pool confusion — even if they just say "our SSO login" or "the AWS login screen." Not tied to any one company's IdP; for EIS/OneSuite's Cognito SAML repoint pattern, prefer this repo's own memory/skills on that topic first if present.
---

# AWS Cognito

Cognito has two genuinely different products under one name — mixing them up is the single most common source of confusion.

## User Pools vs Identity Pools — not interchangeable

| | User Pool | Identity Pool (Federated Identities) |
|---|---|---|
| What it is | A user directory + auth server — sign-up/sign-in, MFA, SAML/OIDC federation, issues JWTs | A broker that exchanges a token (from a User Pool, or another IdP) for temporary AWS IAM credentials |
| Output | ID/access/refresh tokens (JWTs) | Temporary AWS STS credentials (`AssumeRoleWithWebIdentity` under the hood) |
| Use case | "Log a user into my app" | "Let a logged-in user directly call AWS APIs (S3, DynamoDB) from a client" |

A User Pool alone is enough for app login (e.g. gating an ArgoCD/Grafana/internal-tool SSO flow) — an Identity Pool is only needed when the authenticated user (or an unauthenticated guest) needs actual AWS credentials client-side. Provisioning an Identity Pool for a use case that only needed a User Pool is a common unnecessary-complexity mistake.

## SAML/OIDC federation into a User Pool

Key fields when wiring an external IdP (Okta, Azure AD, ADFS, Keycloak, IdC) as a SAML provider:

- **Metadata URL** (or uploaded metadata XML): tells Cognito the IdP's signing cert and SSO endpoint. If the IdP rotates its signing cert, a `metadata_url` (fetched live) survives that automatically; a one-time uploaded XML file does not — repoint to `metadata_url` where possible.
- **ACS URL** (Assertion Consumer Service): the IdP must be configured to POST the SAML assertion back to Cognito's fixed callback, `https://<user-pool-domain>/saml2/idpresponse` — a typo or stale value here is the most common "SSO redirects but never actually logs in" cause.
- **Audience / Entity ID**: must match exactly between the IdP's relying-party config and what Cognito presents as its SP entity ID (`urn:amazon:cognito:sp:<user-pool-id>`) — a mismatch here fails silently or with a vague SAML validation error, not a clear "audience mismatch" message.
- **Attribute mapping**: maps SAML assertion attributes (email, groups, etc.) to Cognito User Pool attributes — a missing required attribute mapping (usually `email`) blocks user creation on first login even though the SAML handshake itself succeeded.

## "No access" after a successful SSO login

This is almost always **not** an authentication failure — the SAML handshake and User Pool login worked, but the user isn't in the app's own authorization mapping. Being *assigned the app* (IdP-side app assignment, or existing as a Cognito user) is a different thing from being *in the RBAC group* the downstream app checks (e.g. an ArgoCD `groups` claim mapped to a role, or a custom attribute the app reads). Two separate admin actions, two separate places to check:

1. IdP side: is the user/group assigned to this application at all?
2. App/Cognito side: does the group-to-role or attribute-to-permission mapping actually include them?

## App clients vs app integration domain

- **App client**: the OAuth2/OIDC client_id (+ optional secret) a specific application uses to talk to the User Pool — each app usually gets its own client so token scopes/callback URLs can differ per app.
- **Hosted UI domain**: the actual login page URL (`https://<domain>.auth.<region>.amazoncognito.com/login` or a custom domain) — shared across app clients in the same pool, configured once at the pool level.

## Token types

- **ID token**: JWT asserting who the user is (claims like email, groups) — what an app should validate to authorize/identify the user.
- **Access token**: JWT scoped for calling Cognito's own User Pool API (or a resource server) — not generally the token to hand to your own backend for authorization decisions.
- **Refresh token**: exchanges for new ID/access tokens without re-prompting login, subject to the pool's refresh token expiry (default 30 days).

Using the access token where the ID token was intended (or vice versa) is a common integration bug — check which one a downstream app's OIDC library actually expects to validate.
