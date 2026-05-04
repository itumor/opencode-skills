#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/openldap"

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[%s] %s\n' "$(now_utc)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(now_utc)" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$(now_utc)" "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

ms_now() {
  perl -MTime::HiRes=time -e 'printf("%.0f\n", time()*1000)'
}

extract_tfvar() {
  local key="$1" tfvars="${TF_DIR}/terraform.tfvars"
  [[ -f "$tfvars" ]] || return 1
  awk -v k="$key" '
    $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "", $0)
      gsub(/^[[:space:]]*\"/, "", $0)
      gsub(/\"[[:space:]]*$/, "", $0)
      print $0
      exit
    }
  ' "$tfvars"
}

_tf_json_path() {
  local out_json="${TF_DIR}/reports/logs/terraform_openldap_outputs_$(date -u +%Y-%m-%d).json"
  if [[ -f "$out_json" ]]; then
    echo "$out_json"
    return 0
  fi
  out_json="$(ls -1t "${TF_DIR}"/reports/logs/terraform_openldap_outputs_*.json 2>/dev/null | head -n 1 || true)"
  if [[ -n "$out_json" && -f "$out_json" ]]; then
    echo "$out_json"
    return 0
  fi
  return 1
}

_get_from_out_text() {
  local key="$1" subkey="${2:-}" out_text="${TF_DIR}/out.text"
  [[ -f "$out_text" ]] || return 1

  if [[ -n "$subkey" ]]; then
    awk -v k="$key" -v s="$subkey" '
      $0 ~ "^"k"[[:space:]]*= *\\{" {inblk=1; next}
      inblk==1 && $0 ~ /^}/ {inblk=0}
      inblk==1 && $0 ~ "\""s"\"" {
        gsub(/.*= *\"/, "", $0)
        gsub(/\".*/, "", $0)
        print
        exit
      }
    ' "$out_text"
  else
    awk -v k="$key" '
      $0 ~ "^"k"[[:space:]]*= *\"" {
        gsub(/^[^\"]*\"/, "", $0)
        gsub(/\".*/, "", $0)
        print
        exit
      }
    ' "$out_text"
  fi
}

get_output_value() {
  local key="$1" subkey="${2:-}"

  # Prefer checked-in/out.text values for test runs, then fallback to live terraform outputs.
  if [[ -n "$subkey" ]]; then
    local v
    v="$(_get_from_out_text "$key" "$subkey" || true)"
    if [[ -n "$v" ]]; then
      echo "$v"
      return 0
    fi
  else
    local v
    v="$(_get_from_out_text "$key" || true)"
    if [[ -n "$v" ]]; then
      echo "$v"
      return 0
    fi
  fi

  if command -v terraform >/dev/null 2>&1; then
    if [[ -n "$subkey" ]]; then
      if command -v jq >/dev/null 2>&1; then
        terraform -chdir="$TF_DIR" output -json "$key" 2>/dev/null | jq -r --arg sk "$subkey" '.value[$sk] // empty' 2>/dev/null && return 0
      fi
    else
      terraform -chdir="$TF_DIR" output -raw "$key" 2>/dev/null && return 0
    fi
  fi

  if command -v jq >/dev/null 2>&1; then
    local out_json
    out_json="$(_tf_json_path || true)"
    if [[ -n "$out_json" ]]; then
      if [[ -n "$subkey" ]]; then
        jq -r --arg k "$key" --arg sk "$subkey" '.[$k].value[$sk] // empty' "$out_json" 2>/dev/null && return 0
      else
        jq -r --arg k "$key" '.[$k].value // empty' "$out_json" 2>/dev/null && return 0
      fi
    fi
  fi

  _get_from_out_text "$key" "$subkey"
}

load_env_defaults() {
  BASE_DN="${BASE_DN:-$(extract_tfvar base_dn || true)}"
  [[ -n "${BASE_DN:-}" ]] || BASE_DN="dc=cae,dc=local"

  ADMIN_DN="${ADMIN_DN:-cn=admin,${BASE_DN}}"
  ADMIN_PW="${ADMIN_PW:-$(extract_tfvar admin_password || true)}"
  [[ -n "${ADMIN_PW:-}" ]] || ADMIN_PW="admin"

  LDAP_PORT="${LDAP_PORT:-389}"

  GA_WRITE_DNS="${GA_WRITE_DNS:-$(get_output_value ga_write_dns || true)}"
  GA_READ_DNS="${GA_READ_DNS:-$(get_output_value ga_read_dns || true)}"
  WRITE_LB_LIVE="${WRITE_LB_LIVE:-$(get_output_value write_lb_dns live || true)}"
  WRITE_LB_DR="${WRITE_LB_DR:-$(get_output_value write_lb_dns dr || true)}"
  READ_LB_LIVE="${READ_LB_LIVE:-$(get_output_value read_lb_dns live || true)}"
  READ_LB_DR="${READ_LB_DR:-$(get_output_value read_lb_dns dr || true)}"

  export BASE_DN ADMIN_DN ADMIN_PW LDAP_PORT
  export GA_WRITE_DNS GA_READ_DNS WRITE_LB_LIVE WRITE_LB_DR READ_LB_LIVE READ_LB_DR
}

ldap_cmd() {
  local op="$1"
  shift
  local host="$1"
  shift
  "${op}" -x -o nettimeout=5 -H "ldap://${host}:${LDAP_PORT}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" "$@"
}

resolve_writer_host() {
  case "$1" in
    live) echo "$WRITE_LB_LIVE" ;;
    dr) echo "$WRITE_LB_DR" ;;
    ga) echo "$GA_WRITE_DNS" ;;
    *) echo "$1" ;;
  esac
}

read_endpoints_csv_default() {
  local parts=""
  [[ -n "${GA_READ_DNS:-}" ]] && parts="${parts},ga=${GA_READ_DNS}"
  [[ -n "${READ_LB_LIVE:-}" ]] && parts="${parts},live=${READ_LB_LIVE}"
  [[ -n "${READ_LB_DR:-}" ]] && parts="${parts},dr=${READ_LB_DR}"
  echo "${parts#,}"
}

ensure_run_dirs() {
  local run_dir="$1"
  mkdir -p "$run_dir" "$run_dir/logs" "$run_dir/state" "$run_dir/reports"
}
