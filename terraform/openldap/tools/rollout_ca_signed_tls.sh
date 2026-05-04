#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Roll out CA-signed TLS to OpenLDAP via Terraform and validate connectivity.

Required:
  --ca-cert PATH
  --server-cert PATH
  --server-key PATH
  --read-host HOST
  --write-host HOST

Optional:
  --tf-dir PATH                  (default: terraform/openldap)
  --tfvars PATH                  (default: <tf-dir>/ca_signed_tls.tfvars)
  --ansible-connection ssh|ssm   (optional terraform override)
  --bind-dn DN                   (default: cn=admin,dc=cae,dc=local)
  --bind-pw PASSWORD             (default: LDAP_BIND_PW env var)
  --base-dn DN                   (default: dc=cae,dc=local)
  --report PATH                  (default: <tf-dir>/reports/CA_SIGNED_TLS_ROLLOUT_<utc>.md)
  --no-apply                     (skip terraform apply)
  --skip-tls-checks              (skip openssl endpoint checks)
  --skip-dns-check               (skip DNS validation for read/write hosts)
  --skip-ldap-tests              (skip ldapwhoami/search/write checks)
  --no-auto-approve              (prompt on terraform apply)
  --help

Example:
  bash terraform/openldap/tools/rollout_ca_signed_tls.sh \
    --ca-cert /secure/ca.crt \
    --server-cert /secure/ldap-chain.pem \
    --server-key /secure/ldap.key \
    --read-host ldap-read.example.com \
    --write-host ldap-write.example.com \
    --bind-pw '***'
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

fatal() {
  printf '[FATAL] %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"
}

cert_matches_hostname() {
  local cert="$1"
  local host="$2"

  if openssl verify -help 2>&1 | grep -q -- '-verify_hostname'; then
    openssl verify -CAfile "$CA_CERT" -verify_hostname "$host" "$cert" >/dev/null 2>&1
    return $?
  fi

  openssl x509 -in "$cert" -noout -text 2>/dev/null \
    | awk '
      /Subject Alternative Name/ {capture=1; next}
      capture && /^[[:space:]]*X509v3/ {capture=0}
      capture {print}
    ' \
    | tr ',' '\n' | sed 's/^[[:space:]]*//' \
    | grep -q -F "DNS:${host}"
}

resolve_host() {
  local host="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short "$host" | awk 'NF {print; exit}' >/dev/null
    return $?
  fi
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$host" >/dev/null
    return $?
  fi
  if command -v host >/dev/null 2>&1; then
    host "$host" >/dev/null 2>&1
    return $?
  fi
  fatal "No DNS resolver command available (dig/getent/host)"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TF_DIR="${DEFAULT_TF_DIR}"
TFVARS_PATH=""
REPORT_PATH=""

CA_CERT=""
SERVER_CERT=""
SERVER_KEY=""
READ_HOST=""
WRITE_HOST=""
BIND_DN="cn=admin,dc=cae,dc=local"
BIND_PW="${LDAP_BIND_PW:-}"
BASE_DN="dc=cae,dc=local"
ANSIBLE_CONNECTION=""

RUN_APPLY=1
RUN_TLS_CHECKS=1
RUN_DNS_CHECK=1
RUN_LDAP_TESTS=1
AUTO_APPROVE=1

while (($# > 0)); do
  case "$1" in
    --ca-cert) CA_CERT="${2:-}"; shift 2 ;;
    --server-cert) SERVER_CERT="${2:-}"; shift 2 ;;
    --server-key) SERVER_KEY="${2:-}"; shift 2 ;;
    --read-host) READ_HOST="${2:-}"; shift 2 ;;
    --write-host) WRITE_HOST="${2:-}"; shift 2 ;;
    --tf-dir) TF_DIR="${2:-}"; shift 2 ;;
    --tfvars) TFVARS_PATH="${2:-}"; shift 2 ;;
    --bind-dn) BIND_DN="${2:-}"; shift 2 ;;
    --bind-pw) BIND_PW="${2:-}"; shift 2 ;;
    --base-dn) BASE_DN="${2:-}"; shift 2 ;;
    --ansible-connection) ANSIBLE_CONNECTION="${2:-}"; shift 2 ;;
    --report) REPORT_PATH="${2:-}"; shift 2 ;;
    --no-apply) RUN_APPLY=0; shift ;;
    --skip-tls-checks) RUN_TLS_CHECKS=0; shift ;;
    --skip-dns-check) RUN_DNS_CHECK=0; shift ;;
    --skip-ldap-tests) RUN_LDAP_TESTS=0; shift ;;
    --no-auto-approve) AUTO_APPROVE=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *)
      fatal "Unknown option: $1"
      ;;
  esac
