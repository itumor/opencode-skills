#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<USAGE
Usage: $0 [--run-id <id>] [--run-dir <dir>] [--phase <all|0|1|2|3|4|5>]

Environment overrides:
  PHASE1_RATE=10
  PHASE1_DURATION_SEC=900
  PHASE2_RATES=25,50,100
  PHASE2_DURATION_SEC=600
  PHASE2_COOLDOWN_SEC=300
  PHASE3_DURATION_SEC=14400
  PHASE4_STEADY_SEC=300
  PHASE4_SWITCH_PAUSE_SEC=45
  PHASE5_DURATION_SEC=600
  PHASE5_RATE=50
  READ_INTERVAL_MS=250
  PROBE_LAG=1
USAGE
}

RUN_ID=""
RUN_DIR=""
PHASE_SEL="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --phase) PHASE_SEL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

need_cmd ldapsearch
need_cmd ldapadd
need_cmd awk
need_cmd perl

load_env_defaults

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_DIR="${RUN_DIR:-${SCRIPT_DIR}/runs/${RUN_ID}}"
ensure_run_dirs "$RUN_DIR"

PHASE1_RATE="${PHASE1_RATE:-10}"
PHASE1_DURATION_SEC="${PHASE1_DURATION_SEC:-900}"
PHASE2_RATES="${PHASE2_RATES:-25,50,100}"
PHASE2_DURATION_SEC="${PHASE2_DURATION_SEC:-600}"
PHASE2_COOLDOWN_SEC="${PHASE2_COOLDOWN_SEC:-300}"
PHASE3_DURATION_SEC="${PHASE3_DURATION_SEC:-14400}"
PHASE4_STEADY_SEC="${PHASE4_STEADY_SEC:-300}"
PHASE4_SWITCH_PAUSE_SEC="${PHASE4_SWITCH_PAUSE_SEC:-45}"
PHASE5_DURATION_SEC="${PHASE5_DURATION_SEC:-600}"
PHASE5_RATE="${PHASE5_RATE:-50}"
READ_INTERVAL_MS="${READ_INTERVAL_MS:-250}"
PROBE_LAG="${PROBE_LAG:-1}"

READ_ENDPOINTS="$(read_endpoints_csv_default)"
[[ -n "$READ_ENDPOINTS" ]] || die "unable to resolve read endpoints"

NEXT_SEQ_FILE="${RUN_DIR}/state/next_seq"
[[ -f "$NEXT_SEQ_FILE" ]] || echo "1" >"$NEXT_SEQ_FILE"

phase_enabled() {
  local p="$1"
  [[ "$PHASE_SEL" == "all" || "$PHASE_SEL" == "$p" ]]
}

alloc_seq_range() {
  local count="$1"
  local start end
  start="$(cat "$NEXT_SEQ_FILE")"
  end=$(( start + count - 1 ))
  echo $(( end + 1 )) >"$NEXT_SEQ_FILE"
  printf '%s %s\n' "$start" "$end"
}

start_phase_readers() {
  local phase="$1" duration_sec="$2"
  local pids_file="${RUN_DIR}/state/readers_${phase}.pids"
  : >"$pids_file"
  IFS=',' read -r -a eps <<<"$READ_ENDPOINTS"
  for item in "${eps[@]}"; do
    label="${item%%=*}"
    host="${item#*=}"
    "${SCRIPT_DIR}/reader.sh" \
      --run-dir "$RUN_DIR" --run-id "$RUN_ID" --phase "$phase" \
      --endpoint-label "$label" --endpoint-host "$host" \
      --duration-sec "$duration_sec" --interval-ms "$READ_INTERVAL_MS" &
    echo "$!" >>"$pids_file"
  done
}

wait_phase_readers() {
  local phase="$1"
  local pids_file="${RUN_DIR}/state/readers_${phase}.pids"
  [[ -f "$pids_file" ]] || return 0
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    wait "$pid" || true
  done <"$pids_file"
}

