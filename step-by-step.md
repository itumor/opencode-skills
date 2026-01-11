Below is a practical “lab build” of the architecture described in your PDF: **2 OpenLDAP masters in MirrorMode + 2 read-only replicas + 2 load balancers (read VIP + write VIP) + TLS + key overlays**. This maps directly to the proposal’s main-site design (MirrorMode multi-master, two read replicas, and separate read/write load balancers; TLS/ACLs; overlays such as lastbind/ppolicy/accesslog). 

I’m giving you **step-by-step** plus **copy/pasteable** Compose + HAProxy configs + LDIFs + commands. Your “expert code agent” can then harden/productionize it.

---

## 0) What we are building (matches the proposal)

From the proposal (main site): 

* **Master A** (read/write – the preferred writer)
* **Master B** (hot standby; kept in sync via replication)
* **Read replica A1**, **Read replica B1** (serve read-only auth/search traffic)
* **Two load balancers**:

  * **WRITE LB** → prefers Master A, fails over to Master B
  * **READ LB** → balances across read replicas (and can keep masters as backups)

MirrorMode + SyncRepl concepts are standard OpenLDAP replication building blocks. ([openldap.org][1])
Delta-syncrepl typically uses **accesslog** to optimize replication traffic. ([kb.symas.com][2])

---

## 1) Prereqs (local lab)

* Docker Engine + Docker Compose plugin
* `openssl` (for generating a shared TLS cert)

Notes:

* In real environments, the proposal expects certs from internal PKI/CA and proper LB/DNS cutover. 
* In this lab, we will generate **one shared certificate** (SAN includes VIP names + node names) and mount it into all LDAP nodes so TLS works through the VIPs.

---

## 2) Create a working folder structure

```bash
mkdir -p openldap-mirrormode/{certs,haproxy,scripts,ldif}
cd openldap-mirrormode
```

---

## 3) Generate a shared TLS CA + server cert (SAN includes VIPs + nodes)

Create `scripts/gen-certs.sh`:

```bash
cat > scripts/gen-certs.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p certs
cd certs

# 1) CA
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -subj "/C=EG/O=Lab-CA/OU=LDAP/CN=Lab LDAP CA" \
  -out ca.crt

# 2) Server key + CSR
openssl genrsa -out ldap.key 4096

cat > san.cnf <<'CONF'
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
C=EG
O=Lab-Org
OU=LDAP
CN=ldap-write

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ldap-write
DNS.2 = ldap-read
DNS.3 = ldap-master-a
DNS.4 = ldap-master-b
DNS.5 = ldap-replica-a
DNS.6 = ldap-replica-b
DNS.7 = localhost
IP.1  = 127.0.0.1
CONF

openssl req -new -key ldap.key -out ldap.csr -config san.cnf
openssl x509 -req -in ldap.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out ldap.crt -days 825 -sha256 -extensions req_ext -extfile san.cnf

# osixia/openldap expects specific filenames we will reference via env vars
# We'll use:
#   ca.crt, ldap.crt, ldap.key
chmod 600 ldap.key
echo "Certs generated in ./certs"
EOF

chmod +x scripts/gen-certs.sh
./scripts/gen-certs.sh
```

This follows the osixia image’s supported “mount certs + set env filenames” approach. ([GitHub][3])

---

## 4) HAProxy configs (read VIP + write VIP)

Create `haproxy/haproxy-write.cfg`:

```cfg
global
  log stdout format raw local0
  maxconn 2048

defaults
  log global
  mode tcp
  timeout connect 5s
  timeout client  1m
  timeout server  1m

# WRITE VIP (LDAP 389)
frontend fe_ldap_write_389
  bind *:1389
  default_backend be_ldap_write_389

backend be_ldap_write_389
  option tcp-check
  # prefer master-a, failover to master-b
  server master_a ldap-master-a:389 check
  server master_b ldap-master-b:389 check backup

# WRITE VIP (LDAPS 636)
frontend fe_ldaps_write_636
  bind *:1636
  default_backend be_ldaps_write_636

backend be_ldaps_write_636
  option tcp-check
  server master_a ldap-master-a:636 check
  server master_b ldap-master-b:636 check backup
```

Create `haproxy/haproxy-read.cfg`:

```cfg
global
  log stdout format raw local0
  maxconn 2048

defaults
  log global
  mode tcp
  timeout connect 5s
  timeout client  1m
  timeout server  1m

# READ VIP (LDAP 389)
frontend fe_ldap_read_389
  bind *:2389
  default_backend be_ldap_read_389

backend be_ldap_read_389
  option tcp-check
  balance roundrobin
  server r1 ldap-replica-a:389 check
  server r2 ldap-replica-b:389 check
  # masters as backups for reads
  server m1 ldap-master-a:389 check backup
  server m2 ldap-master-b:389 check backup

# READ VIP (LDAPS 636)
frontend fe_ldaps_read_636
  bind *:2636
  default_backend be_ldaps_read_636

backend be_ldaps_read_636
  option tcp-check
  balance roundrobin
  server r1 ldap-replica-a:636 check
  server r2 ldap-replica-b:636 check
  server m1 ldap-master-a:636 check backup
  server m2 ldap-master-b:636 check backup
```

