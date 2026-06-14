#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="/Users/eramadan/openscript/nextgenopen/terraform/openldap-perf-test/.local-ssh/openldap_master_replica"
MASTER=35.89.241.129
REPLICA=44.246.185.17
MASTER_PRIV=10.40.1.10
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $SSH_KEY"
SCP="scp -o StrictHostKeyChecking=no -i $SSH_KEY"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
err()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

[[ -f "$SSH_KEY" ]] || err "SSH key not found: $SSH_KEY"

# --- Step 1: Copy scripts to both nodes ---
log "Copying scripts to master..."
tar czf /tmp/ngoscripts.tar.gz -C "$(pwd)" script
$SCP /tmp/ngoscripts.tar.gz ec2-user@$MASTER:/tmp/
$SSH ec2-user@$MASTER 'tar xzf /tmp/ngoscripts.tar.gz -C /tmp/ && rm /tmp/ngoscripts.tar.gz'

log "Copying scripts to replica..."
$SCP /tmp/ngoscripts.tar.gz ec2-user@$REPLICA:/tmp/
$SSH ec2-user@$REPLICA 'tar xzf /tmp/ngoscripts.tar.gz -C /tmp/ && rm /tmp/ngoscripts.tar.gz'
rm /tmp/ngoscripts.tar.gz

# --- Step 2: Clean both nodes ---
log "Cleaning master..."
$SSH ec2-user@$MASTER 'sudo bash /tmp/script/0-clean-openldap.sh'

log "Cleaning replica..."
$SSH ec2-user@$REPLICA 'sudo bash /tmp/script/0-clean-openldap.sh'

# --- Step 3: Install master with TLS ---
log "Installing master (TLS_MODE=yes)..."
$SSH ec2-user@$MASTER 'sudo TLS_MODE=yes bash /tmp/script/install-symas-openldap-all-in-one.sh' || {
  err "Master install failed"
}

# --- Step 4: Extract master CA cert ---
log "Extracting master CA cert..."
$SSH ec2-user@$MASTER 'sudo cat /opt/symas/etc/openldap/tls/ca.crt' > /tmp/perf-master-ca.crt
$SSH ec2-user@$MASTER 'sudo cat /opt/symas/etc/openldap/tls/ca.key' > /tmp/perf-master-ca.key
log "CA cert saved to /tmp/perf-master-ca.crt ($(wc -c < /tmp/perf-master-ca.crt) bytes)"

# --- Step 5: Install replica with master CA ---
log "Copying CA to replica..."
$SCP /tmp/perf-master-ca.crt /tmp/perf-master-ca.key ec2-user@$REPLICA:/tmp/

log "Installing replica (TLS_MODE=yes + master CA)..."
$SSH ec2-user@$REPLICA \
  "sudo MASTER_IP=$MASTER_PRIV ADMIN_PW=TheN1le1 REPL_PW=replpass \
   TLS_MODE=yes COPY_FROM_MASTER=1 \
   STAGED_CA_CERT=/tmp/perf-master-ca.crt STAGED_CA_KEY=/tmp/perf-master-ca.key \
   LDAPTLS_REQCERT=never bash /tmp/script/install-symas-openldap-replica-all-in-one.sh" || {
  err "Replica install failed"
}

log "OpenLDAP master+replica deployed successfully"
