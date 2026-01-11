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
  -b "dc=cae,dc=local" "(uid=testuser)"
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

## Notes

- Base DN is `dc=cae,dc=local`. Admin DN is `cn=admin,dc=cae,dc=local`.
- Default passwords are `admin` (admin) and `config` (cn=config).
- If you want a different base DN/DIT, share the desired values and I can update all LDIFs and compose envs.