done

[[ -n "$CA_CERT" ]] || fatal "--ca-cert is required"
[[ -n "$SERVER_CERT" ]] || fatal "--server-cert is required"
[[ -n "$SERVER_KEY" ]] || fatal "--server-key is required"
[[ -n "$READ_HOST" ]] || fatal "--read-host is required"
[[ -n "$WRITE_HOST" ]] || fatal "--write-host is required"

CA_CERT="$(cd "$(dirname "$CA_CERT")" && pwd)/$(basename "$CA_CERT")"
SERVER_CERT="$(cd "$(dirname "$SERVER_CERT")" && pwd)/$(basename "$SERVER_CERT")"
SERVER_KEY="$(cd "$(dirname "$SERVER_KEY")" && pwd)/$(basename "$SERVER_KEY")"
TF_DIR="$(cd "$TF_DIR" && pwd)"

[[ -f "$CA_CERT" ]] || fatal "CA cert not found: $CA_CERT"
[[ -f "$SERVER_CERT" ]] || fatal "Server cert not found: $SERVER_CERT"
[[ -f "$SERVER_KEY" ]] || fatal "Server key not found: $SERVER_KEY"
[[ -d "$TF_DIR" ]] || fatal "Terraform directory not found: $TF_DIR"

if [[ -z "$TFVARS_PATH" ]]; then
  TFVARS_PATH="${TF_DIR}/ca_signed_tls.tfvars"
fi
if [[ -z "$REPORT_PATH" ]]; then
  REPORT_PATH="${TF_DIR}/reports/CA_SIGNED_TLS_ROLLOUT_$(date -u +%Y%m%dT%H%M%SZ).md"
fi

mkdir -p "$(dirname "$REPORT_PATH")"

need_cmd openssl
if [[ "$RUN_APPLY" -eq 1 ]]; then
  need_cmd terraform
fi
if [[ "$RUN_LDAP_TESTS" -eq 1 ]]; then
  need_cmd ldapwhoami
  need_cmd ldapsearch
  need_cmd ldapadd
  need_cmd ldapdelete
  [[ -n "$BIND_PW" ]] || fatal "Bind password required for LDAP tests. Use --bind-pw or LDAP_BIND_PW."
fi

{
  echo "# CA-signed TLS rollout report"
  echo
  echo "- UTC time: $(date -u '+%Y-%m-%d %H:%M:%S')"
  echo "- Read host: ${READ_HOST}"
  echo "- Write host: ${WRITE_HOST}"
  echo "- Terraform dir: ${TF_DIR}"
  echo "- TF vars file: ${TFVARS_PATH}"
  echo
} >"$REPORT_PATH"

log "Preflight: checking certificate and key consistency"
cert_pub="$(
  openssl x509 -in "$SERVER_CERT" -pubkey -noout \
    | openssl pkey -pubin -outform DER \
    | openssl dgst -sha256 | awk '{print $2}'
)"
key_pub="$(
  openssl pkey -in "$SERVER_KEY" -pubout -outform DER \
    | openssl dgst -sha256 | awk '{print $2}'
)"
[[ "$cert_pub" == "$key_pub" ]] || fatal "Server cert and key do not match"

