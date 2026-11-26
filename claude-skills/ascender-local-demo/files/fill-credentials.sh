#!/bin/bash
# Fill the two credentials in the LOCAL demo Ascender (http://127.0.0.1:32000) in one run.
# Secrets go straight from `aws` / `glab` into the local Ascender API over stdin.
# Nothing secret is printed, written to disk, or put on a command line.
#
#   bash fill-credentials.sh            # AWS temp keys + new GitLab deploy token
#   bash fill-credentials.sh aws        # only refresh the AWS keys (after a new `aws sso login`)
#   bash fill-credentials.sh --selftest
set -euo pipefail
URL=http://127.0.0.1:32000/api/v2
AWS_PROFILE_NAME=PTO-Reference
GITLAB=sfo-cvdevopsgit01.eqxdev.exigengroup.com
GL_PROJECT='iac%2Fprojects%2Faws%2Fpto-reference%2Fansible'
SCM_CRED='GitLab pto-reference (read)'
AWS_CRED='AWS PTO-Reference (temporary)'

aws_payload() { jq -c '{inputs: {username: .AccessKeyId, password: .SecretAccessKey, security_token: .SessionToken}}'; }
scm_payload() { jq -c '{inputs: {username: .username, password: .token}}'; }

if [ "${1:-}" = "--selftest" ]; then
  [ "$(printf '{"AccessKeyId":"a","SecretAccessKey":"b","SessionToken":"c","Expiration":"x"}' | aws_payload)" = '{"inputs":{"username":"a","password":"b","security_token":"c"}}' ]
  [ "$(printf '{"id":1,"username":"u","token":"t"}' | scm_payload)" = '{"inputs":{"username":"u","password":"t"}}' ]
  echo "selftest ok"; exit 0
fi

kc() { kubectl --kubeconfig "$HOME/.kube/kind-ascender-demo.config" --context kind-ascender-demo -n awx "$@"; }
PW=$(kc get secret ascender-demo-admin-password -o jsonpath='{.data.password}' | base64 -d)
# auth via a curl config on a file descriptor, so the password is not in the process list
api() { curl -s -K <(printf 'user = "admin:%s"\n' "$PW") -H 'Content-Type: application/json' "$@"; }
cred_id() { api "$URL/credentials/?name=$(jq -rn --arg n "$1" '$n|@uri')" | jq -r '.results[0].id // empty'; }
patch_cred() { # patch_cred ID  (payload on stdin) -> prints only the HTTP code
  api -o /dev/null -w '%{http_code}' -X PATCH -d @- "$URL/credentials/$1/"
}

# ---- AWS temporary keys -----------------------------------------------------
AID=$(cred_id "$AWS_CRED"); [ -n "$AID" ] || { echo "credential '$AWS_CRED' not found in Ascender" >&2; exit 1; }
J=$(aws configure export-credentials --profile "$AWS_PROFILE_NAME" --format process) ||
  { echo "no AWS session: run  aws sso login --profile $AWS_PROFILE_NAME" >&2; exit 1; }
code=$(printf '%s' "$J" | aws_payload | patch_cred "$AID")
echo "AWS credential (id $AID): HTTP $code, keys expire $(printf '%s' "$J" | jq -r .Expiration)"
unset J
[ "$code" = 200 ] || exit 1
[ "${1:-}" = "aws" ] && exit 0

# ---- GitLab deploy token (read_repository, 2 days) --------------------------
SID=$(cred_id "$SCM_CRED"); [ -n "$SID" ] || { echo "credential '$SCM_CRED' not found in Ascender" >&2; exit 1; }
EXP=$(date -v+2d +%F)
unset GITLAB_TOKEN   # a stale env token overrides glab's own login
T=$(printf '{"name":"ascender-poc-demo-%s","scopes":["read_repository"],"expires_at":"%s"}' "$(date +%m%d-%H%M)" "$EXP" |
  GITLAB_HOST=$GITLAB glab api --method POST "projects/$GL_PROJECT/deploy_tokens" --input - -H 'Content-Type: application/json') ||
  { echo "GitLab refused to create the deploy token (needs Maintainer on the repo, and VPN)" >&2; exit 1; }
[ -n "$(printf '%s' "$T" | jq -r '.token // empty')" ] || { echo "GitLab answer had no token: $(printf '%s' "$T" | jq -c 'del(.token)')" >&2; exit 1; }
code=$(printf '%s' "$T" | scm_payload | patch_cred "$SID")
echo "GitLab credential (id $SID): HTTP $code, deploy token id $(printf '%s' "$T" | jq -r .id) '$(printf '%s' "$T" | jq -r .name)', expires $EXP"
unset T
[ "$code" = 200 ]