run_writer_duration() {
  local phase="$1" writer_label="$2" rate="$3" duration_sec="$4"
  local write_count
  write_count="$(awk -v r="$rate" -v d="$duration_sec" 'BEGIN{c=int(r*d); if(c<1)c=1; print c}')"
  read -r seq_start seq_end < <(alloc_seq_range "$write_count")

  log "phase=${phase} writer=${writer_label} host=$(resolve_writer_host "$writer_label") rate=${rate} duration_sec=${duration_sec} seq=${seq_start}-${seq_end}"

  "${SCRIPT_DIR}/writer.sh" \
    --run-dir "$RUN_DIR" --run-id "$RUN_ID" --phase "$phase" \
    --writer "$writer_label" --seq-start "$seq_start" --seq-end "$seq_end" \
    --rate "$rate" --probe-lag "$PROBE_LAG" --read-endpoints "$READ_ENDPOINTS"

  echo "$seq_start $seq_end" >"${RUN_DIR}/state/seq_${phase}.txt"
}

phase_metrics() {
  local phase="$1"
  local out="${RUN_DIR}/reports/phase_metrics_${phase}.txt"

  local wr_total wr_ok wr_rate lag_p95 lag_p99 lag_max lag_file lag_count idx95 idx99 p95v p99v maxv lag_stats
  wr_total="$(awk -F',' -v p="$phase" 'NR>1 && $3==p {n++} END{print n+0}' "${RUN_DIR}/reports/write_samples.csv" 2>/dev/null || echo 0)"
  wr_ok="$(awk -F',' -v p="$phase" 'NR>1 && $3==p && $11==1 {n++} END{print n+0}' "${RUN_DIR}/reports/write_samples.csv" 2>/dev/null || echo 0)"
  wr_rate="$(awk -v ok="$wr_ok" -v t="$wr_total" 'BEGIN{if(t==0){print "0.00"}else{printf("%.2f",100*ok/t)}}')"

  lag_file="${RUN_DIR}/state/lag_${phase}.txt"
  awk -F',' -v p="$phase" 'NR>1 && $3==p && $9 ~ /^[0-9]+$/ {print $9}' "${RUN_DIR}/reports/lag_samples.csv" 2>/dev/null | sort -n >"$lag_file" || true
  lag_count="$(wc -l <"$lag_file" | tr -d ' ')"
  if [[ "$lag_count" -eq 0 ]]; then
    lag_stats="0 0 0"
  else
    idx95="$(awk -v n="$lag_count" 'BEGIN{i=int((n*95+99)/100); if(i<1)i=1; if(i>n)i=n; print i}')"
    idx99="$(awk -v n="$lag_count" 'BEGIN{i=int((n*99+99)/100); if(i<1)i=1; if(i>n)i=n; print i}')"
    p95v="$(sed -n "${idx95}p" "$lag_file")"
    p99v="$(sed -n "${idx99}p" "$lag_file")"
    maxv="$(tail -n 1 "$lag_file")"
    lag_stats="${p95v:-0} ${p99v:-0} ${maxv:-0}"
  fi
  lag_p95="$(echo "$lag_stats" | awk '{print $1}')"
  lag_p99="$(echo "$lag_stats" | awk '{print $2}')"
  lag_max="$(echo "$lag_stats" | awk '{print $3}')"

  {
    echo "phase=${phase}"
    echo "write_total=${wr_total}"
    echo "write_ok=${wr_ok}"
    echo "write_success_rate_pct=${wr_rate}"
    echo "lag_p95_ms=${lag_p95}"
    echo "lag_p99_ms=${lag_p99}"
    echo "lag_max_ms=${lag_max}"
  } >"$out"

  cat "$out"
}

generate_report() {
  local report_md="${RUN_DIR}/reports/SUMMARY.md"
  {
    echo "# OpenLDAP Load Test Report"
    echo
    echo "- run_id: ${RUN_ID}"
    echo "- run_dir: ${RUN_DIR}"
    echo "- generated_utc: $(now_utc)"
    echo "- read_endpoints: ${READ_ENDPOINTS}"
    echo
    echo "## Files"
    echo "- write samples: reports/write_samples.csv"
    echo "- read samples: reports/read_samples.csv"
    echo "- lag samples: reports/lag_samples.csv"
    echo "- lag convergence: reports/lag_convergence.csv"
    echo "- reconciliation: reports/reconcile_summary.csv"
    echo
    echo "## Phase Metrics"
    for f in "${RUN_DIR}"/reports/phase_metrics_*.txt; do
      [[ -f "$f" ]] || continue
      echo "### $(basename "$f" .txt)"
      sed 's/^/- /' "$f"
      echo
    done
  } >"$report_md"

  log "report generated: ${report_md}"
}