log "Preflight: checking certificate chain against CA"
openssl verify -CAfile "$CA_CERT" "$SERVER_CERT" >/dev/null

log "Preflight: checking SAN/hostname match for read/write hosts"
cert_matches_hostname "$SERVER_CERT" "$READ_HOST" || fatal "Server cert SAN/CN does not match read host: $READ_HOST"
cert_matches_hostname "$SERVER_CERT" "$WRITE_HOST" || fatal "Server cert SAN/CN does not match write host: $WRITE_HOST"

if [[ "$RUN_DNS_CHECK" -eq 1 ]]; then
  log "Preflight: validating DNS resolution"
  resolve_host "$READ_HOST" || fatal "Read host does not resolve: $READ_HOST"
  resolve_host "$WRITE_HOST" || fatal "Write host does not resolve: $WRITE_HOST"
fi

log "Writing Terraform var file: $TFVARS_PATH"
{
  echo "tls_cert_mode = \"external_required\""
  echo
  echo "tls_ca_cert_pem = <<EOT"
  cat "$CA_CERT"
  echo
  echo "EOT"
  echo
  echo "tls_cert_pem = <<EOT"
  cat "$SERVER_CERT"
  echo
  echo "EOT"
  echo
  echo "tls_key_pem = <<EOT"
  cat "$SERVER_KEY"
  echo
  echo "EOT"
} >"$TFVARS_PATH"
chmod 600 "$TFVARS_PATH" || true

if [[ "$RUN_APPLY" -eq 1 ]]; then
  log "Running terraform init/apply in $TF_DIR"
  (
    cd "$TF_DIR"
    terraform init -backend-config=backend.hcl
    apply_cmd=(terraform apply "-var-file=$(basename "$TFVARS_PATH")")
    if [[ "$AUTO_APPROVE" -eq 1 ]]; then
      apply_cmd+=("-auto-approve")
    fi
    if [[ -n "$ANSIBLE_CONNECTION" ]]; then
      apply_cmd+=("-var" "ansible_connection=${ANSIBLE_CONNECTION}")
    fi
    "${apply_cmd[@]}"
  )
fi

run_tls_check() {
  local host="$1"
  local mode="$2"
  local out
  local presented
  local expected_fp
  local presented_fp
  out="$(mktemp)"
  presented="$(mktemp)"
  expected_fp="$(openssl x509 -in "$SERVER_CERT" -noout -fingerprint -sha256 | awk -F= '{print $2}')"

  if [[ "$mode" == "ldaps" ]]; then
    openssl s_client -connect "${host}:636" -servername "${host}" -showcerts -CAfile "$CA_CERT" </dev/null >"$out" 2>&1 || true
  else
    openssl s_client -connect "${host}:389" -starttls ldap -servername "${host}" -showcerts -CAfile "$CA_CERT" </dev/null >"$out" 2>&1 || true
  fi

  grep -q "Verify return code: 0 (ok)" "$out" || {
    sed -n '1,120p' "$out" >&2
    rm -f "$presented"
    rm -f "$out"
    fatal "TLS verification failed for ${host} (${mode})"
  }

  awk '
    /BEGIN CERTIFICATE/ {capture=1}
    capture {print}
    /END CERTIFICATE/ {exit}
  ' "$out" >"$presented"
  [[ -s "$presented" ]] || fatal "Could not extract presented certificate for ${host} (${mode})"

  presented_fp="$(openssl x509 -in "$presented" -noout -fingerprint -sha256 | awk -F= '{print $2}')"
  [[ "$presented_fp" == "$expected_fp" ]] || fatal "Endpoint ${host} (${mode}) is not presenting the expected server certificate"
  cert_matches_hostname "$presented" "$host" || fatal "Endpoint ${host} (${mode}) certificate hostname verification failed"

  rm -f "$presented"
  rm -f "$out"
}

