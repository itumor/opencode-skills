#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<USAGE
Usage: $0 --run-dir <dir> --run-id <id> --uid <uid> --ack-ms <epoch_ms> [--phase <name>] [--read-endpoints "label=host,label=host"] [--timeout-sec 60]
USAGE
}

RUN_DIR=""
RUN_ID=""
UID_VAL=""
ACK_MS=""
PHASE="unknown"
READ_ENDPOINTS=""
TIMEOUT_SEC=60

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --uid) UID_VAL="$2"; shift 2 ;;
    --ack-ms) ACK_MS="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --read-endpoints) READ_ENDPOINTS="$2"; shift 2 ;;
    --timeout-sec) TIMEOUT_SEC="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$RUN_DIR" && -n "$RUN_ID" && -n "$UID_VAL" && -n "$ACK_MS" ]] || { usage; die "required args missing"; }

load_env_defaults
ensure_run_dirs "$RUN_DIR"

[[ -n "$READ_ENDPOINTS" ]] || READ_ENDPOINTS="$(read_endpoints_csv_default)"
[[ -n "$READ_ENDPOINTS" ]] || die "no read endpoints resolved"

out_csv="${RUN_DIR}/reports/lag_samples.csv"
if [[ ! -f "$out_csv" ]]; then
  echo "ts_utc,run_id,phase,uid,endpoint_label,endpoint_host,ack_ms,first_visible_ms,lag_ms,probe_status" >"$out_csv"
fi

tmp_file="${RUN_DIR}/state/lag_${UID_VAL}.tmp"
: >"$tmp_file"

deadline=$(( $(date +%s) + TIMEOUT_SEC ))
IFS=',' read -r -a ep_items <<<"$READ_ENDPOINTS"

remaining="${#ep_items[@]}"
while [[ "$remaining" -gt 0 && $(date +%s) -le $deadline ]]; do
  remaining=0
  for item in "${ep_items[@]}"; do
    label="${item%%=*}"
    host="${item#*=}"
    if grep -q "^${label}," "$tmp_file"; then
      continue
    fi

    set +e
    ldapsearch -LLL -x -o nettimeout=5 -H "ldap://${host}:${LDAP_PORT}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" -b "${BASE_DN}" "(uid=${UID_VAL})" dn >/tmp/lag_probe_${UID_VAL}_${label}.out 2>/tmp/lag_probe_${UID_VAL}_${label}.err
    rc=$?
    set -e

    if [[ "$rc" -eq 0 ]] && grep -q '^dn:' /tmp/lag_probe_${UID_VAL}_${label}.out; then
      vis_ms="$(ms_now)"
      lag_ms=$(( vis_ms - ACK_MS ))
      echo "${label},${host},${vis_ms},${lag_ms}" >>"$tmp_file"
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(now_utc)" "$RUN_ID" "$PHASE" "$UID_VAL" "$label" "$host" "$ACK_MS" "$vis_ms" "$lag_ms" "ok" >>"$out_csv"
    else
      remaining=$(( remaining + 1 ))
    fi
  done

  [[ "$remaining" -eq 0 ]] && break
  sleep 1
done

if [[ "$remaining" -gt 0 ]]; then
  for item in "${ep_items[@]}"; do
    label="${item%%=*}"
    host="${item#*=}"
    if ! grep -q "^${label}," "$tmp_file"; then
      printf '%s,%s,%s,%s,%s,%s,%s,,,%s\n' "$(now_utc)" "$RUN_ID" "$PHASE" "$UID_VAL" "$label" "$host" "$ACK_MS" "timeout" >>"$out_csv"
    fi
  done
fi

if [[ -s "$tmp_file" ]]; then
  max_lag="$(awk -F',' 'BEGIN{m=0} {if($4>m)m=$4} END{print m+0}' "$tmp_file")"
  summary_csv="${RUN_DIR}/reports/lag_convergence.csv"
  if [[ ! -f "$summary_csv" ]]; then
    echo "ts_utc,run_id,phase,uid,ack_ms,convergence_lag_ms,probe_status" >"$summary_csv"
  fi
  status="ok"
  [[ "$remaining" -gt 0 ]] && status="partial"
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$(now_utc)" "$RUN_ID" "$PHASE" "$UID_VAL" "$ACK_MS" "$max_lag" "$status" >>"$summary_csv"
fi

[[ "$remaining" -eq 0 ]]