phase0() {
  log "Phase 0: environment and baseline validation"
  endpoints="write_live=${WRITE_LB_LIVE},write_dr=${WRITE_LB_DR},write_ga=${GA_WRITE_DNS},read_live=${READ_LB_LIVE},read_dr=${READ_LB_DR},read_ga=${GA_READ_DNS}"
  echo "$endpoints" >"${RUN_DIR}/state/endpoints.txt"

  IFS=',' read -r -a items <<<"$endpoints"
  for item in "${items[@]}"; do
    label="${item%%=*}"
    host="${item#*=}"
    [[ -n "$host" ]] || continue
    set +e
    ldapwhoami -x -o nettimeout=5 -H "ldap://${host}:${LDAP_PORT}" -D "${ADMIN_DN}" -w "${ADMIN_PW}" >"${RUN_DIR}/logs/whoami_${label}.out" 2>"${RUN_DIR}/logs/whoami_${label}.err"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      warn "phase0 whoami failed for ${label} ${host} rc=${rc}"
    fi
  done
}

phase1() {
  log "Phase 1: low-rate functional correctness"
  total_reader_sec=$(( PHASE1_DURATION_SEC * 2 + 30 ))
  start_phase_readers "phase1" "$total_reader_sec"

  "${SCRIPT_DIR}/switch_writer.sh" --run-dir "$RUN_DIR" --writer live
  run_writer_duration "phase1_live" "live" "$PHASE1_RATE" "$PHASE1_DURATION_SEC"
  "${SCRIPT_DIR}/reconcile.sh" --run-dir "$RUN_DIR" --run-id "$RUN_ID" --seq-start "$(awk '{print $1}' "${RUN_DIR}/state/seq_phase1_live.txt")" --seq-end "$(awk '{print $2}' "${RUN_DIR}/state/seq_phase1_live.txt")" --read-endpoints "$READ_ENDPOINTS"

  "${SCRIPT_DIR}/switch_writer.sh" --run-dir "$RUN_DIR" --writer dr --pause-sec 30
  run_writer_duration "phase1_dr" "dr" "$PHASE1_RATE" "$PHASE1_DURATION_SEC"
  "${SCRIPT_DIR}/reconcile.sh" --run-dir "$RUN_DIR" --run-id "$RUN_ID" --seq-start "$(awk '{print $1}' "${RUN_DIR}/state/seq_phase1_dr.txt")" --seq-end "$(awk '{print $2}' "${RUN_DIR}/state/seq_phase1_dr.txt")" --read-endpoints "$READ_ENDPOINTS"

  wait_phase_readers "phase1"
  phase_metrics "phase1_live"
  phase_metrics "phase1_dr"
}

phase2() {
  log "Phase 2: throughput ramp"
  IFS=',' read -r -a rates <<<"$PHASE2_RATES"
  total_steps="${#rates[@]}"
  total_reader_sec=$(( total_steps * (PHASE2_DURATION_SEC + PHASE2_COOLDOWN_SEC) * 2 ))
  start_phase_readers "phase2" "$total_reader_sec"

  local max_sustainable=0

  for writer in live dr; do
    "${SCRIPT_DIR}/switch_writer.sh" --run-dir "$RUN_DIR" --writer "$writer"
    for rate in "${rates[@]}"; do
      phase="phase2_${writer}_r${rate}"
      run_writer_duration "$phase" "$writer" "$rate" "$PHASE2_DURATION_SEC"
      phase_metrics "$phase" >"${RUN_DIR}/reports/${phase}.metrics"

      success_rate="$(awk -F'=' '/write_success_rate_pct/{print $2}' "${RUN_DIR}/reports/${phase}.metrics")"
      p95="$(awk -F'=' '/lag_p95_ms/{print $2}' "${RUN_DIR}/reports/${phase}.metrics")"
      if awk -v s="$success_rate" -v p="$p95" 'BEGIN{exit !(s>=99.5 && p<=2000)}'; then
        [[ "$rate" -gt "$max_sustainable" ]] && max_sustainable="$rate"
      fi

      log "phase2 cooldown ${PHASE2_COOLDOWN_SEC}s after ${phase}"
      sleep "$PHASE2_COOLDOWN_SEC"
    done
  done

  echo "$max_sustainable" >"${RUN_DIR}/state/max_sustainable_rate"
  wait_phase_readers "phase2"
  log "phase2 max sustainable rate=${max_sustainable} wps"
}

