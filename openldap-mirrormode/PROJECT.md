# OpenLDAP MirrorMode Lab - Project Overview

This project provides a local, Docker Compose-based OpenLDAP lab with:

- 2 OpenLDAP masters in MirrorMode (active/active for writes)
- 2 read-only replicas (syncrepl consumers)
- 2 HAProxy VIPs for read/write separation
- TLS-enabled LDAP endpoints
- LDIFs and scripts to configure replication

## Services

- `ldap-master-a` / `ldap-master-b`: OpenLDAP masters in MirrorMode
- `ldap-replica-a` / `ldap-replica-b`: OpenLDAP read-only replicas
- `ldap-write`: HAProxy for read/write traffic (ports 1389/1636)
- `ldap-read`: HAProxy for read-only traffic (ports 2389/2636)

## Network and Ports

All services are attached to the `ldapnet` Docker network.

- Write VIP: `ldap://localhost:1389` (LDAP), `ldaps://localhost:1636` (LDAPS)
- Read VIP: `ldap://localhost:2389` (LDAP), `ldaps://localhost:2636` (LDAPS)

## Replication Summary

- MirrorMode keeps both masters in sync (bi-directional).
- Replicas are configured as read-only consumers using syncrepl from both masters.
- LDIFs under `ldif/` configure the replicator user, ACLs, server IDs, syncprov, MirrorMode, and replica consumers.

## Infrastructure Architecture (Mermaid)

```mermaid
flowchart LR
  client([LDAP Clients])

  subgraph host[Docker Compose Host]
    subgraph net[ldapnet Bridge Network]
      subgraph vip[HAProxy VIPs]
        rw[ldap-write\nVIP RW :1389/:1636]
        ro[ldap-read\nVIP RO :2389/:2636]
      end

      subgraph masters["LDAP Masters (MirrorMode)"]
        mA[ldap-master-a]
        mB[ldap-master-b]
      end

      subgraph replicas["LDAP Replicas (Read-only)"]
        rA[ldap-replica-a]
        rB[ldap-replica-b]
      end
    end

    subgraph storage[Docker Volumes]
      mA_db[(master_a_db)]
      mA_cfg[(master_a_cfg)]
      mB_db[(master_b_db)]
      mB_cfg[(master_b_cfg)]
      rA_db[(replica_a_db)]
      rA_cfg[(replica_a_cfg)]
      rB_db[(replica_b_db)]
      rB_cfg[(replica_b_cfg)]
      certs[(./certs TLS)]
    end
  end

  client --> rw
  client --> ro

  rw --> mA
  rw --> mB
  ro --> rA
  ro --> rB

  mA <--> |MirrorMode| mB
  mA -.-> |syncrepl| rA
  mA -.-> |syncrepl| rB
  mB -.-> |syncrepl| rA
  mB -.-> |syncrepl| rB

  mA --- mA_db
  mA --- mA_cfg
  mB --- mB_db
  mB --- mB_cfg
  rA --- rA_db
  rA --- rA_cfg
  rB --- rB_db
  rB --- rB_cfg
  mA --- certs
  mB --- certs
  rA --- certs
  rB --- certs
```

## Architecture Diagram (Mermaid)

```mermaid
flowchart LR
  user([LDAP Clients])

  subgraph host[Docker Compose Host]
    subgraph vip[HAProxy VIPs]
      rw[ldap-write\nVIP RW :1389/:1636]
      ro[ldap-read\nVIP RO :2389/:2636]
    end

    subgraph masters["LDAP Masters (MirrorMode)"]
      mA[ldap-master-a]
      mB[ldap-master-b]
    end

    subgraph replicas["LDAP Replicas (Read-only)"]
      rA[ldap-replica-a]
      rB[ldap-replica-b]
    end
  end

  user --> rw
  user --> ro

  rw --> mA
  rw --> mB

  ro --> rA
  ro --> rB

  mA <--> |MirrorMode| mB

  mA -.-> |syncrepl| rA
  mA -.-> |syncrepl| rB
  mB -.-> |syncrepl| rA
  mB -.-> |syncrepl| rB
```

## Replication Setup Flow (Mermaid)

```mermaid
sequenceDiagram
  autonumber
  participant Admin as Admin/Scripts
  participant MA as ldap-master-a
  participant MB as ldap-master-b
  participant RA as ldap-replica-a
  participant RB as ldap-replica-b

  Admin->>MA: Add replicator user (ldif/01-replicator.ldif)
  Admin->>MB: Add replicator user (ldif/01-replicator.ldif)

  Admin->>MA: Apply replicator ACL (ldif/02-replicator-acl.ldif)
  Admin->>MB: Apply replicator ACL (ldif/02-replicator-acl.ldif)

  Admin->>MA: Set server ID (ldif/10-serverid-master-a.ldif)
  Admin->>MB: Set server ID (ldif/11-serverid-master-b.ldif)
  Admin->>RA: Set server ID (ldif/12-serverid-replica-a.ldif)
  Admin->>RB: Set server ID (ldif/13-serverid-replica-b.ldif)

  Admin->>MA: Enable syncprov (ldif/19-load-syncprov.ldif)
  Admin->>MB: Enable syncprov (ldif/19-load-syncprov.ldif)
  Admin->>MA: Configure syncprov (ldif/20-syncprov-master.ldif)
  Admin->>MB: Configure syncprov (ldif/20-syncprov-master.ldif)

  Admin->>MA: Enable MirrorMode (ldif/21-mirrormode-master-a.ldif)
  Admin->>MB: Enable MirrorMode (ldif/22-mirrormode-master-b.ldif)

  Admin->>RA: Configure consumer (ldif/30-replica-consumer.ldif)
  Admin->>RB: Configure consumer (ldif/30-replica-consumer.ldif)
  Admin->>RA: Set read-only (ldif/31-replica-readonly.ldif)
  Admin->>RB: Set read-only (ldif/31-replica-readonly.ldif)
```

## How to Run (Quick)

```bash
./scripts/gen-certs.sh
docker compose up -d
./scripts/apply-replication-ldifs.sh
```

## Notes

- Base DN: `dc=cae,dc=local`
- Admin DN: `cn=admin,dc=cae,dc=local`
- Default passwords: `admin` (admin) and `config` (cn=config)

## Alternative VIP (Keepalived)

For environments that prefer a single floating VIP instead of HAProxy, see
`openldap-mirrormode/keepalived/` for example Keepalived configs and
`scripts/test-keepalived-failover.sh` for a VIP failover test.
