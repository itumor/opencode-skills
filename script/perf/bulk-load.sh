#!/usr/bin/env bash
# bulk-load.sh — Generate 1.5M users and bulk-load into OpenLDAP master
set -euo pipefail

SSH_KEY="/Users/eramadan/openscript/nextgenopen/terraform/openldap-perf-test/.local-ssh/openldap_master_replica"
MASTER=35.89.241.129
MASTER_PRIV=10.40.1.10
REPLICA=44.246.185.17
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $SSH_KEY"
SCP="scp -o StrictHostKeyChecking=no -i $SSH_KEY"

USER_COUNT="${1:-1500000}"
BASE_DN="dc=eab,dc=bank,dc=local"
ADMIN_PW="TheN1le1"
PW="Test123!"

log() { echo "[$(date +%H:%M:%S)] $*"; }
err() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

log "=== Phase 2.2: Generate ${USER_COUNT} users + bulk load ==="

# --- Step 1: Copy generator script to master ---
log "Copying LDIF generator to master"
cat "$(dirname "$0")/gen-ldif.py" | $SSH ec2-user@$MASTER 'cat > /tmp/gen-ldif.py && chmod +x /tmp/gen-ldif.py'

# --- Step 2: Generate LDIF on master ---
log "Generating ${USER_COUNT}-user LDIF on master (this will take 10-20 min)..."
$SSH ec2-user@$MASTER "python3 /tmp/gen-ldif.py ${USER_COUNT} '${PW}' '${BASE_DN}' > /tmp/users.ldif" &
GEN_PID=$!

# Monitor progress
while kill -0 $GEN_PID 2>/dev/null; do
  SIZE=$($SSH ec2-user@$MASTER "wc -c < /tmp/users.ldif 2>/dev/null || echo 0" 2>/dev/null || echo "0")
  SIZE_MB=$((SIZE / 1048576))
  ENTRIES=$($SSH ec2-user@$MASTER "grep -c '^dn: ' /tmp/users.ldif 2>/dev/null || echo 0" 2>/dev/null || echo "0")
  log "  ${ENTRIES} entries, ${SIZE_MB}MB generated so far..."
  sleep 30
done
wait $GEN_PID || err "LDIF generation failed"

TOTAL_SIZE=$($SSH ec2-user@$MASTER "wc -c < /tmp/users.ldif" 2>/dev/null || echo "0")
TOTAL_MB=$((TOTAL_SIZE / 1048576))
TOTAL_ENTRIES=$($SSH ec2-user@$MASTER "grep -c '^dn: ' /tmp/users.ldif" 2>/dev/null || echo "0")
log "LDIF generated: ${TOTAL_ENTRIES} entries, ${TOTAL_MB}MB"

# --- Step 3: Stop LDAP services on master ---
log "Stopping master slapd..."
$SSH ec2-user@$MASTER 'sudo systemctl stop symas-openldap-servers'

# --- Step 4: Bulk import via slapadd ---
log "Running slapadd (this will take 10-30 min)..."
$SSH ec2-user@$MASTER "sudo /opt/symas/sbin/slapadd -n 1 -l /tmp/users.ldif" &
SLAPADD_PID=$!

while kill -0 $SLAPADD_PID 2>/dev/null; do
  DB_SIZE=$($SSH ec2-user@$MASTER "sudo du -sh /var/symas/openldap-data/example/ 2>/dev/null | awk '{print \$1}'" 2>/dev/null || echo "?")
  log "  DB size: ${DB_SIZE}..."
  sleep 30
done
wait $SLAPADD_PID || err "slapadd failed"

# --- Step 5: Rebuild indexes ---
log "Running slapindex..."
$SSH ec2-user@$MASTER "sudo /opt/symas/sbin/slapindex -n 1" || err "slapindex failed"

# --- Step 6: Fix permissions and start ---
log "Fixing permissions..."
$SSH ec2-user@$MASTER 'sudo chown -R ldap:ldap /var/symas/openldap-data/example/ 2>/dev/null || sudo chown -R symas-openldap:symas-openldap /var/symas/openldap-data/example/ 2>/dev/null || true'
$SSH ec2-user@$MASTER 'sudo restorecon -Rv /var/symas/openldap-data/example/ 2>/dev/null || true'

log "Starting master slapd..."
$SSH ec2-user@$MASTER 'sudo systemctl start symas-openldap-servers'
sleep 10

# --- Step 7: Verify master ---
MASTER_COUNT=$($SSH ec2-user@$MASTER "
  export PATH=/opt/symas/bin:/opt/symas/sbin:\$PATH
  LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
    -D 'cn=admin,${BASE_DN}' -w '${ADMIN_PW}' \
    -b '${BASE_DN}' -s sub '(objectClass=inetOrgPerson)' dn 2>/dev/null | grep -c '^dn: ' || echo 0
" 2>/dev/null || echo "0")
log "Master has ${MASTER_COUNT} inetOrgPerson entries (expected ~${USER_COUNT})"

# --- Step 8: Wait for replica sync ---
log "Waiting for replica to sync ${USER_COUNT} entries..."
for i in $(seq 1 60); do
  REPLICA_COUNT=$($SSH ec2-user@$REPLICA "
    export PATH=/opt/symas/bin:/opt/symas/sbin:\$PATH
    LDAPTLS_REQCERT=never ldapsearch -x -ZZ -H ldap://localhost \
      -D 'cn=admin,${BASE_DN}' -w '${ADMIN_PW}' \
      -b '${BASE_DN}' -s sub '(objectClass=inetOrgPerson)' dn 2>/dev/null | grep -c '^dn: ' || echo 0
  " 2>/dev/null || echo "0")
  log "  Replica: ${REPLICA_COUNT}/${MASTER_COUNT} entries synced"
  if [[ "$REPLICA_COUNT" -ge "$MASTER_COUNT" ]] && [[ "$MASTER_COUNT" -gt 0 ]]; then
    log "Replica fully synced!"
    break
  fi
  sleep 30
done

log "=== Bulk load complete ==="
log "Master: ${MASTER_COUNT} users, Replica: ${REPLICA_COUNT} users"
