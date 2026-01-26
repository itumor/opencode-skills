# OpenLDAP MirrorMode lab

This folder contains a lab build for 2 OpenLDAP masters (MirrorMode), 2 read-only replicas, and 2 HAProxy VIPs (read/write), plus TLS and LDIFs for replication setup.

## Prereqs

- Docker Engine + Docker Compose plugin
- openssl

## Run

From `openldap-mirrormode/`:

```bash
./scripts/gen-certs.sh

docker compose up -d
```

## Configure replication

### Automated setup

If you prefer not to type every `docker exec … ldapadd/ldapmodify` command, run:

```bash
chmod +x scripts/apply-replication-ldifs.sh
./scripts/apply-replication-ldifs.sh
```

It executes the same LDIF files described below (replicator user, server IDs, syncprov, MirrorMode, read-only consumers).

### 1) Create replicator user on both masters

```bash
docker exec -i ldap-master-a ldapadd -x \
  -D "cn=admin,dc=cae,dc=local" -w admin \
  -H ldap://localhost:389 \
  <<EOF
$(cat ldif/01-replicator.ldif)
EOF

docker exec -i ldap-master-b ldapadd -x \
  -D "cn=admin,dc=cae,dc=local" -w admin \
  -H ldap://localhost:389 \
  <<EOF
$(cat ldif/01-replicator.ldif)
EOF
```

### 1b) Allow replicator DN to read (required for syncrepl)

Without this ACL, the replicator bind succeeds but searches return `No such object (32)`, so replicas never receive updates.

```bash
docker exec -i ldap-master-a ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/02-replicator-acl.ldif)
EOF

docker exec -i ldap-master-b ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/02-replicator-acl.ldif)
EOF
```

### 2) Set server IDs

```bash
docker exec -i ldap-master-a ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/10-serverid-master-a.ldif)
EOF

docker exec -i ldap-master-b ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/11-serverid-master-b.ldif)
EOF

docker exec -i ldap-replica-a ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/12-serverid-replica-a.ldif)
EOF

docker exec -i ldap-replica-b ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/13-serverid-replica-b.ldif)
EOF
```

### 3) Enable syncprov on masters

```bash
docker exec -i ldap-master-a ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/19-load-syncprov.ldif)
EOF

docker exec -i ldap-master-b ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/19-load-syncprov.ldif)
EOF

docker exec -i ldap-master-a ldapadd -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/20-syncprov-master.ldif)
EOF

docker exec -i ldap-master-b ldapadd -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/20-syncprov-master.ldif)
EOF
```

### 4) Configure MirrorMode on masters

```bash
docker exec -i ldap-master-a ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/21-mirrormode-master-a.ldif)
EOF

docker exec -i ldap-master-b ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/22-mirrormode-master-b.ldif)
EOF
```

### 5) Configure replicas as read-only consumers

```bash
docker exec -i ldap-replica-a ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/30-replica-consumer.ldif)
EOF

docker exec -i ldap-replica-b ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/30-replica-consumer.ldif)
EOF

docker exec -i ldap-replica-a ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/31-replica-readonly.ldif)
EOF

docker exec -i ldap-replica-b ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/31-replica-readonly.ldif)
EOF
```

## Verify

### 1) Basic whoami

```bash
ldapwhoami -x -H ldap://localhost:1389 -D "cn=admin,dc=cae,dc=local" -w admin
ldapwhoami -x -H ldap://localhost:2389 -D "cn=admin,dc=cae,dc=local" -w admin
```

### 2) Add and read a test user

```bash

ldapadd -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=cae,dc=local" -w admin \
  -f ldif/90-test-user.ldif

ldapsearch -x -H ldap://localhost:2389 \
  -D "cn=admin,dc=cae,dc=local" -w admin \
  -b "dc=cae,dc=local" "(uid=testuser5)"
```

### 3) Failover test (write VIP)

```bash
docker stop ldap-master-a

ldapmodify -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=cae,dc=local" -w admin <<'EOF'
dn: uid=testuser,dc=cae,dc=local
changetype: modify
replace: sn
sn: user2
EOF

docker start ldap-master-a
```

## Keepalived VIP failover (single IP)

If you prefer a single VIP that moves between two MirrorMode masters (master/backup),
see the example Keepalived configs in `keepalived/`:

- `keepalived/keepalived-master.conf`
- `keepalived/keepalived-backup.conf`
- `keepalived/check_slapd.sh`

These are intended for real hosts (not the Docker lab). The Docker Compose lab
still uses HAProxy VIPs for read/write separation.

### Keepalived failover test (VIP)

From `openldap-mirrormode/` on a machine with LDAP client tools installed:

```bash
chmod +x scripts/test-keepalived-failover.sh

VIP_HOST=192.168.10.50 \
MASTER_A_URI=ldap://ldap1:389 \
MASTER_B_URI=ldap://ldap2:389 \
FAILOVER_CMD="ssh root@ldap1 'systemctl stop keepalived'" \
FAILBACK_CMD="ssh root@ldap1 'systemctl start keepalived'" \
./scripts/test-keepalived-failover.sh --failover
```


## How to run
```bash
chmod +x scripts/test-ldap-cluster.sh
./scripts/test-ldap-cluster.sh
BASE_DN="dc=example,dc=org" ADMIN_PW="admin" ./scripts/test-ldap-cluster.sh

```

## Optional failover test (stops master-a temporarily):
```bash
./scripts/test-ldap-cluster.sh --failover
```


## Notes

- Base DN is `dc=cae,dc=local`. Admin DN is `cn=admin,dc=cae,dc=local`.
- Default passwords are `admin` (admin) and `config` (cn=config).
- If you want a different base DN/DIT, share the desired values and I can update all LDIFs and compose envs.
