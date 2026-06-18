#!/usr/bin/env bash
# deploy-tls-lab.sh — Full OpenLDAP Master+Replica TLS deployment
# Usage: bash deploy-tls-lab.sh
# Run from: /Users/eramadan/openscript/nextgenopen/

set -euo pipefail

SSH_KEY="terraform/openldap-master-replica/.local-ssh/openldap_master_replica"
MASTER=54.186.123.12
REPLICA=44.243.198.216
MASTER_PRIV=10.30.1.10
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $SSH_KEY"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
err()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# Preflight checks
[[ -f "$SSH_KEY" ]] || err "SSH key not found: $SSH_KEY"

# --- Step 1: Copy scripts to both nodes ---
log "Copying scripts to master..."
tar czf /tmp/ngoscripts.tar.gz -C "$(pwd)" script
scp $SSH_OPTS /tmp/ngoscripts.tar.gz ec2-user@$MASTER:/tmp/
ssh $SSH_OPTS ec2-user@$MASTER 'tar xzf /tmp/ngoscripts.tar.gz -C /tmp/ && rm /tmp/ngoscripts.tar.gz'

log "Copying scripts to replica..."
scp $SSH_OPTS /tmp/ngoscripts.tar.gz ec2-user@$REPLICA:/tmp/
ssh $SSH_OPTS ec2-user@$REPLICA 'tar xzf /tmp/ngoscripts.tar.gz -C /tmp/ && rm /tmp/ngoscripts.tar.gz'
rm /tmp/ngoscripts.tar.gz

# --- Step 2: Install master with TLS (clean + install) ---
log "Installing master (TLS_MODE=yes)..."
ssh $SSH_OPTS ec2-user@$MASTER 'sudo TLS_MODE=yes CLEAN=1 SKIP_TEST=1 SKIP_DIAG=1 bash /tmp/script/master-all-in-one.sh' || {
  err "Master install failed"
}

# --- Step 3: Extract master CA cert ---
log "Extracting master CA cert..."
ssh $SSH_OPTS ec2-user@$MASTER 'sudo cat /opt/symas/etc/openldap/tls/ca.crt' > /tmp/master-ca.crt
ssh $SSH_OPTS ec2-user@$MASTER 'sudo cat /opt/symas/etc/openldap/tls/ca.key' > /tmp/master-ca.key
log "CA cert saved to /tmp/master-ca.crt ($(wc -c < /tmp/master-ca.crt) bytes)"

# --- Step 4: Install replica with master CA (clean + install) ---
log "Copying CA to replica..."
scp $SSH_OPTS /tmp/master-ca.crt /tmp/master-ca.key ec2-user@$REPLICA:/tmp/

log "Installing replica (TLS_MODE=yes + master CA)..."
ssh $SSH_OPTS ec2-user@$REPLICA \
  "sudo MASTER_IP=$MASTER_PRIV ADMIN_PW=TheN1le1 REPL_PW=replpass \
   TLS_MODE=yes CLEAN=1 COPY_FROM_MASTER=1 \
   STAGED_CA_CERT=/tmp/master-ca.crt STAGED_CA_KEY=/tmp/master-ca.key \
   LDAPTLS_REQCERT=never SKIP_TEST=1 SKIP_DIAG=1 bash /tmp/script/replica-all-in-one.sh" || {
  err "Replica install failed"
}

# --- Step 5: Test connections ---
log "=== Testing Connections ==="

export LDAPTLS_CACERT=/tmp/master-ca.crt

log "Master TLS bind (StartTLS)..."
ldapwhoami -x -ZZ -H ldap://$MASTER:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" || err "Master bind failed"

log "Replica TLS bind (StartTLS)..."
ldapwhoami -x -ZZ -H ldap://$REPLICA:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" || err "Replica bind failed"

log "Master LDAPS bind (port 636)..."
ldapwhoami -x -H ldaps://$MASTER:636 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" || err "Master LDAPS bind failed"

log "Replica LDAPS bind (port 636)..."
ldapwhoami -x -H ldaps://$REPLICA:636 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" || err "Replica LDAPS bind failed"

# --- Step 6: Test replication ---
log "=== Testing Replication ==="

TEST_UID="repltest-$(date +%Y%m%d%H%M%S)"

ldapadd -x -ZZ -H ldap://$MASTER:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" <<EOF
dn: uid=${TEST_UID},ou=Users,dc=eab,dc=bank,dc=local
objectClass: inetOrgPerson
objectClass: organizationalPerson
objectClass: person
cn: ReplTest
sn: Test
uid: ${TEST_UID}
userPassword: TestPass123!
EOF

log "Waiting 10s for replication..."
sleep 10

RESULT=$(ldapsearch -x -ZZ -o ldif-wrap=no -H ldap://$REPLICA:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  -b "uid=${TEST_UID},ou=Users,dc=eab,dc=bank,dc=local" -s base dn 2>&1)

if echo "$RESULT" | grep -q "uid=${TEST_UID}"; then
  log "Replication: PASS (entry found on replica)"
else
  err "Replication: FAIL (entry not found on replica)"
fi

log "Cleaning up test entry..."
ldapdelete -x -ZZ -H ldap://$MASTER:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  "uid=${TEST_UID},ou=Users,dc=eab,dc=bank,dc=local" 2>/dev/null || true

# --- Done ---
echo ""
echo "=========================================="
echo "  DEPLOYMENT COMPLETE — ALL TESTS PASSED"
echo "=========================================="
echo "  Master:   $MASTER (private $MASTER_PRIV)"
echo "  Replica:  $REPLICA"
echo "  CA cert:  /tmp/master-ca.crt"
echo "=========================================="
echo ""
echo "Connect:"
echo "  export LDAPTLS_CACERT=/tmp/master-ca.crt"
echo "  ldapwhoami -x -ZZ -H ldap://$MASTER:389 -D 'cn=admin,dc=eab,dc=bank,dc=local' -w 'TheN1le1'"
echo ""