if [[ "$RUN_TLS_CHECKS" -eq 1 ]]; then
  log "Validating TLS handshake + trust for read/write endpoints"
  run_tls_check "$READ_HOST" "ldaps"
  run_tls_check "$WRITE_HOST" "ldaps"
  run_tls_check "$READ_HOST" "starttls"
  run_tls_check "$WRITE_HOST" "starttls"
fi

if [[ "$RUN_LDAP_TESTS" -eq 1 ]]; then
  log "Running strict-trust LDAP tests"
  export LDAPTLS_CACERT="$CA_CERT"
  export LDAPTLS_REQCERT=demand

  ldapwhoami -x -o nettimeout=8 -H "ldaps://${READ_HOST}:636" -D "$BIND_DN" -w "$BIND_PW" >/dev/null
  ldapwhoami -x -o nettimeout=8 -H "ldaps://${WRITE_HOST}:636" -D "$BIND_DN" -w "$BIND_PW" >/dev/null

  ldapsearch -LLL -x -o nettimeout=8 -H "ldaps://${READ_HOST}:636" -D "$BIND_DN" -w "$BIND_PW" -b "$BASE_DN" -s base dn >/dev/null
  ldapsearch -LLL -x -ZZ -o nettimeout=8 -H "ldap://${READ_HOST}:389" -D "$BIND_DN" -w "$BIND_PW" -b "$BASE_DN" -s base dn >/dev/null

  ts="$(date -u +%Y%m%d%H%M%S)"
  cn="ca-rollout-${ts}"
  dn="cn=${cn},${BASE_DN}"
  ldif="$(mktemp)"
  cat >"$ldif" <<EOF
dn: ${dn}
objectClass: organizationalRole
cn: ${cn}
description: ${cn}
EOF

  cleanup() {
    ldapdelete -x -o nettimeout=8 -H "ldaps://${WRITE_HOST}:636" -D "$BIND_DN" -w "$BIND_PW" "$dn" >/dev/null 2>&1 || true
    rm -f "$ldif"
  }
  trap cleanup EXIT

  ldapadd -x -o nettimeout=8 -H "ldaps://${WRITE_HOST}:636" -D "$BIND_DN" -w "$BIND_PW" -f "$ldif" >/dev/null

  found=0
  for _ in $(seq 1 20); do
    if ldapsearch -LLL -x -o nettimeout=8 -H "ldaps://${READ_HOST}:636" -D "$BIND_DN" -w "$BIND_PW" -b "$BASE_DN" "(cn=${cn})" dn | grep -q '^dn:'; then
      found=1
      break
    fi
    sleep 1
  done
  [[ "$found" -eq 1 ]] || fatal "Write/read replication check failed for ${cn}"

  if ldapwhoami -x -o nettimeout=8 -H "ldap://${WRITE_HOST}:389" -D "$BIND_DN" -w "$BIND_PW" >/dev/null 2>&1; then
    fatal "Plain LDAP bind on 389 succeeded unexpectedly (TLS simple-bind enforcement not active)"
  fi

  cleanup
  trap - EXIT
fi

{
  echo "## Result"
  echo
  echo "- Preflight cert/key/chain: PASS"
  if [[ "$RUN_DNS_CHECK" -eq 1 ]]; then
    echo "- DNS checks: PASS"
  else
    echo "- DNS checks: SKIPPED"
  fi
  if [[ "$RUN_APPLY" -eq 1 ]]; then
    echo "- Terraform apply: PASS"
  else
    echo "- Terraform apply: SKIPPED"
  fi
  if [[ "$RUN_TLS_CHECKS" -eq 1 ]]; then
    echo "- TLS handshake and verification: PASS"
  else
    echo "- TLS handshake and verification: SKIPPED"
  fi
  if [[ "$RUN_LDAP_TESTS" -eq 1 ]]; then
    echo "- LDAP auth/search/write/security checks: PASS"
  else
    echo "- LDAP auth/search/write/security checks: SKIPPED"
  fi
} >>"$REPORT_PATH"

log "Completed successfully. Report: $REPORT_PATH"
