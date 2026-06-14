#!/usr/bin/env bash
# run-perf-suite.sh — Full performance test suite orchestrator
# Runs all phases (smoke → stress) and produces a report
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ips.env" 2>/dev/null || true

MASTER="${PERF_MASTER_PRIV:-10.40.1.10}"
REPLICA="${PERF_REPLICA_PRIV:-10.40.2.10}"
LG1="${PERF_LG1_PUB:-44.247.77.105}"
LG2="${PERF_LG2_PUB:-35.94.20.201}"
SSH_KEY="${SSH_KEY:-/Users/eramadan/openscript/nextgenopen/terraform/openldap-perf-test/.local-ssh/openldap_master_replica}"

ADMIN_DN="cn=admin,dc=eab,dc=bank,dc=local"
ADMIN_PW="TheN1le1"
BASE_DN="dc=eab,dc=bank,dc=local"

SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $SSH_KEY"
SCP="scp -o StrictHostKeyChecking=no -i $SSH_KEY"
RESULTS_DIR="${SCRIPT_DIR}/results/$(date +%Y%m%d_%H%M%S)"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
err()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }

mkdir -p "$RESULTS_DIR"

deploy_scripts_to_loadgen() {
    log "Deploying test scripts to load generators..."
    for lg in "$LG1" "$LG2"; do
        $SCP "${SCRIPT_DIR}/ldap-load-tester.py" "ec2-user@${lg}:/tmp/"
        $SSH ec2-user@"$lg" "sudo dnf -y install python3 2>&1 | tail -1 || true"
    done
}

run_smoke_test() {
    log "=== PHASE 0: Smoke Test ==="
    log "Verifying connectivity..."
    local ok=true

    for host in "$MASTER" "$REPLICA"; do
        $SSH ec2-user@"$LG1" "
            export PATH=/opt/symas/bin:/opt/symas/sbin:\$PATH
            LDAPTLS_REQCERT=never ldapwhoami -x -ZZ -H ldap://${host}:389 \
                -D '$ADMIN_DN' -w '$ADMIN_PW' >/dev/null 2>&1
        " || { log "FAIL: Cannot bind to $host"; ok=false; }
    done

    if $ok; then
        log "Smoke test PASSED"

        log "Running 10 ops/sec for 60s smoke load..."
        $SSH ec2-user@"$LG1" "
            python3 /tmp/ldap-load-tester.py --host $REPLICA --port 636 \
                --mode login --target-ops 10 --duration 60 --concurrency 5 --json
        " 2>/dev/null | tee "${RESULTS_DIR}/smoke.json"
    else
        err "Smoke test FAILED"
        return 1
    fi
}

