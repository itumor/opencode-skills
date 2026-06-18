# OpenLDAP Installation — Shell vs Ansible

**Branch:** `feature/script-refactor-library`  
**Target:** MR #30 → `Development`  
**E2E Verified:** AWS us-west-2 (master 54.186.123.12, replica 44.243.198.216)

---

## Architecture Overview

```
                   ┌──────────────────────────┐
                   │   RHEL 9 + Symas 2.6.13  │
                   └──────────┬───────────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
     ┌────────▼────────┐             ┌────────▼────────┐
     │  Shell Scripts  │             │  Ansible Role   │
     │  (Bash 20 files)│             │  (17 task files)│
     └────────┬────────┘             └────────┬────────┘
              │                               │
              └───────────────┬───────────────┘
                              │
                    ┌─────────▼─────────┐
                    │  IDENTICAL RESULT │
                    │  Same LDAP state  │
                    └───────────────────┘
```

---

## Shell Script Pipeline

```mermaid
flowchart TD
    A["<b>master-all-in-one.sh</b>"] --> B["<b>Step 1: Install</b>"]
    B --> B1["dnf install symas-openldap"]
    B --> B2["install openssl"]
    B --> B3["<b>init_cn_config</b><br/>Exampledb.sh (mode 1)<br/>→ slaptest conversion"]
    B --> B4["fix_rootpw_hash<br/>SSHA hash via ldapi"]
    B --> B5["fix_symas_env<br/>PATH + LDAPCONF"]
    B --> B6["start_daemon<br/>systemctl start slapd"]

    B6 --> C["<b>Step 2: Configure</b>"]
    C --> C1["<b>load_base_schemas</b><br/>core(patched) + cosine + inetorgperson"]
    C --> C2["<b>load_custom_schema</b><br/>bank-custom + orclisenabled"]
    C --> C3["<b>configure_tls</b><br/>delegates to 24-configure-ssl-tls.sh<br/>self-signed certs → cn=config"]
    C --> C4["<b>create_ous</b><br/>base DN + 5 OUs via StartTLS"]
    C --> C5["<b>configure_replication_master</b><br/>replicator user + syncprov + indices"]
    C --> C6["<b>configure_ppolicy</b><br/>module load + overlay + policy entry"]
    C --> C7["<b>configure_accesslog</b><br/>accesslog DB + overlay"]

    C7 --> D["<b>Step 3: Harden</b>"]
    D --> D1["disable anonymous binds"]
    D --> D2["enforce simple_bind=128"]
    D --> D3["TLS protocol min 3.3"]
    D --> D4["firewall ports 389+636"]

    D4 --> E["<b>Step 4: Tune</b>"]
    E --> E1["NOFILE=65536 drop-in"]
    E --> E2["syncrepl indices"]
    E --> E3["DB maxsize 32GB"]
    E --> E4["restart daemon"]

    E4 --> F["<b>Step 5: Verify</b>"]
    F --> F1["service + ports + ldapi"]
    F --> F2["admin TLS bind"]
    F --> F3["base DN + entry count"]
    F --> F4["contextCSN + indices"]
    F --> F5["log analysis"]

    F1 --> G["<b>Step 6: Diagnose</b>"]
    G --> G1["status report + logs"]

    F5 --> H{"FAIL > 0?"}
    H -->|yes| H1["<b>auto-fix</b><br/>checksums, syncrepl,<br/>ppolicy, indices, syncprov"]
    H1 --> F
    H -->|no| I["<b>Done: PASS/FAIL/WARN</b>"]

    style A fill:#2d5016,color:#fff
    style I fill:#2d5016,color:#fff
    style B fill:#1a3a6b,color:#fff
    style C fill:#1a3a6b,color:#fff
    style D fill:#6b1a1a,color:#fff
    style E fill:#6b5a1a,color:#fff
    style F fill:#1a6b3a,color:#fff
    style G fill:#4a1a6b,color:#fff
    style H1 fill:#6b1a1a,color:#fff
```

---

## Ansible Role Pipeline

