#!/usr/bin/env bash
# bank-perf-suite.sh — All-in-one bank OpenLDAP performance test suite
#
# Runs locally on the load-generator host (jump, master, or replica).
# Tests: smoke, login load, write load, mixed load, stress ramp.
#
# Prerequisites: bank-bulk-load.sh already run to populate test users.
#
# Usage:
#   bash bank-perf-suite.sh                          # Run all phases on local LDAP
#   bash bank-perf-suite.sh --master 172.23.11.236    # Target specific master
#   bash bank-perf-suite.sh --replica 172.23.11.237   # Target specific replica
#   bash bank-perf-suite.sh --skip-smoke               # Skip smoke test
#   bash bank-perf-suite.sh --quick                    # Quick 2-min test (smoke only)
#
# Environment variables:
#   BANK_MASTER    Master IP (default: 172.23.11.236)
#   BANK_REPLICA   Replica IP (default: 172.23.11.237)
#   BANK_ADMIN_PW  Admin password (default: TheN1le1)
#   BANK_BASE_DN   Base DN (default: dc=eab,dc=bank,dc=local)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MASTER="${BANK_MASTER:-172.23.11.236}"
REPLICA="${BANK_REPLICA:-172.23.11.237}"
ADMIN_PW="${BANK_ADMIN_PW:-TheN1le1}"
ADMIN_DN="cn=admin,dc=eab,dc=bank,dc=local"
BASE_DN="dc=eab,dc=bank,dc=local"

RESULTS_DIR="${SCRIPT_DIR}/results/$(date +%Y%m%d_%H%M%S)"
SKIP_SMOKE=0
QUICK=0
TEST_HOST="${REPLICA}"    # default: test against replica for read load
WRITE_HOST="${MASTER}"    # write tests go to master

export PATH="/opt/symas/bin:/opt/symas/sbin:${PATH:-/usr/bin}"
export LDAPTLS_REQCERT=never

log()  { echo "[$(date +%H:%M:%S)] $*"; }
err()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }

for arg in "$@"; do
    case "$arg" in
        --master) TEST_HOST="$2"; WRITE_HOST="$2"; shift ;;
        --replica) TEST_HOST="$2"; shift ;;
        --skip-smoke) SKIP_SMOKE=1 ;;
        --quick) QUICK=1 ;;
    esac
    shift 2>/dev/null || true
done

mkdir -p "$RESULTS_DIR"

# ============================================================
# Smoke test
# ============================================================
run_smoke() {
    log "=== PHASE 0: Smoke Test ==="
    local ok=true

    for host in "$MASTER" "$REPLICA"; do
        if ldapwhoami -x -H ldaps://${host}:636 \
            -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1; then
            log "  [OK] Bind to ${host}"
        else
            log "  [FAIL] Cannot bind to ${host}"
            ok=false
        fi
    done

    if $ok; then
        log "Smoke test PASSED"
    else
        err "Smoke test FAILED — check connectivity, credentials, and LDAP service"
        return 1
    fi
}

# ============================================================
# Run a single load test
# ============================================================
run_test() {
    local label="$1"; local host="$2"; local mode="$3"
    local ops="$4"; local duration="$5"; local concurrency="$6"
    local output="${RESULTS_DIR}/${label}.json"

    log "=== ${label} ==="
    log "  Host: ${host}, Mode: ${mode}, Target: ${ops} ops/sec, ${duration}s, ${concurrency} threads"

    python3 "${SCRIPT_DIR}/bank-load-tester.py" \
        --host "${host}" --port 636 \
        --mode "${mode}" --target-ops "${ops}" \
        --duration "${duration}" --concurrency "${concurrency}" \
        --admin-dn "${ADMIN_DN}" --admin-pw "${ADMIN_PW}" \
        --base-dn "${BASE_DN}" \
        --json 2>/dev/null | tee "${output}"

    # Quick summary from JSON
    if [[ -f "${output}" ]]; then
        python3 -c "
import json
with open('${output}') as f:
    d = json.load(f)
    print(f\"  Result: {d.get('ops_per_sec',0)} ops/sec, {d.get('error_rate',0)}% errors, p50={d.get('latency_p50',{}).get('search',0)}ms\")
" 2>/dev/null || true
    fi
}

# ============================================================
# Main
# ============================================================
log "=== Bank OpenLDAP Performance Test Suite ==="
log "Master: ${MASTER}, Replica: ${REPLICA}"
log "Results: ${RESULTS_DIR}"
log ""

if [[ "$SKIP_SMOKE" -ne 1 ]]; then
    run_smoke || exit 1
fi

if [[ "$QUICK" -eq 1 ]]; then
    log "Quick mode — smoke only, done."
    exit 0
fi

# Phase 1: Login load (reads on replica)
run_test "01-login-100ops"   "$TEST_HOST"  "login"  "100"  "120" "50"
run_test "02-login-500ops"   "$TEST_HOST"  "login"  "500"  "120" "100"

# Phase 2: Write load (adds on master)
run_test "03-write-25ops"    "$WRITE_HOST" "write"  "25"   "120" "10"

# Phase 3: Mixed load (reads + writes)
run_test "04-mixed-200ops"   "$TEST_HOST"  "mixed"  "200"  "120" "50"

# Phase 4: Stress ramp (only if explicitly requested via --full)
if [[ "${RUN_FULL:-0}" -eq 1 ]]; then
    log "=== Full stress test (40 min ramp) ==="
    run_test "05-stress-ramp" "$TEST_HOST" "stress" "2000" "2400" "100"
fi

# ============================================================
# Summary
# ============================================================
log ""
log "=== Test Suite Complete ==="
log "Results: ${RESULTS_DIR}"

# Generate quick summary
{
    echo "Bank OpenLDAP Performance Test Summary"
    echo "======================================"
    echo "Date: $(date)"
    echo "Master: ${MASTER}, Replica: ${REPLICA}"
    echo ""
    for f in "$RESULTS_DIR"/*.json; do
        if [[ -f "$f" ]]; then
            echo "--- $(basename "$f") ---"
            python3 -c "
import json
with open('$f') as fh:
    d = json.load(fh)
    print(f\"  Ops/sec:  {d.get('ops_per_sec', 'N/A')}\")
    print(f\"  Errors:   {d.get('errors', 'N/A')}\")
    print(f\"  Error%:   {d.get('error_rate', 'N/A')}%\")
    s = d.get('latency_p50', {}).get('search')
    if s: print(f'  p50:      {s}ms')
    s = d.get('latency_p95', {}).get('search')
    if s: print(f'  p95:      {s}ms')
    s = d.get('latency_p99', {}).get('search')
    if s: print(f'  p99:      {s}ms')
" 2>/dev/null || true
        fi
    done
} | tee "${RESULTS_DIR}/summary.txt"

log "Summary saved to ${RESULTS_DIR}/summary.txt"