run_baseline() {
    local iteration="$1"
    log "=== PHASE 1: Baseline Performance (iteration ${iteration}) ==="

    log "Starting monitor on replica..."
    $SSH ec2-user@"$LG1" "
        ADMIN_DN='$ADMIN_DN' ADMIN_PW='$ADMIN_PW' MASTER_IP='$MASTER' \
        bash -c 'nohup python3 -c \"
import subprocess, time, os
os.chdir(\\\"/tmp\\\")
while True:
    t=time.time()
    subprocess.run([\\\"/opt/symas/bin/ldapsearch\\\",\\\"-x\\\",\\\"-ZZ\\\",\\\"-H\\\",\\\"ldap://${REPLICA}\\\",\\\"-D\\\",\\\"${ADMIN_DN}\\\",\\\"-w\\\",\\\"${ADMIN_PW}\\\",\\\"-b\\\",\\\"cn=Monitor\\\",\\\"-s\\\",\\\"sub\\\",\\\"(objectClass=*)\\\",\\\"dn\\\"],capture_output=True,env={\\\"LDAPTLS_REQCERT\\\":\\\"never\\\",\\\"PATH\\\":\\\"/opt/symas/bin:/opt/symas/sbin\\\"})
    time.sleep(5)
\" &>/dev/null &'
    " 2>/dev/null || true

    log "Login load: 100 ops/sec on replica for 5 minutes..."
    $SSH ec2-user@"$LG2" "
        python3 /tmp/ldap-load-tester.py --host $REPLICA --port 636 \
            --mode login --target-ops 100 --duration 300 --concurrency 50 --json
    " 2>/dev/null | tee "${RESULTS_DIR}/baseline_i${iteration}.json"

    log "Baseline complete"
}

run_write_test() {
    local iteration="$1"
    log "=== PHASE 2: Write Performance (iteration ${iteration}) ==="

    log "Adding 1000 churn users on master..."
    $SSH ec2-user@"$LG1" "
        python3 /tmp/ldap-load-tester.py --host $MASTER --port 636 \
            --mode write --target-ops 25 --duration 120 --concurrency 5 --json
    " 2>/dev/null | tee "${RESULTS_DIR}/write_i${iteration}.json"

    log "Write test complete"
}

run_load_test() {
    local iteration="$1"
    log "=== PHASE 3: Load Test (iteration ${iteration}) ==="

    log "Mixed load: 500 ops/sec login + 25 ops/sec writes for 10 minutes..."
    $SSH ec2-user@"$LG2" "
        python3 /tmp/ldap-load-tester.py --host $REPLICA --port 636 \
            --mode mixed --target-ops 500 --duration 600 --concurrency 100 --json
    " 2>/dev/null | tee "${RESULTS_DIR}/load_i${iteration}.json"

    log "Load test complete"
}

run_stress_test() {
    local iteration="$1"
    log "=== PHASE 4: Stress Test (iteration ${iteration}) ==="

    log "Stress ramp: 100→2000 ops/sec..."
    $SSH ec2-user@"$LG1" "
        python3 /tmp/ldap-load-tester.py --host $REPLICA --port 636 \
            --mode stress --duration 2400 --concurrency 100 --json
    " 2>/dev/null | tee "${RESULTS_DIR}/stress_i${iteration}.json"

    log "Stress test complete"
}

tune_and_retest() {
    local iteration="$1"
    log "=== TUNING ITERATION ${iteration} ==="

    # Apply tuning to master
    log "Applying tuning I${iteration} to master..."
    $SSH ec2-user@"$MASTER" "
        sudo bash /tmp/script/perf/tune-ldap.sh localhost ${iteration}
    " 2>&1 | tail -5

    # Apply tuning to replica
    log "Applying tuning I${iteration} to replica..."
    $SSH ec2-user@"$REPLICA" "
        sudo bash /tmp/script/perf/tune-ldap.sh localhost ${iteration}
    " 2>&1 | tail -5

    # Wait for services to stabilize
    sleep 10
}

# ===== Main Orchestrator =====
log "=== OpenLDAP Performance Test Suite ==="
log "Master: ${MASTER}, Replica: ${REPLICA}"
log "Results: ${RESULTS_DIR}"
log ""

deploy_scripts_to_loadgen

# Copy tuning scripts to LDAP nodes
$SCP "${SCRIPT_DIR}/tune-ldap.sh" "ec2-user@${MASTER}:/tmp/script/perf/"
$SCP "${SCRIPT_DIR}/tune-ldap.sh" "ec2-user@${REPLICA}:/tmp/script/perf/"
$SSH ec2-user@"$MASTER" "mkdir -p /tmp/script/perf"
$SSH ec2-user@"$REPLICA" "mkdir -p /tmp/script/perf"

# Phase 0: Smoke
run_smoke_test || exit 1

# Iteration I1: Baseline (no tuning)
run_baseline 1

# Iteration I1: Apply indexes, retest
tune_and_retest 1
run_baseline 2
run_write_test 2

# Iteration I2: Tune threads
tune_and_retest 2
run_baseline 3
run_load_test 3

# Iteration I3: LMDB + OS limits
tune_and_retest 3
run_baseline 4

# Iteration I4: Disk/I/O
tune_and_retest 4
run_baseline 5

# Iteration I5: Logging
tune_and_retest 5
run_baseline 6

# Iteration I6: Combined best
tune_and_retest 6
run_baseline 7
run_load_test 7
run_write_test 7

# Iteration I7: Final optimum
tune_and_retest 7
run_baseline 8
run_stress_test 8

log ""
log "=== Test Suite Complete ==="
log "Results saved to: ${RESULTS_DIR}"
log ""

# Generate summary
{
    echo "Summary of all results:"
    for f in "$RESULTS_DIR"/*.json; do
        if [[ -f "$f" ]]; then
            echo "--- $(basename "$f") ---"
            python3 -c "
import json
with open('$f') as fh:
    d = json.load(fh)
    print(f\"  Ops/sec: {d.get('ops_per_sec', 'N/A')}\")
    print(f\"  Errors:  {d.get('errors', 'N/A')}\")
    print(f\"  Error%:  {d.get('error_rate', 'N/A')}%\")
    if 'latency_p50' in d and 'search' in d['latency_p50']:
        print(f\"  p50:     {d['latency_p50']['search']}ms\")
        print(f\"  p95:     {d['latency_p95']['search']}ms\")
        print(f\"  p99:     {d['latency_p99']['search']}ms\")
" 2>/dev/null || echo "  (parse error)"
        fi
    done
} > "${RESULTS_DIR}/summary.txt"
cat "${RESULTS_DIR}/summary.txt"