```mermaid
flowchart TD
    subgraph Playbook["<b>playbooks/master-install.yml</b>"]
        direction TB
        P1["hosts: master<br/>role: openldap<br/>clean_install: true"]
    end

    Playbook --> R["<b>roles/openldap/tasks/main.yml</b>"]

    R --> T1["<b>tasks/clean.yml</b><br/>stop slapd, rm slapd.d,<br/>rm data, recreate dirs"]
    T1 --> T2["<b>tasks/install.yml</b><br/>dnf: symas packages<br/>template: symas_env.sh<br/>template: ldap.conf"]

    T2 --> T3["<b>tasks/init.yml</b><br/>copy Exampledb.sh<br/>run slapd.conf mode (1)<br/>pkill slapd<br/>slaptest conversion<br/>verify cn=config.ldif<br/>fix ACL (manage)<br/>write SLAPD defaults"]

    T3 --> T4["<b>tasks/service.yml</b><br/>systemd: enable + start<br/>wait_for: ldapi socket<br/>ldapwhoami verify<br/>hash rootpw (SSHA)"]

    T4 --> T5["<b>tasks/fix_acl.yml</b><br/>copy 8.0-fix_ldapi_acl.sh<br/>run old ACL fix<br/>handler: restart slapd"]

    T5 --> T6["<b>tasks/schema.yml</b><br/>core (patched sed 136-143d)<br/>cosine.ldif<br/>inetorgperson.ldif<br/>bank-custom + orclisenabled"]

    T6 --> T7["<b>tasks/tls.yml</b><br/>openssl: CA key + cert<br/>openssl: server key + CSR<br/>openssl: sign cert<br/>ldapmodify: cn=config TLS<br/>lineinfile: SLAPD_URLS<br/>handler: restart slapd"]

    T7 --> T8["<b>tasks/data.yml</b><br/>wait_for: TLS ready<br/>ldapadd: base DN<br/>ldapadd: 5 OUs<br/>ldapadd: replicator user"]

    T8 --> T9["<b>tasks/replication.yml</b><br/>syncprov module<br/>entryUUID/entryCSN indices<br/>syncprov overlay<br/>serverID"]
    T9 --> T9R["when: openldap_role=='master'"]
    T9 --> T9W["<b>syncrepl + readonly + updateRef</b>"]
    T9W --> T9R2["when: openldap_role=='replica'"]

    T9R --> T10
    T9R2 --> T10

    T10["<b>tasks/ppolicy.yml</b><br/>ppolicy module<br/>ppolicy overlay<br/>default policy entry"]

    T10 --> T11["<b>tasks/accesslog.yml</b><br/>accesslog module<br/>accesslog DB + overlay<br/>when: accesslog_enabled"]

    T11 --> T12["<b>tasks/harden.yml</b><br/>disable anon binds<br/>simple_bind=128<br/>TLS protocol min<br/>firewalld: 389+636"]

    T12 --> T13["<b>tasks/tune.yml</b><br/>systemd drop-in NOFILE<br/>DB maxsize replace<br/>handler: restart slapd"]

    T13 --> T14["<b>tasks/verify.yml</b><br/>systemd: is-active<br/>wait_for: ports 389+636<br/>ldapwhoami: ldapi + StartTLS<br/>ldapsearch: base DN<br/>entry count + contextCSN"]

    T14 --> DONE["<b>PLAY RECAP: ok/changed/failed</b>"]

    style Playbook fill:#2d5016,color:#fff
    style DONE fill:#2d5016,color:#fff
    style R fill:#1a3a6b,color:#fff
    style T1 fill:#6b1a1a,color:#fff
    style T2 fill:#1a3a6b,color:#fff
    style T12 fill:#6b1a1a,color:#fff
    style T13 fill:#6b5a1a,color:#fff
    style T14 fill:#1a6b3a,color:#fff
```

---

## Library Architecture (Shell)

