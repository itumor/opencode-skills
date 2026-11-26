#!/usr/bin/env bash
# COEXT-113157: some UIs append ":443" to GENESIS_HOST, so the browser calls /dxp-gateway:443/...
# Adds one more rule (prefix /dxp-gateway:443/ -> dxp-gateway:9191, rewrite /) in front of the VirtualService rules.
# Usage: add-443-route.sh <release-dir-name> <virtualservice> <ui-host>
set -euo pipefail
P=/Users/eramadan/gitwork/iac/docs/coext-113157-evidence/prep-2026-11-23
REL=$1; VS=$2; UIH=$3
K=(kubectl --context fv-demo -n ppg-fv01)
if "${K[@]}" get virtualservice "$VS" -o json | jq -e '.spec.http[] | select(.name=="coext-113157-dxp-gateway-443")' >/dev/null; then
  echo "$REL: rule already present"; exit 0
fi
jq -n --arg h "$UIH" '[{op:"add",path:"/spec/http/0",value:{name:"coext-113157-dxp-gateway-443",match:[{uri:{prefix:"/dxp-gateway:443/"}}],rewrite:{uri:"/"},route:[{destination:{host:"dxp-gateway",port:{number:9191}},headers:{request:{set:{"x-forwarded-host":$h,"x-forwarded-proto":"https"}}}}]}}]' > "$P/$REL/vs-add-443-route.jsonpatch.json"
"${K[@]}" patch virtualservice "$VS" --type=json --patch-file "$P/$REL/vs-add-443-route.jsonpatch.json"
sleep 3
printf '%s /dxp-gateway:443/core/v1/version -> ' "$REL"
curl -sk --max-time 15 -o /dev/null -w '%{http_code} %{content_type}\n' "https://$UIH/dxp-gateway:443/core/v1/version"