phase3() {
  log "Phase 3: soak"
  max_rate="$(cat "${RUN_DIR}/state/max_sustainable_rate" 2>/dev/null || echo 50)"
  soak_rate="$(awk -v m="$max_rate" 'BEGIN{r=int(m*0.65); if(r<1)r=1; print r}')"
  echo "$soak_rate" >"${RUN_DIR}/state/soak_rate"

  start_phase_readers "phase3" "$PHASE3_DURATION_SEC"
  "${SCRIPT_DIR}/switch_writer.sh" --run-dir "$RUN_DIR" --writer live
  run_writer_duration "phase3_soak" "live" "$soak_rate" "$PHASE3_DURATION_SEC"

  read -r s e <"${RUN_DIR}/state/seq_phase3_soak.txt"
  "${SCRIPT_DIR}/reconcile.sh" --run-dir "$RUN_DIR" --run-id "$RUN_ID" --seq-start "$s" --seq-end "$e" --read-endpoints "$READ_ENDPOINTS"

  wait_phase_readers "phase3"
  phase_metrics "phase3_soak"
}

phase4() {
  log "Phase 4: writer switch and failure behavior"
  start_phase_readers "phase4" "$(( PHASE4_STEADY_SEC * 4 ))"

  "${SCRIPT_DIR}/switch_writer.sh" --run-dir "$RUN_DIR" --writer live
  run_writer_duration "phase4_switch_pre" "live" "$PHASE1_RATE" "$PHASE4_STEADY_SEC"

  "${SCRIPT_DIR}/switch_writer.sh" --run-dir "$RUN_DIR" --writer dr --pause-sec "$PHASE4_SWITCH_PAUSE_SEC"
  run_writer_duration "phase4_switch_post" "dr" "$PHASE1_RATE" "$PHASE4_STEADY_SEC"

  if [[ -n "${PHASE4_FAILURE_CMD:-}" ]]; then
    log "running failure injection command"
    bash -lc "$PHASE4_FAILURE_CMD" || true
  else
    warn "PHASE4_FAILURE_CMD not set; unplanned failure simulation skipped"
  fi

  "${SCRIPT_DIR}/switch_writer.sh" --run-dir "$RUN_DIR" --writer live
  run_writer_duration "phase4_recovery" "live" "$PHASE1_RATE" "$PHASE4_STEADY_SEC"

  read -r a b <"${RUN_DIR}/state/seq_phase4_switch_pre.txt"
  read -r c d <"${RUN_DIR}/state/seq_phase4_recovery.txt"
  "${SCRIPT_DIR}/reconcile.sh" --run-dir "$RUN_DIR" --run-id "$RUN_ID" --seq-start "$a" --seq-end "$d" --read-endpoints "$READ_ENDPOINTS"

  wait_phase_readers "phase4"
  phase_metrics "phase4_switch_pre"
  phase_metrics "phase4_switch_post"
  phase_metrics "phase4_recovery"
}

phase5() {
  log "Phase 5: GA vs direct NLB comparison"
  start_phase_readers "phase5" "$(( PHASE5_DURATION_SEC * 2 + 30 ))"

  "${SCRIPT_DIR}/switch_writer.sh" --run-dir "$RUN_DIR" --writer ga
  run_writer_duration "phase5_ga" "ga" "$PHASE5_RATE" "$PHASE5_DURATION_SEC"

  "${SCRIPT_DIR}/switch_writer.sh" --run-dir "$RUN_DIR" --writer live --pause-sec 15
  run_writer_duration "phase5_direct" "live" "$PHASE5_RATE" "$PHASE5_DURATION_SEC"

  wait_phase_readers "phase5"
  phase_metrics "phase5_ga"
  phase_metrics "phase5_direct"
}

log "run_id=${RUN_ID} run_dir=${RUN_DIR}"
phase_enabled 0 && phase0
phase_enabled 1 && phase1
phase_enabled 2 && phase2
phase_enabled 3 && phase3
phase_enabled 4 && phase4
phase_enabled 5 && phase5

generate_report
log "load plan run complete"