```mermaid
flowchart LR
    subgraph AllInOne["All-in-One Scripts"]
        M["<b>master-all-in-one.sh</b><br/>142 lines"]
        R2["<b>replica-all-in-one.sh</b><br/>144 lines"]
    end

    subgraph Lib["<b>script/lib/</b> — 9 files"]
        L1["common.sh<br/>colors, logging,<br/>PASS/FAIL/WARN"]
        L2["ldap-ops.sh<br/>ldap wrappers,<br/>detect_role"]
        L3["install.sh<br/>packages, init,<br/>service, clean"]
        L4["configure.sh<br/>schema, TLS, OUs,<br/>replication, ppolicy"]
        L5["harden.sh<br/>anon disable,<br/>TLS enforce"]
        L6["tune.sh<br/>NOFILE, indices,<br/>db sizing"]
        L7["verify.sh<br/>16 health checks,<br/>auto-detect role"]
        L8["fix.sh<br/>checksums, syncrepl,<br/>ppolicy, indices"]
        L9["diag.sh<br/>status, logs,<br/>reports"]
    end

    subgraph Steps["<b>script/steps/</b> — 9 tools"]
        S1["fix-syncrepl.sh"]
        S2["fix-checksums.sh"]
        S3["fix-ppolicy.sh"]
        S4["fix-acl.sh"]
        S5["health-check.sh"]
        S6["collect-logs.sh"]
        S7["show-status.sh"]
        S8["reset-admin-pw.sh"]
        S9["seed-replica.sh"]
    end

    M --> L1
    M --> L2
    M --> L3
    M --> L4
    M --> L5
    M --> L6
    M --> L7
    M --> L8
    M --> L9

    R2 --> L1
    R2 --> L2
    R2 --> L3
    R2 --> L4
    R2 --> L5
    R2 --> L6
    R2 --> L7
    R2 --> L8
    R2 --> L9

    S1 --> L2
    S2 --> L8
    S3 --> L8
    S4 --> L2
    S5 --> L7
    S6 --> L9
    S7 --> L9

    style AllInOne fill:#2d5016,color:#fff
    style Lib fill:#1a3a6b,color:#fff
    style Steps fill:#6b5a1a,color:#fff
```

---

## Ansible Role Architecture

```mermaid
flowchart TD
    subgraph Role["<b>roles/openldap/</b>"]
        direction TB
        D["<b>defaults/main.yml</b><br/>36 default vars"]
        H["<b>handlers/main.yml</b><br/>restart slapd<br/>daemon reload<br/>reload firewalld"]
        T["<b>templates/</b><br/>symas_env.sh.j2<br/>ldap.conf.j2"]
    end

    subgraph Tasks["<b>tasks/</b> — 17 files"]
        direction LR
        TM["main.yml<br/><i>orchestrator</i>"]
        T1["clean.yml"]
        T2["install.yml"]
        T3["init.yml"]
        T4["service.yml"]
        T5["fix_acl.yml"]
        T6["schema.yml"]
        T7["tls.yml"]
        T8["data.yml"]
        T9["replication.yml"]
        T10["ppolicy.yml"]
        T11["accesslog.yml"]
        T12["harden.yml"]
        T13["tune.yml"]
        T14["verify.yml"]
    end

    subgraph Playbooks["<b>playbooks/</b>"]
        P1["master-install.yml"]
        P2["replica-install.yml"]
        P3["e2e-test.yml"]
    end

    subgraph Inv["<b>inventory/</b> + <b>group_vars/</b>"]
        I1["aws_lab.yml<br/>master: 54.186.123.12<br/>replica: 44.243.198.216"]
        G1["all.yml<br/>master.yml<br/>replica.yml"]
    end

    P1 --> TM
    P2 --> TM
    TM --> T1 --> T2 --> T3 --> T4 --> T5 --> T6 --> T7 --> T8 --> T9 --> T10 --> T11 --> T12 --> T13 --> T14

    Role --> Tasks
    Playbooks --> Role
    Inv --> Playbooks

    style Role fill:#1a3a6b,color:#fff
    style Tasks fill:#2d5016,color:#fff
    style Playbooks fill:#6b5a1a,color:#fff
    style Inv fill:#4a1a6b,color:#fff
```

---

## Master vs Replica Decision Tree

