#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<USAGE
Usage: $0 --run-dir <dir> --run-id <id> --seq-start N --seq-end N [--read-endpoints "label=host,label=host"] [--settle-sec N]
USAGE
}

RUN_DIR=""
RUN_ID=""
SEQ_START=""
SEQ_END=""
READ_ENDPOINTS=""
SETTLE_SEC=15

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --seq-start) SEQ_START="$2"; shift 2 ;;
    --seq-end) SEQ_END="$2"; shift 2 ;;
    --read-endpoints) READ_ENDPOINTS="$2"; shift 2 ;;
    --settle-sec) SETTLE_SEC="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$RUN_DIR" && -n "$RUN_ID" && -n "$SEQ_START" && -n "$SEQ_END" ]] || { usage; die "required args missing"; }

load_env_defaults
ensure_run_dirs "$RUN_DIR"

[[ -n "$READ_ENDPOINTS" ]] || READ_ENDPOINTS="$(read_endpoints_csv_default)"
[[ -n "$READ_ENDPOINTS" ]] || die "no read endpoints resolved"

log "settle window ${SETTLE_SEC}s before reconciliation"
sleep "$SETTLE_SEC"

expected_file="${RUN_DIR}/state/expected_uids.txt"
for (( seq=SEQ_START; seq<=SEQ_END; seq++ )); do
  echo "lt-${RUN_ID}-${seq}"
done | sort >"$expected_file"

IFS=',' read -r -a ep_items <<<"$READ_ENDPOINTS"
seen_all="${RUN_DIR}/state/reconcile_seen_all.txt"
: >"$seen_all"

stale_count=0
summary_csv="${RUN_DIR}/reports/reconcile_summary.csv"
if [[ ! -f "$summary_csv" ]]; then
  echo "ts_utc,run_id,endpoint_label,endpoint_host,expected_count,found_count,missing_count,duplicate_count,stale_reads_count" >"$summary_csv"
fi

for item in "${ep_items[@]}"; do
  label="${item%%=*}"
  host="${item#*=}"

  found_raw="${RUN_DIR}/state/found_${label}.raw"
  found_uids="${RUN_DIR}/state/found_${label}.uids"

  set +e
  ldapsearch -LLL -x -o nettimeout=5 -H "ldap://${host}:${LDAP_PORT}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" -b "ou=people,${BASE_DN}" "(uid=lt-${RUN_ID}-*)" uid >"$found_raw" 2>"${RUN_DIR}/logs/reconcile_${label}.err"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    warn "reconcile ldapsearch failed on ${label} (${host}) rc=${rc}"
    : >"$found_uids"
  else
    awk '/^uid: /{print $2}' "$found_raw" | sort >"$found_uids"
  fi

  cat "$found_uids" >>"$seen_all"

  missing_file="${RUN_DIR}/reports/reconcile_missing_${label}.txt"
  dup_file="${RUN_DIR}/reports/reconcile_duplicates_${label}.txt"

  comm -23 "$expected_file" "$found_uids" >"$missing_file"
  sort "$found_uids" | uniq -d >"$dup_file"

  expected_count="$(wc -l <"$expected_file" | tr -d ' ')"
  found_count="$(wc -l <"$found_uids" | tr -d ' ')"
  missing_count="$(wc -l <"$missing_file" | tr -d ' ')"
  duplicate_count="$(wc -l <"$dup_file" | tr -d ' ')"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(now_utc)" "$RUN_ID" "$label" "$host" "$expected_count" "$found_count" "$missing_count" "$duplicate_count" "0" >>"$summary_csv"
done

uniq_seen="${RUN_DIR}/state/reconcile_seen_unique.txt"
sort "$seen_all" | uniq >"$uniq_seen"

for uid in $(cat "$uniq_seen"); do
  present=0
  total=0
  for item in "${ep_items[@]}"; do
    label="${item%%=*}"
    total=$(( total + 1 ))
    if grep -qx "$uid" "${RUN_DIR}/state/found_${label}.uids"; then
      present=$(( present + 1 ))
    fi
  done
  if [[ "$present" -gt 0 && "$present" -lt "$total" ]]; then
    stale_count=$(( stale_count + 1 ))
  fi
done

stale_file="${RUN_DIR}/reports/reconcile_stale_count.txt"
printf '%s\n' "$stale_count" >"$stale_file"
run_summary="${RUN_DIR}/reports/reconcile_run_summary.csv"
if [[ ! -f "$run_summary" ]]; then
  echo "ts_utc,run_id,seq_start,seq_end,stale_reads_count" >"$run_summary"
fi
printf '%s,%s,%s,%s,%s\n' "$(now_utc)" "$RUN_ID" "$SEQ_START" "$SEQ_END" "$stale_count" >>"$run_summary"

log "reconcile complete: stale_reads_count=${stale_count}"
