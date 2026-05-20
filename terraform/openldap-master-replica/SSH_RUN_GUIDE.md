# Run OpenLDAP Master/Replica Scripts Over SSH

Use this guide to run `bootstrap-openldap.sh` on EC2 or any RHEL 9-compatible VM that has SSH, `sudo`, `dnf`, and `systemd`.

## Topology

- Master: writable OpenLDAP node.
- Replica: read-only syncrepl consumer.
- The replica must reach the master on TCP `389`.
- Your workstation must reach both VMs over SSH.

## Required Variables

| Variable | Master | Replica | Meaning |
| --- | --- | --- | --- |
| `ROLE` | `master` | `replica` | Node role. |
| `PRIVATE_IP` | master private IP | replica private IP | IP used by local slapd listener. |
| `MASTER_IP` | omit | master private IP | Provider used by replica syncrepl. |
| `BASE_DN` | same on both | same on both | Directory suffix. |
| `ORG_NAME` | same on both | same on both | Base organization name. |
| `ADMIN_PW` | same on both | same on both | Password for `cn=admin,$BASE_DN`. |
| `REPL_PW` | same on both | same on both | Password for `cn=replicator,$BASE_DN`. |
| `SERVER_ID` | `1` | `2` | Unique OpenLDAP server ID. |

## Example Inputs

```bash
MASTER_HOST="52.13.60.230"
REPLICA_HOST="54.189.212.43"
MASTER_PRIVATE_IP="10.30.1.10"
REPLICA_PRIVATE_IP="10.30.2.10"
SSH_KEY="terraform/openldap-master-replica/.local-ssh/openldap_master_replica"
SSH_USER="ec2-user"
BASE_DN="dc=cae,dc=local"
ORG_NAME="CAE"
ADMIN_PW="admin"
REPL_PW="replpass"
```

For a non-EC2 VM, replace hostnames, private IPs, SSH user, and key path.

## Copy Script To VMs

```bash
scp -i "$SSH_KEY" \
  terraform/openldap-master-replica/scripts/bootstrap-openldap.sh \
  "$SSH_USER@$MASTER_HOST:/tmp/bootstrap-openldap.sh"

scp -i "$SSH_KEY" \
  terraform/openldap-master-replica/scripts/bootstrap-openldap.sh \
  "$SSH_USER@$REPLICA_HOST:/tmp/bootstrap-openldap.sh"
```

## Run Master

Run the master first.

```bash
ssh -i "$SSH_KEY" "$SSH_USER@$MASTER_HOST" \
  "chmod +x /tmp/bootstrap-openldap.sh && \
   sudo ROLE='master' \
     PRIVATE_IP='$MASTER_PRIVATE_IP' \
     BASE_DN='$BASE_DN' \
     ORG_NAME='$ORG_NAME' \
     ADMIN_PW='$ADMIN_PW' \
     REPL_PW='$REPL_PW' \
     SERVER_ID='1' \
     /tmp/bootstrap-openldap.sh"
```

Expected result:

- Symas OpenLDAP packages installed.
- `symas-openldap-servers` active.
- Base DN and `ou=people`/`ou=groups` created.
- Replication user `cn=replicator,$BASE_DN` created.
- `syncprov` overlay enabled.

## Run Replica

Run the replica after the master succeeds.

```bash
ssh -i "$SSH_KEY" "$SSH_USER@$REPLICA_HOST" \
  "chmod +x /tmp/bootstrap-openldap.sh && \
   sudo ROLE='replica' \
     PRIVATE_IP='$REPLICA_PRIVATE_IP' \
     MASTER_IP='$MASTER_PRIVATE_IP' \
     BASE_DN='$BASE_DN' \
     ORG_NAME='$ORG_NAME' \
     ADMIN_PW='$ADMIN_PW' \
     REPL_PW='$REPL_PW' \
     SERVER_ID='2' \
     /tmp/bootstrap-openldap.sh"
```

Expected result:

- Symas OpenLDAP packages installed.
- `symas-openldap-servers` active.
- Replica configured with `olcSyncRepl` from the master.
- Replica configured read-only with `olcReadOnly: TRUE`.

## Verify Services

```bash
ssh -i "$SSH_KEY" "$SSH_USER@$MASTER_HOST" \
  "sudo systemctl is-active symas-openldap-servers"

ssh -i "$SSH_KEY" "$SSH_USER@$REPLICA_HOST" \
  "sudo systemctl is-active symas-openldap-servers"
```

Expected result from both:

```text
active
```

## Verify LDAP Bind And Base DN

```bash
ssh -i "$SSH_KEY" "$SSH_USER@$MASTER_HOST" \
  "sudo /opt/symas/bin/ldapwhoami -x -H ldap://localhost:389 \
    -D 'cn=admin,$BASE_DN' -w '$ADMIN_PW'"

ssh -i "$SSH_KEY" "$SSH_USER@$MASTER_HOST" \
  "sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 \
    -D 'cn=admin,$BASE_DN' -w '$ADMIN_PW' \
    -b '$BASE_DN' -s base dn"

ssh -i "$SSH_KEY" "$SSH_USER@$REPLICA_HOST" \
  "sudo /opt/symas/bin/ldapwhoami -x -H ldap://localhost:389 \
    -D 'cn=admin,$BASE_DN' -w '$ADMIN_PW'"
```

Expected bind result:

```text
dn:cn=admin,dc=cae,dc=local
```

Expected base DN result:

```text
dn: dc=cae,dc=local
```

## Verify Replication Manually

Create a unique test user on the master.

```bash
UID_VALUE="manualcheck$(date -u +%Y%m%d%H%M%S)"

ssh -i "$SSH_KEY" "$SSH_USER@$MASTER_HOST" "cat >/tmp/$UID_VALUE.ldif <<LDIF
dn: uid=$UID_VALUE,ou=people,$BASE_DN
objectClass: inetOrgPerson
cn: Manual Replication Check
sn: Check
uid: $UID_VALUE
mail: $UID_VALUE@example.test
LDIF
sudo /opt/symas/bin/ldapadd -x -H ldap://localhost:389 \
  -D 'cn=admin,$BASE_DN' -w '$ADMIN_PW' \
  -f /tmp/$UID_VALUE.ldif"
```

Search for the same user on the replica.

```bash
ssh -i "$SSH_KEY" "$SSH_USER@$REPLICA_HOST" \
  "sudo /opt/symas/bin/ldapsearch -LLL -x -H ldap://localhost:389 \
    -D 'cn=admin,$BASE_DN' -w '$ADMIN_PW' \
    -b '$BASE_DN' '(uid=$UID_VALUE)' dn"
```

Expected result:

```text
dn: uid=<UID_VALUE>,ou=people,dc=cae,dc=local
```

## Verify With Helper Script

For the Terraform-created EC2 lab, use:

```bash
cd terraform/openldap-master-replica
./scripts/verify.sh
```

This script reads Terraform outputs, connects over SSH, checks services and LDAP binds, writes a test user to the master, then confirms it appears on the replica.

## Troubleshooting

- Exit `137`: VM ran out of memory during `dnf`; the script creates `/swapfile`, but very small or locked-down systems may need swap enabled manually.
- SSH timeout: check VM public IP, security group/firewall, key path, and user.
- Replica cannot sync: check TCP `389` from replica private IP to master private IP.
- Bind fails: confirm `BASE_DN`, `ADMIN_PW`, and `REPL_PW` match on both nodes.
- Service fails: run `sudo journalctl -u symas-openldap-servers --no-pager -n 100`.