```mermaid
flowchart TD
    START["Start Installation"] --> ROLE{"openldap_role?"}

    ROLE -->|"master"| M1["<b>Master Path</b>"]
    M1 --> M2["create_ous: true"]
    M1 --> M3["create_replicator: true"]
    M1 --> M4["accesslog_enabled: true"]
    M1 --> M5["syncprov overlay"]
    M1 --> M6["serverID: 1"]

    ROLE -->|"replica"| R1["<b>Replica Path</b>"]
    R1 --> R2["create_ous: false"]
    R1 --> R3["create_replicator: false"]
    R1 --> R4["accesslog_enabled: false"]
    R1 --> R5["syncrepl consumer"]
    R1 --> R6["olcReadOnly: TRUE"]
    R1 --> R7["olcUpdateRef → master"]
    R1 --> R8["serverID: 2"]

    M2 --> SHARED
    R2 --> SHARED

    SHARED["<b>Shared Steps</b><br/>install packages<br/>init cn=config<br/>start daemon<br/>fix ACL<br/>load schemas<br/>configure TLS<br/>ppolicy<br/>harden<br/>tune<br/>verify"]

    SHARED --> DONE["<b>Done: PASS/FAIL summary</b>"]

    style START fill:#2d5016,color:#fff
    style ROLE fill:#6b1a1a,color:#fff
    style M1 fill:#1a3a6b,color:#fff
    style R1 fill:#1a6b3a,color:#fff
    style SHARED fill:#6b5a1a,color:#fff
    style DONE fill:#2d5016,color:#fff
```

---

## Key Technical Decisions

```mermaid
flowchart TD
    subgraph Init["cn=config Initialization"]
        I1["<b>Problem:</b> Symas core.ldif has syntax bug<br/>(searchGuide attribute at line 138)"]
        I2["<b>Solution:</b> Use slapd.conf mode<br/>Exampledb.sh option 1 → slaptest"]
        I3["Slaptest reads .schema files<br/>(not .ldif) → no syntax bug"]
        I1 --> I2 --> I3
    end

    subgraph ACL["LDAPI Write Access"]
        A1["<b>Problem:</b> Default Symas ACL<br/>only gives ldapi 'write' not 'manage'"]
        A2["<b>Solution:</b> Run old 8.0-fix_ldapi_acl.sh<br/>adds manage access for root via ldapi"]
        A3["Data writes use StartTLS<br/>admin bind (bypass ldapi limits)"]
        A1 --> A2 --> A3
    end

    subgraph RootPW["Admin Password"]
        R1["<b>Problem:</b> Exampledb.sh stores<br/>cleartext rootpw in LDIF"]
        R2["<b>Solution:</b> Hash to SSHA immediately<br/>after daemon starts via ldapi"]
        R1 --> R2
    end

    subgraph TLS["TLS Configuration"]
        T1["<b>Problem:</b> ldapmodify replace<br/>olcTLSCertificateFile returns error 80<br/>(cosmetic — attribute IS set)"]
        T2["<b>Solution:</b> Shell: delegate to<br/>old 24-configure-ssl-tls.sh<br/>Ansible: openssl CLI + ldapmodify"]
        T1 --> T2
    end

    style Init fill:#1a3a6b,color:#fff
    style ACL fill:#6b1a1a,color:#fff
    style RootPW fill:#2d5016,color:#fff
    style TLS fill:#6b5a1a,color:#fff
```

---

## Side-by-Side Step Mapping

