#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<USAGE
Usage: $0 --run-dir <dir> --run-id <id> --phase <name> --endpoint-label <label> --endpoint-host <host> [--duration-sec N] [--interval-ms N]
USAGE
}

RUN_DIR=""
RUN_ID=""
PHASE=""
ENDPOINT_LABEL=""
ENDPOINT_HOST=""
DURATION_SEC=600
INTERVAL_MS=250

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --endpoint-label) ENDPOINT_LABEL="$2"; shift 2 ;;
    --endpoint-host) ENDPOINT_HOST="$2"; shift 2 ;;
    --duration-sec) DURATION_SEC="$2"; shift 2 ;;
    --interval-ms) INTERVAL_MS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$RUN_DIR" && -n "$RUN_ID" && -n "$PHASE" && -n "$ENDPOINT_LABEL" && -n "$ENDPOINT_HOST" ]] || { usage; die "required args missing"; }

load_env_defaults
ensure_run_dirs "$RUN_DIR"

out_csv="${RUN_DIR}/reports/read_samples.csv"
if [[ ! -f "$out_csv" ]]; then
  echo "ts_utc,run_id,phase,endpoint_label,endpoint_host,latency_ms,success,ldap_rc" >"$out_csv"
fi

interval_s="$(awk -v ms="$INTERVAL_MS" 'BEGIN{ if (ms < 1) ms=1; printf("%.6f", ms/1000) }')"
deadline=$(( $(date +%s) + DURATION_SEC ))

while [[ $(date +%s) -lt $deadline ]]; do
  start_ms="$(ms_now)"

  set +e
  ldapsearch -LLL -x -o nettimeout=5 -H "ldap://${ENDPOINT_HOST}:${LDAP_PORT}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" -b "${BASE_DN}" -s base dn >"${RUN_DIR}/logs/read_${ENDPOINT_LABEL}.out" 2>"${RUN_DIR}/logs/read_${ENDPOINT_LABEL}.err"
  rc=$?
  set -e

  end_ms="$(ms_now)"
  latency_ms=$(( end_ms - start_ms ))
  success=0
  [[ "$rc" -eq 0 ]] && success=1

  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$(now_utc)" "$RUN_ID" "$PHASE" "$ENDPOINT_LABEL" "$ENDPOINT_HOST" "$latency_ms" "$success" "$rc" >>"$out_csv"
  sleep "$interval_s"
done
