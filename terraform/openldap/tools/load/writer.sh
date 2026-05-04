#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<USAGE
Usage: $0 --run-dir <dir> --run-id <id> --phase <name> --writer <live|dr|ga|host> --seq-start N --seq-end N [--rate WPS] [--probe-lag 1] [--read-endpoints "label=host,label=host"]
USAGE
}

RUN_DIR=""
RUN_ID=""
PHASE=""
WRITER=""
SEQ_START=""
SEQ_END=""
RATE=10
PROBE_LAG=0
READ_ENDPOINTS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --writer) WRITER="$2"; shift 2 ;;
    --seq-start) SEQ_START="$2"; shift 2 ;;
    --seq-end) SEQ_END="$2"; shift 2 ;;
    --rate) RATE="$2"; shift 2 ;;
    --probe-lag) PROBE_LAG="$2"; shift 2 ;;
    --read-endpoints) READ_ENDPOINTS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$RUN_DIR" && -n "$RUN_ID" && -n "$PHASE" && -n "$WRITER" && -n "$SEQ_START" && -n "$SEQ_END" ]] || { usage; die "required args missing"; }

load_env_defaults
ensure_run_dirs "$RUN_DIR"

[[ -n "$READ_ENDPOINTS" ]] || READ_ENDPOINTS="$(read_endpoints_csv_default)"
writer_host="$(resolve_writer_host "$WRITER")"
[[ -n "$writer_host" ]] || die "writer host resolved empty"

if [[ -f "${RUN_DIR}/state/active_writer" ]]; then
  active_writer="$(cat "${RUN_DIR}/state/active_writer")"
  if [[ "$active_writer" != "$WRITER" ]]; then
    die "single-writer gate violation: active_writer=${active_writer}, requested=${WRITER}"
  fi
fi

out_csv="${RUN_DIR}/reports/write_samples.csv"
if [[ ! -f "$out_csv" ]]; then
  echo "ts_utc,run_id,phase,seq,uid,writer_label,writer_host,write_ts_ms,ack_ts_ms,write_latency_ms,success,ldap_rc,ldap_error_code,dn" >"$out_csv"
fi

sleep_s="$(awk -v r="$RATE" 'BEGIN{ if (r <= 0) r=1; printf("%.6f", 1/r) }')"

for (( seq=SEQ_START; seq<=SEQ_END; seq++ )); do
  uid="lt-${RUN_ID}-${seq}"
  dn="uid=${uid},ou=people,${BASE_DN}"
  write_ts_ms="$(ms_now)"
  ts_utc="$(now_utc)"

  ldif_path="${RUN_DIR}/state/${uid}.ldif"
  cat >"$ldif_path" <<LDIF
dn: ${dn}
objectClass: inetOrgPerson
uid: ${uid}
cn: lt-${seq}
sn: lt-${seq}
description: writer=${WRITER};host=${writer_host};ts=${write_ts_ms}
employeeNumber: ${seq}
LDIF

  set +e
  ldapadd -x -o nettimeout=5 -H "ldap://${writer_host}:${LDAP_PORT}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" -f "$ldif_path" >"${RUN_DIR}/logs/${uid}.add.out" 2>"${RUN_DIR}/logs/${uid}.add.err"
  rc=$?
  set -e

  ack_ts_ms="$(ms_now)"
  latency_ms=$(( ack_ts_ms - write_ts_ms ))
  success=0
  err_code=""

  if [[ "$rc" -eq 0 ]]; then
    success=1
  else
    err_code="$(sed -n 's/.*(\([0-9][0-9]*\)).*/\1/p' "${RUN_DIR}/logs/${uid}.add.err" | head -n 1)"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts_utc" "$RUN_ID" "$PHASE" "$seq" "$uid" "$WRITER" "$writer_host" "$write_ts_ms" "$ack_ts_ms" "$latency_ms" "$success" "$rc" "$err_code" "$dn" >>"$out_csv"

  if [[ "$success" -eq 1 && "$PROBE_LAG" -eq 1 ]]; then
    "${SCRIPT_DIR}/lag_probe.sh" --run-dir "$RUN_DIR" --run-id "$RUN_ID" --uid "$uid" --ack-ms "$ack_ts_ms" --phase "$PHASE" --read-endpoints "$READ_ENDPOINTS" || true
  fi

  sleep "$sleep_s"
done