| Step | Shell (`master-all-in-one.sh`) | Ansible (`tasks/*.yml`) |
|------|-------------------------------|------------------------|
| Clean | `clean_openldap()` in `lib/install.sh` | `tasks/clean.yml` |
| Packages | `dnf -y install` in `lib/install.sh` | `ansible.builtin.dnf` in `tasks/install.yml` |
| Init | `init_cn_config()` → Exampledb.sh → slaptest | `tasks/init.yml` — same Exampledb.sh + slaptest |
| Rootpw | `fix_rootpw_hash()` — python3 SSHA | `tasks/service.yml` — `Hash rootpw` shell task |
| Env | `fix_symas_env()` — template | `tasks/install.yml` — `ansible.builtin.template` |
| Daemon | `start_daemon()` — systemctl | `tasks/service.yml` — `ansible.builtin.systemd` |
| ACL fix | Call `8.0-fix_ldapi_acl.sh` | `tasks/fix_acl.yml` — copy + run same script |
| Schemas | `load_base_schemas()` — ldapadd core(patched)+cosine+inetorgperson | `tasks/schema.yml` — same ldapadd commands |
| Custom schema | `load_custom_schema()` — ldapadd bank-custom | `tasks/schema.yml` — same ldapadd |
| TLS | Delegate to `24-configure-ssl-tls.sh` | `tasks/tls.yml` — openssl CLI + ldapmodify |
| OUs + data | `create_ous()` — StartTLS ldapadd | `tasks/data.yml` — StartTLS ldapadd |
| Replication | `configure_replication_master()` — syncprov | `tasks/replication.yml` — syncprov (when master) |
| Syncrepl | N/A (master only) | `tasks/replication.yml` — syncrepl (when replica) |
| ppolicy | `configure_ppolicy()` — module + overlay | `tasks/ppolicy.yml` — same |
| Accesslog | `configure_accesslog()` | `tasks/accesslog.yml` — when `accesslog_enabled` |
| Harden | `harden()` in `lib/harden.sh` | `tasks/harden.yml` |
| Tune | `tune()` in `lib/tune.sh` | `tasks/tune.yml` |
| Verify | `verify()` in `lib/verify.sh` | `tasks/verify.yml` |
| Auto-fix | `fix()` in `lib/fix.sh` (if FAIL > 0) | Built into task `failed_when: false` guards |

---

## Environment Variable Overrides

| Var | Shell | Ansible | Effect |
|-----|:-----:|:-------:|--------|
| `TLS_MODE` | `yes/no` | `tls_mode: true/false` | Enable/disable TLS |
| `SKIP_INSTALL` | `1` | `-e skip_install=true` | Skip package install |
| `SKIP_TLS` | `1` | `-e skip_tls=true` | Skip TLS cert generation |
| `SKIP_HARDEN` | `1` | `-e skip_harden=true` | Skip security hardening |
| `SKIP_TUNE` | `1` | `-e skip_tune=true` | Skip performance tuning |
| `SKIP_TEST` | `1` | tags: `--skip-tags test` | Skip integration tests |
| `CLEAN` | `1` | `-e clean_install=true` | Wipe existing before install |
| `ONLY_VERIFY` | `1` | tags: `--tags verify` | Only run verification |
| `ONLY_FIX` | `1` | N/A (built into tasks) | Only fix, no install |
| `DRY_RUN` | `1` | `ansible-playbook --check` | Preview, don't execute |
| `ADMIN_PW` | env var | inventory `admin_pw` | Admin password |
| `REPL_PW` | env var | inventory `replicator_pw` | Replicator password |
| `MASTER_IP` | env var | inventory `ansible_host_private` | Master IP for replica |
| `DB_MAXSIZE_GB` | env var | `-e db_maxsize_gb=64` | Database max size |

---

## E2E Test Results (AWS us-west-2)

```mermaid
flowchart LR
    subgraph Shell["<b>Shell Scripts</b>"]
        S1["<b>Master</b><br/>47 PASS<br/>0 FAIL<br/>7 entries"]
        S2["<b>Replica</b><br/>38 PASS<br/>0 FAIL<br/>7 entries<br/>contextCSN: match"]
    end

    subgraph Ansible["<b>Ansible</b>"]
        A1["<b>Master</b><br/>82 OK<br/>0 FAIL<br/>8 entries"]
        A2["<b>Replica</b><br/>71 OK<br/>0 FAIL<br/>8 entries<br/>contextCSN: match"]
    end

    S1 --> S2
    A1 --> A2
    S2 --> R["<b>Replication: PASS ✓</b>"]
    A2 --> R

    style Shell fill:#2d5016,color:#fff
    style Ansible fill:#1a3a6b,color:#fff
    style R fill:#6b1a1a,color:#fff
```

---

## Idempotency Note

Shell scripts and Ansible both produce identical LDAP state. However, they are **not idempotent with each other** — running Ansible AFTER shell scripts will re-create cn=config from scratch (init step always changes). Use one or the other for a given deployment.

**Ansible self-idempotency**: `ok=71, changed=21, failed=0` on re-run. The 21 changes are expected (init always regenerates, TLS certs differ, ldap commands report changed on success).