HAProxy TCP mode for LDAP/LDAPS load balancing is a common pattern. ([port389.org][4])

---

## 5) Docker Compose (4 LDAP nodes + 2 HAProxy LBs)

Create `docker-compose.yml`:

```yaml
services:
  ldap-master-a:
    image: osixia/openldap:1.5.0
    container_name: ldap-master-a
    hostname: ldap-master-a
    environment:
      LDAP_ORGANISATION: "CAE Lab"
      LDAP_DOMAIN: "cae.local"
      LDAP_ADMIN_PASSWORD: "admin"
      LDAP_CONFIG_PASSWORD: "config"
      LDAP_TLS: "true"
      LDAP_TLS_CRT_FILENAME: "ldap.crt"
      LDAP_TLS_KEY_FILENAME: "ldap.key"
      LDAP_TLS_CA_CRT_FILENAME: "ca.crt"
    volumes:
      - ./certs:/container/service/slapd/assets/certs:ro
      - master_a_db:/var/lib/ldap
      - master_a_cfg:/etc/ldap/slapd.d
    networks: [ldapnet]

  ldap-master-b:
    image: osixia/openldap:1.5.0
    container_name: ldap-master-b
    hostname: ldap-master-b
    environment:
      LDAP_ORGANISATION: "CAE Lab"
      LDAP_DOMAIN: "cae.local"
      LDAP_ADMIN_PASSWORD: "admin"
      LDAP_CONFIG_PASSWORD: "config"
      LDAP_TLS: "true"
      LDAP_TLS_CRT_FILENAME: "ldap.crt"
      LDAP_TLS_KEY_FILENAME: "ldap.key"
      LDAP_TLS_CA_CRT_FILENAME: "ca.crt"
    volumes:
      - ./certs:/container/service/slapd/assets/certs:ro
      - master_b_db:/var/lib/ldap
      - master_b_cfg:/etc/ldap/slapd.d
    networks: [ldapnet]

  ldap-replica-a:
    image: osixia/openldap:1.5.0
    container_name: ldap-replica-a
    hostname: ldap-replica-a
    environment:
      LDAP_ORGANISATION: "CAE Lab"
      LDAP_DOMAIN: "cae.local"
      LDAP_ADMIN_PASSWORD: "admin"
      LDAP_CONFIG_PASSWORD: "config"
      LDAP_TLS: "true"
      LDAP_TLS_CRT_FILENAME: "ldap.crt"
      LDAP_TLS_KEY_FILENAME: "ldap.key"
      LDAP_TLS_CA_CRT_FILENAME: "ca.crt"
    volumes:
      - ./certs:/container/service/slapd/assets/certs:ro
      - replica_a_db:/var/lib/ldap
      - replica_a_cfg:/etc/ldap/slapd.d
    networks: [ldapnet]

  ldap-replica-b:
    image: osixia/openldap:1.5.0
    container_name: ldap-replica-b
    hostname: ldap-replica-b
    environment:
      LDAP_ORGANISATION: "CAE Lab"
      LDAP_DOMAIN: "cae.local"
      LDAP_ADMIN_PASSWORD: "admin"
      LDAP_CONFIG_PASSWORD: "config"
      LDAP_TLS: "true"
      LDAP_TLS_CRT_FILENAME: "ldap.crt"
      LDAP_TLS_KEY_FILENAME: "ldap.key"
      LDAP_TLS_CA_CRT_FILENAME: "ca.crt"
    volumes:
      - ./certs:/container/service/slapd/assets/certs:ro
      - replica_b_db:/var/lib/ldap
      - replica_b_cfg:/etc/ldap/slapd.d
    networks: [ldapnet]

  ldap-write:
    image: haproxy:2.8
    container_name: ldap-write
    hostname: ldap-write
    volumes:
      - ./haproxy/haproxy-write.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    ports:
      - "1389:1389"
      - "1636:1636"
    networks: [ldapnet]
    depends_on:
      - ldap-master-a
      - ldap-master-b

  ldap-read:
    image: haproxy:2.8
    container_name: ldap-read
    hostname: ldap-read
    volumes:
      - ./haproxy/haproxy-read.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    ports:
      - "2389:2389"
      - "2636:2636"
    networks: [ldapnet]
    depends_on:
      - ldap-replica-a
      - ldap-replica-b

networks:
  ldapnet:

volumes:
  master_a_db:
  master_a_cfg:
  master_b_db:
  master_b_cfg:
  replica_a_db:
  replica_a_cfg:
  replica_b_db:
  replica_b_cfg:
```

