---
name: istio-san-wildcard
description: Use when an Istio DestinationRule in SIMPLE TLS mode fails with CERTIFICATE_VERIFY_FAILED or "verify SAN list" after a valid cert is deployed — especially wildcard certs like *.domain.tld. Symptom: curl/service returns 503, Envoy logs show TLS_error verify SAN list.
---

# Istio SAN wildcard — DestinationRule fix

## The Problem

Istio Envoy in `SIMPLE` TLS mode performs SAN (Subject Alternative Name) verification. Wildcard certs (`*.domain.tld`) are **not matched automatically** — Envoy won't expand the wildcard unless you explicitly declare `subjectAltNames` in the DestinationRule.

```
TLS_error: CERTIFICATE_VERIFY_FAILED: verify SAN list
```

## Fix — add subjectAltNames to DestinationRule

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
spec:
  host: aws0caakeycloak01.infra.aws0.caa-eis.cloud
  trafficPolicy:
    tls:
      mode: SIMPLE
      subjectAltNames:
        - "*.infra.aws0.caa-eis.cloud"
```

## Helm template gotcha — YAML quote wildcard

If `subjectAltNames` values come from a Helm values file, bare `*` breaks YAML parsing:

```
YAML parse error: did not find expected alphabetic or numeric character
```

Fix: use `| quote` in the range loop:

```yaml
{{- range $s.subjectAltNames }}
- {{ . | quote }}   # NOT just {{ . }}
{{- end }}
```

Values file entry must quote the wildcard too:

```yaml
subjectAltNames:
  - "*.infra.aws0.caa-eis.cloud"   # quotes required
```

## Temporary workaround (never leave in prod)

```yaml
trafficPolicy:
  tls:
    mode: SIMPLE
    insecureSkipVerify: true   # disables ALL cert validation — temp only
```

Replace with `subjectAltNames` immediately.

## Passthrough mode

For TLS passthrough (`passthrough-gw`) there is no DestinationRule — SNI is forwarded as-is. SAN issue only occurs with SIMPLE or MUTUAL mode.
