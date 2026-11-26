#!/usr/bin/env bash
# COEXT-113157: the UIs append ":443" to their API base values, so the browser calls /<service>:443/...
# For every coext-113157 rule on every VirtualService in the namespace, add a twin rule with prefix /<service>:443/
# (same destination, same rewrite) in front, unless it is already there. Idempotent.
set -euo pipefail
P=/Users/eramadan/gitwork/iac/docs/coext-113157-evidence/prep-2026-11-23
K=(kubectl --context fv-demo -n ppg-fv01 --request-timeout=20s)
"${K[@]}" get virtualservice -o json > "$P/vs-all-before-twins.json"
jq -r '.items[] | select((.spec.http // []) | map(.name // "") | any(startswith("coext-113157"))) | .metadata.name' "$P/vs-all-before-twins.json" | while read -r vs; do
  jq --arg vs "$vs" '
    (.items[] | select(.metadata.name==$vs) | .spec.http) as $http
    | [ $http[] | select((.name // "") | startswith("coext-113157")) | select(.match[0].uri.prefix | test(":443/$") | not) ] as $base
    | [ $base[] | . as $r | ($r.match[0].uri.prefix | sub("/$"; ":443/")) as $tp
        | select([ $http[] | .match[0].uri.prefix ] | index($tp) | not)
        | {op:"add", path:"/spec/http/0", value: ($r | .name = ($r.name + "-443") | .match = [{uri:{prefix:$tp}}])} ]' \
    "$P/vs-all-before-twins.json" > "$P/twins-$vs.jsonpatch.json"
  n=$(jq length "$P/twins-$vs.jsonpatch.json")
  if [ "$n" -gt 0 ]; then
    "${K[@]}" patch virtualservice "$vs" --type=json --patch-file "$P/twins-$vs.jsonpatch.json" >/dev/null
    echo "$vs: added $n twin rule(s)"
  else
    echo "$vs: nothing to add"
  fi
done