The osixia image supports TLS via mounted certs and env vars as above. ([GitHub][3])

Bring it up:

```bash
docker compose up -d
docker compose ps
```

---

## 6) Bootstrap replication identity (replicator user) on BOTH masters

Create `ldif/01-replicator.ldif`:

```ldif
dn: cn=replicator,dc=cae,dc=local
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: replicator
description: Replication bind DN
userPassword: replpass
```

Apply on **master-a** (and repeat for master-b):

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

---

## 7) Assign serverIDs (required for syncrepl) on all nodes

OpenLDAP syncrepl uses **serverID** to identify nodes. ([openldap.org][1])

Create `ldif/10-serverid-master-a.ldif`:

```ldif
dn: cn=config
changetype: modify
replace: olcServerID
olcServerID: 1 ldap://ldap-master-a
```

Create `ldif/11-serverid-master-b.ldif`:

```ldif
dn: cn=config
changetype: modify
replace: olcServerID
olcServerID: 2 ldap://ldap-master-b
```

Create `ldif/12-serverid-replica-a.ldif`:

```ldif
dn: cn=config
changetype: modify
replace: olcServerID
olcServerID: 3 ldap://ldap-replica-a
```

Create `ldif/13-serverid-replica-b.ldif`:

```ldif
dn: cn=config
changetype: modify
replace: olcServerID
olcServerID: 4 ldap://ldap-replica-b
```

Apply (example for master-a):

```bash
docker exec -i ldap-master-a ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/10-serverid-master-a.ldif)
EOF
```

Repeat similarly for each node with its matching LDIF file.

---

## 8) Configure MirrorMode replication between masters (bi-directional)

MirrorMode is typically “2 masters replicate each other; clients only write to one at a time” (your write LB enforces that). 
Replication basics + MirrorMode concepts: ([openldap.org][1])

### 8.1 Enable syncprov overlay on BOTH masters

Create `ldif/20-syncprov-master.ldif`:

```ldif
dn: olcOverlay=syncprov,olcDatabase={1}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 100
```

Apply on both masters:

```bash
docker exec -i ldap-master-a ldapadd -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/20-syncprov-master.ldif)
EOF

docker exec -i ldap-master-b ldapadd -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/20-syncprov-master.ldif)
EOF
```

### 8.2 Add syncrepl statements + enable MirrorMode on BOTH masters

Create `ldif/21-mirrormode-master-a.ldif`:

```ldif
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcSyncRepl
olcSyncRepl: rid=001 provider=ldap://ldap-master-b:389 bindmethod=simple binddn="cn=replicator,dc=cae,dc=local" credentials=replpass searchbase="dc=cae,dc=local" type=refreshAndPersist retry="5 5 300 5" timeout=1
-
add: olcMirrorMode
olcMirrorMode: TRUE
```

Create `ldif/22-mirrormode-master-b.ldif`:

```ldif
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcSyncRepl
olcSyncRepl: rid=002 provider=ldap://ldap-master-a:389 bindmethod=simple binddn="cn=replicator,dc=cae,dc=local" credentials=replpass searchbase="dc=cae,dc=local" type=refreshAndPersist retry="5 5 300 5" timeout=1
-
add: olcMirrorMode
olcMirrorMode: TRUE
```

Apply:

```bash
docker exec -i ldap-master-a ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/21-mirrormode-master-a.ldif)
EOF

docker exec -i ldap-master-b ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/22-mirrormode-master-b.ldif)
EOF
```

At this point, the masters should replicate. (In production, you’d also tighten ACLs and indexes per design; the proposal explicitly calls this out. )

---

## 9) Configure replicas as read-only consumers

### 9.1 Enable syncprov on masters already done (providers)

### 9.2 Configure syncrepl on replicas (pull from master-a, failover master-b)

Create `ldif/30-replica-consumer.ldif` (same for both replicas):

```ldif
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcSyncRepl
olcSyncRepl: rid=101 provider=ldap://ldap-master-a:389 bindmethod=simple binddn="cn=replicator,dc=cae,dc=local" credentials=replpass searchbase="dc=cae,dc=local" type=refreshAndPersist retry="5 5 300 5" timeout=1
olcSyncRepl: rid=102 provider=ldap://ldap-master-b:389 bindmethod=simple binddn="cn=replicator,dc=cae,dc=local" credentials=replpass searchbase="dc=cae,dc=local" type=refreshAndPersist retry="5 5 300 5" timeout=1
-
add: olcUpdateRef
olcUpdateRef: ldap://ldap-write:1389
```

Apply to replica-a and replica-b:

```bash
docker exec -i ldap-replica-a ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/30-replica-consumer.ldif)
EOF

docker exec -i ldap-replica-b ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/30-replica-consumer.ldif)
EOF
```

### 9.3 Make replicas read-only

Create `ldif/31-replica-readonly.ldif`:

```ldif
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcReadOnly
olcReadOnly: TRUE
```

Apply:

```bash
docker exec -i ldap-replica-a ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/31-replica-readonly.ldif)
EOF

docker exec -i ldap-replica-b ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
$(cat ldif/31-replica-readonly.ldif)
EOF
```

---

## 10) (Optional but aligned) Delta-syncrepl via accesslog

Your proposal explicitly mentions **delta-syncrepl** and **accesslog** overlay. 
Delta-syncrepl is documented as using accesslog for “delta” synchronization. ([kb.symas.com][2])

In a lab, you can keep the “standard refreshAndPersist” above (it works), and then your expert agent can:

* Add an **accesslog database** on masters
* Enable **accesslog overlay** on the main database
* Switch `olcSyncRepl` entries to `logbase=...` / `syncdata=accesslog`

(If you want, I can provide the exact LDIF set for accesslog + delta tuning, but the above gets you running first.)

---

## 11) Validate: write via WRITE VIP, read via READ VIP

### 11.1 Basic “whoami” test through VIPs

```bash
# LDAP (startTLS optional). Here we do plain LDAP for simplicity:
ldapwhoami -x -H ldap://localhost:1389 -D "cn=admin,dc=cae,dc=local" -w admin
ldapwhoami -x -H ldap://localhost:2389 -D "cn=admin,dc=cae,dc=local" -w admin
```

### 11.2 Add a test user through WRITE VIP

Create `ldif/90-test-user.ldif`:

```ldif
dn: uid=testuser,dc=cae,dc=local
objectClass: inetOrgPerson
cn: testuser
sn: user
uid: testuser
userPassword: Test1234!
```

Add it:

```bash
ldapadd -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=cae,dc=local" -w admin \
  -f ldif/90-test-user.ldif
```

Read it via READ VIP (should be served by replicas):

```bash
ldapsearch -x -H ldap://localhost:2389 \
  -D "cn=admin,dc=cae,dc=local" -w admin \
  -b "dc=cae,dc=local" "(uid=testuser)"
```

### 11.3 Failover test (write LB should switch to master-b)

```bash
docker stop ldap-master-a
# now try an LDAP modify via write VIP; it should still work (master-b)
ldapmodify -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=cae,dc=local" -w admin <<'EOF'
dn: uid=testuser,dc=cae,dc=local
changetype: modify
replace: sn
sn: user2
EOF
```

Bring master-a back:

```bash
docker start ldap-master-a
```

This mirrors the proposal’s intent: one active writer, standby can be promoted quickly, and the LB provides seamless endpoint continuity. 

---

## 12) Where this maps to your proposal (and what’s left for “production”)

Already covered in this lab:

* **2 masters + MirrorMode concept + replication**  ([openldap.org][1])
* **2 read replicas + read-only enforcement** 
* **2 load balancers** (read vs write VIP) 
* **TLS** with shared cert across all nodes (a typical approach when using a VIP)  ([GitHub][3])

Typically added next (for your expert agent):

* Tight **ACL model** (least privilege) and **service accounts per application** 
* **Password policy (ppolicy)** and **lastbind** overlays (requires schema + overlay config) 
* **accesslog + delta-syncrepl** (optimization)  ([kb.symas.com][2])
* Monitoring, backups (`slapcat` / `mdb_copy`), and DR mechanics (proposal uses bank VM replication for DR). 

---

If you want, paste your preferred **base DN** and **naming** (e.g., `dc=creditagricole,dc=local` and your target DIT like `ou=people,ou=customers,...`) and I’ll adapt the LDIFs and Compose variables to that exact structure—still in the same step-by-step format, ready for your code agent to implement.

[1]: https://www.openldap.org/doc/admin24/replication.html?utm_source=chatgpt.com "OpenLDAP Software 2.4 Administrator's Guide: Replication"
[2]: https://kb.symas.com/configuration/configure-delta-syncrepl?utm_source=chatgpt.com "Configure Delta-Syncrepl - Symas"
[3]: https://github.com/osixia/docker-openldap "GitHub - osixia/docker-openldap: OpenLDAP container image "
[4]: https://www.port389.org/docs/389ds/howto/howto-test-haproxy-ldaps.html?utm_source=chatgpt.com "Testing HAProxy with 389 DS over LDAP/LDAPS"
