**Solution Design Document**

**Technical Solution Design: OpenLDAP cn=config Implementation**

---

### 1. Document Purpose & Scope
1.1 **Objective**  
Define the enterprise-grade OpenLDAP deployment based on cn=config dynamic configuration, ensuring secure, scalable directory services across DEV/QA/PROD environments with consistent management, auditing, and automated change control.

1.2 **Scope**  
**In-scope:**  
- Design of cn=config-based OpenLDAP instances with MDB backend  
- Schema, module, overlay, and ACL planning  
- Replication, TLS, authentication, and password policy definition  
- Configuration management processes (LDIF, version control) and change lifecycle  
- Deployment, testing, migration, and operational runbooks for Linux servers  

**Out-of-scope:**  
- Application-level LDAP integration (application code changes)  
- Detailed non-LDAP identity provider integrations (e.g., Active Directory federation)  
- Storage/network infrastructure procurement  

---

### 2. Current State Overview
2.1 **Existing Directory Services**  
Assumes limited or legacy static slapd.conf-based OpenLDAP deployments with minimal automation. Existing directories may lack dynamic configuration, consistent schema versioning, and centralized change control.

2.2 **Limitations of Static slapd.conf**  
- Manual restarts required for all configuration changes; introduces downtime.  
- Configuration files shared across hosts through error-prone scripting.  
- Difficult to audit and roll back; no transactional change history.  
- Limited ability to modularize configuration per environment.  

---

### 3. Target Architecture
3.1 **High-level Architecture Description**  
Each environment (DEV/QA/PROD) hosts an OpenLDAP cluster of at least two nodes (primary and secondary). Servers run Linux (RHEL/CentOS/Ubuntu), store configuration in cn=config, and persist data via MDB. Replication uses syncrepl (mirror mode). TLS terminates on OpenLDAP with certificates issued by internal PKI (intermediate CA). Configuration stored as LDIF in Git for auditability.

3.2 **OpenLDAP Components & Interactions**  
- **slapd** daemon with cn=config backend and MDB data backend.  
- **syncrepl/mirror mode** for replication.  
- **Accesslog overlay** for audit trails.  
- **ppolicy overlay** for password policies.  
- **schema files** loaded into cn=config for core/cosine/inetOrgPerson + custom extensions.  
- **Clients/applications** connect over LDAPS/StartTLS with credentials managed via service accounts in directory.

3.3 **cn=config Architecture Overview**  
- cn=config stored as LDIF files under /etc/openldap/slapd.d; each entry (olcDatabase, olcOverlay) editable via ldapmodify (ldif).  
- Dynamic configuration allows modularization per database and simplified distribution by exporting LDIF snapshots.

3.4 **Environments**  
- **DEV:** single replica cluster for early validation.  
- **QA:** multi-node cluster with production-like data subsets and workload.  
- **PROD:** geographically redundant pair/triplet of servers, multi-site replication, high availability.

---

### 4. Design Principles & Decisions
4.1 **cn=config Justification**  
- Enables dynamic updates without service restart.  
- Hosts configuration as LDAP entries, aligning with directory paradigm for toolkits (ldapmodify).  
- Facilitates centralized change management via LDIF.

4.2 **Principles**  
- **Security:** enforce TLS, strong ACLs, and encrypted replication.  
- **Scalability:** MDB backend for high throughput; modular overlays to selectively enable features.  
- **Availability:** multi-node replication, health checks, graceful failover.  
- **Maintainability:** version-controlled LDIF, automation to apportion changes, documentation for schema and ACLs.

4.3 **Trade-offs/Rejections**   
- **slapd.conf static model** rejected due to downtime and manual change risk.  
- **Other directory products (389/ds)** evaluated but OpenLDAP selected for lighter footprint, simplicity, and existing expertise.  
- **SQL-backed directories** dismissed because LDAP is required.

---

### 5. OpenLDAP Configuration Design
5.1 **cn=config Structure**  
- Root entry: `cn=config`.  
- Database entry example: `olcDatabase={1}mdb,cn=config`.  
- Components: schema, overlays, database definitions, backend parameters.  
- Each entry carries `olcAccess`, `olcAttributeOptions`, `olcDbDirectory`, etc.

5.2 **Database Backend**  
- MDB selected for stability and high performance.  
- Config parameters: `olcDbMaxSize`, `olcDbCheckpoint`, `olcDbCacheSize`, `olcDbFlags`.  
- Data stored per environment; separate directories for DEV/QA/PROD.

5.3 **Configuration Management**  
- LDIF snapshots stored in Git (private repo).  
- Changes authored as LDIF fragments; code review ensures ACL/schema validation.  
- Delivery pipeline: commit -> CI validation (`slapadd -n0`).  
- Promotion to environments via automation (Ansible/Chef/Puppet).

5.4 **Change Lifecycle**  
1. Author LDIF change (schema/ACL/overlay).  
2. Validate offline using `slaptest` + `ldapmodify -n`.  
3. Merge and promote through DEV/QA/PROD.  
4. Apply using ldapmodify (live) via automation.  
5. Snapshot and tag configuration version.

---

### 6. Modules, Overlays, and Features

6.1 **Required Modules (Current Project Baseline)**  
- `back_mdb`: MDB backend (primary data store).  
- `syncprov`: replication provider for MirrorMode and delta sync (`openldap-mirrormode/ldif/19-load-syncprov.ldif`).  
- `ppolicy`: password policy overlay (`script/9-password_policy.sh`).  
- `ppm`: password quality check module used by ppolicy (`script/16-add-strong-password-quality-checker-PPM.sh`).  
- `accesslog`: audit logging overlay for admin/system/user events (`script/25-configure-accesslog-audit.sh`).  
- `back_monitor` (optional): diagnostic monitoring (`cn=Monitor` queries).  

6.2 **Overlays (Load Order)**  
1. `syncprov`: required for replication and MirrorMode consistency.  
2. `ppolicy`: required for password policy enforcement and compliance.  
3. `accesslog`: required for audit trail (admin, system, and user operations).  
4. `memberof` (deferred): not part of current baseline, enable only if business logic requires reverse membership attributes.  
5. `rwm` (deferred): not part of current baseline, enable only for protocol translation/remap requirements.  

6.3 **Configuration Example**  
```ldif
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: syncprov
olcModuleLoad: ppolicy
olcModuleLoad: ppm
olcModuleLoad: accesslog
```

6.4 **Justification**  
- `syncprov` ensures consistency for syncrepl consumers and enables MirrorMode.  
- `ppolicy` + `ppm` enforce password hygiene and strong password quality rules.  
- `accesslog` provides comprehensive audit trails for compliance and troubleshooting.  
- `memberof` and `rwm` remain explicitly out of the current implementation baseline to avoid unnecessary runtime complexity.

---

### 7. Schema Design

7.1 **Standard Schemas**  
- Load default: `core.schema`, `cosine.schema`, `inetorgperson.schema`, `nis.schema` for POSIX attributes.  
- `collective.schema` only if group policy requirements explicitly need it.  

7.2 **Custom Schema Approach (Project-Aligned)**  
- Use the implemented schema container name: `bank-custom` (`script/12-Create_custom_schema.sh`).  
- Implemented custom attributes: `userisactive`, `memorableAnswer`, `memorableQuestion`, `activationdatetime`, `cif` (`script/13-Create_custom_schema_attr.sh`).  
- Implemented custom object class: `bankUserExtension` (`script/13-Create_custom_schema_attr.sh`).  
- Validate with `slaptest` and automated tests before promotion (`script/test/test_custom_schema_attr.sh`).  

7.3 **Naming Conventions**  
- **Schema name**: `bank-custom`.  
- **Object class**: `bankUserExtension`.  
- **Custom attributes**: `userisactive`, `memorableAnswer`, `memorableQuestion`, `activationdatetime`, `cif`.  
- **OID root**: current implementation uses `1.3.6.1.4.1.55555` (non-prod/lab default), replace with enterprise-assigned PEN before production.  

7.4 **Load Order in cn=config**  
1. Core schemas: `core`, `cosine`, `inetorgperson`, `nis`  
2. Project custom schema: `bank-custom`  
3. Overlays/modules: `syncprov`, `ppolicy`, `ppm`, `accesslog`  

7.5 **AttributeTypes/ObjectClasses Format**  
- Include REQUIRED/MUST and OPTIONAL/MAY clauses.  
- Use explicit syntaxes from the implementation (Boolean, Directory String, Generalized Time).  
- Keep attribute/objectClass names and OIDs synchronized with migration mapping documents.  

7.6 **OID Management (Project Decision)**  

**Decision**: OID management is **in scope** for this project because custom attributes/objectClass are implemented and required for migration compatibility.

- **Current implementation**: uses temporary root `1.3.6.1.4.1.55555` in scripts.  
- **Production requirement**: replace temporary root with enterprise-assigned private OID root before go-live.  
- **Governance**: maintain a controlled OID registry (name, OID, syntax, MUST/MAY, owner, approval date), and require Git review for every schema change.  

7.7 **Sample LDIF (Current Project Custom Schema)**  
```ldif
dn: cn=bank-custom,cn=schema,cn=config
objectClass: olcSchemaConfig
cn: bank-custom
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.1
  NAME 'userisactive'
  DESC 'User active flag'
  EQUALITY booleanMatch
  SYNTAX 1.3.6.1.4.1.1466.115.121.1.7
  SINGLE-VALUE )
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.2
  NAME 'memorableAnswer'
  DESC 'Memorable answer'
  EQUALITY caseExactMatch
  SYNTAX 1.3.6.1.4.1.1466.115.121.1.15
  SINGLE-VALUE )
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.3
  NAME 'memorableQuestion'
  DESC 'Memorable question'
  EQUALITY caseIgnoreMatch
  SYNTAX 1.3.6.1.4.1.1466.115.121.1.15
  SINGLE-VALUE )
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.4
  NAME 'activationdatetime'
  DESC 'Account activation datetime'
  EQUALITY generalizedTimeMatch
  ORDERING generalizedTimeOrderingMatch
  SYNTAX 1.3.6.1.4.1.1466.115.121.1.24
  SINGLE-VALUE )
olcAttributeTypes: ( 1.3.6.1.4.1.55555.1.5
  NAME 'cif'
  DESC 'Customer Information File ID'
  EQUALITY caseExactMatch
  SYNTAX 1.3.6.1.4.1.1466.115.121.1.15
  SINGLE-VALUE )
olcObjectClasses: ( 1.3.6.1.4.1.55555.2.1
  NAME 'bankUserExtension'
  SUP top AUXILIARY
  MAY ( userisactive $ memorableAnswer $ memorableQuestion $ activationdatetime $ cif ) )
```

---

### 8. Security Design

8.1 **TLS Configuration (Project Decision: TLS, NOT SSL)**  

**Decision**: Use **TLS only** (no SSL). For production, enforce **LDAPS-only** listeners.

**Justification**:  
- SSL 3.0 is deprecated and vulnerable (POODLE, DROWN, etc.).  
- TLS 1.2+ is the modern standard.  
- Implementation aligns to `script/24-configure-ssl-tls.sh` listener modes.  

**Non-Production Compatibility Mode: StartTLS + LDAPS**  
- LDAP standard port: 389 for initial connection  
- Client issues STARTTLS command to upgrade to TLS  
- Script mode: `LDAP_LISTENER_MODE=starttls_and_ldaps` -> `SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"`  
- Use in DEV/QA only when legacy clients still require this transition mode.  

**Production Mode: LDAPS-only (Required)**  
- LDAPS dedicated port: 636 for immediate TLS negotiation  
- TLS established before any LDAP protocol exchange  
- Script mode: `LDAP_LISTENER_MODE=ldaps_only` -> `SLAPD_URLS="ldaps:/// ldapi:///"`  
- Plain LDAP listener (389) disabled for production.  

**Final Decision**: production uses LDAPS-only. StartTLS+LDAPS remains an explicitly temporary compatibility mode for non-production.

**Certificate Management**:  
- Certificates signed by enterprise/internal PKI.  
- Managed under `/opt/symas/etc/openldap/tls` (matches implementation script defaults).  
- Configuration entries under cn=config:  
  - `olcTLSCertificateFile`: server certificate path  
  - `olcTLSCertificateKeyFile`: server private key path  
  - `olcTLSCACertificateFile`: CA chain path  
  - `olcTLSProtocolMin`: set to `3.3` (TLS 1.2 minimum)  
  - `olcTLSCipherSuite`: enforce strong ciphers (no weak/export ciphers)  

**TLS Certificate Renewal**:  
- Monitor expiration via `cn=Monitor` queries; alert 30 days before expiry.  
- Automate renewal process through enterprise PKI workflow (e.g., Vault/cert management pipeline).  
- Test renewal in DEV/QA before production rotation.  

**Client Configuration**:  
- Applications must connect to LDAPS (636) or use StartTLS over 389.  
- Distribute enterprise CA root certificate to all client systems for certificate validation.  
- Disable certificate hostname verification only in non-prod labs (never in production).

8.2 **Authentication Mechanisms**  
- Simple binds over StartTLS/LDAPS for service accounts.  
- SASL support (EXTERNAL via TLS client cert) when needed.  
- Anonymous binds disabled; enforce binding DN with ACL rules.

8.3 **ACL Strategy**  
- Base ACL for entire tree ensuring read-only access except for service accounts.  
- Example:
  ```
olcAccess: to dn.subtree="ou=Users,dc=eab,dc=bank,dc=local"
    by dn.exact="cn=admin,dc=eab,dc=bank,dc=local" write
    by users read
    by * none
  ```

8.4 **Password Policies**  
- Configure ppolicy overlay: password history (5), lockout duration (30m), grace logins (3), min/max length (12/64).  
- Enforcement via `ppolicy_default` entry under `cn=config`.

8.5 **Audit & Logging (Accesslog Implementation)**  

**Comprehensive Audit Logging for Admin/System/User Events**  

8.5.1 **Accesslog Overlay Configuration**  
Configure the `accesslog` overlay to capture all directory changes for audit, compliance, and troubleshooting:

**Enable Accesslog Module**:  
```ldif
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: accesslog
```

**Create Accesslog Database**:  
```ldif
dn: olcDatabase={2}mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: {2}mdb
olcSuffix: cn=accesslog
olcRootDN: cn=accesslog-admin,cn=accesslog
olcDbDirectory: /opt/symas/var/openldap-accesslog
olcDbMaxSize: 1073741824
olcDbIndex: reqStart eq
olcDbIndex: reqEnd eq
olcDbIndex: reqResult eq
olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * none
```

**Attach Overlay to Primary Database**:  
```ldif
dn: olcOverlay=accesslog,olcDatabase={1}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcAccessLogConfig
olcOverlay: accesslog
olcAccessLogDB: cn=accesslog
olcAccessLogOps: writes reads session
olcAccessLogPurge: 30+00:00 01+00:00
```

8.5.2 **Audit Event Capture**  
The `olcAccessLogOps` parameter controls what events are recorded:

- **writes** (REQUIRED): ADD, MODIFY, DELETE, MODRDN operations (admin/system/user changes)  
- **reads** (OPTIONAL): SEARCH operations; verbose but essential for forensic analysis if required  
- **session** (REQUIRED): BIND, UNBIND authentication events (successful and failed attempts)  

**Captured Event Details**:  
- `reqStart`: timestamp of operation  
- `reqDN`: LDAP Distinguished Name (object modified)  
- `reqAuthzID`: authenticated user performing operation  
- `reqOp`: operation type (add/modify/delete/search/bind)  
- `reqResult`: operation result code (0 = success, others = failure/error)  
- `reqAssertion`, `reqMod`: search filters or modification details  

8.5.3 **Log Retention & Purge Policy**  
- Default in implementation: `olcAccessLogPurge: 30+00:00 01+00:00` (keep 30 days, purge job every 1 day).  
- Adjust based on compliance requirements (e.g., 90 days for regulatory audit trails)  
- Separate backups of accesslog database before purge operations  

8.5.4 **SIEM Integration & Log Forwarding**  
Forward accesslog entries to enterprise SIEM via syslog:

**syslog Forwarding Configuration** (on OpenLDAP host):  
```bash
# rsyslog rule: forward OpenLDAP accesslog to SIEM
# /etc/rsyslog.d/openldap-siem.conf
:programname, isequal, "slapd"
  *.* @@siem-collector.bank.local:514
```

**Field Mapping for SIEM** (document with SIEM team):  
| LDAP Field | SIEM Field | Type | Example |
|---|---|---|---|
| `reqAuthzID` | user_id | string | cn=admin,dc=eab,dc=bank,dc=local |
| `reqStart` | timestamp | ISO8601 | 2026-02-04T10:30:45.123Z |
| `reqDN` | object_dn | string | uid=test5,ou=Users,dc=eab,dc=bank,dc=local |
| `reqOp` | operation | enum | ADD, MODIFY, DELETE, BIND |
| `reqResult` | result_code | integer | 0 (success), 49 (invalid credentials) |
| `reqMod` | changes | string | userPassword=****,mail=user@bank.local |

8.5.5 **Operational Logging Levels**  
Configure slapd logging for diagnostic information:
- `loglevel: stats` = high-level bind/search/modify counts  
- `loglevel: stats2` = detailed operation timing  
- `loglevel: config` = configuration changes in cn=config  
- `loglevel: -1` (recommended for production) = log all levels (be cautious of log volume)  

**Configuration in cn=config**:  
```ldif
dn: cn=config
changetype: modify
replace: olcLogLevel
olcLogLevel: stats config
```

8.5.6 **Log Rotation & Disk Management**  
- slapd logs via `systemd-journald` (default); configure retention in `/etc/systemd/journald.conf`  
- accesslog database on separate filesystem to prevent data disk exhaustion  
- Monitor `du -sh /opt/symas/var/openldap-accesslog` daily; alert if approaching capacity  
- Implement nightly backup of accesslog before purge operations  

8.5.7 **Audit Validation**  
Validate accesslog is capturing events:
```bash
ldapsearch -H ldapi:// -Y EXTERNAL \
  -b cn=accesslog \
  -s sub '(reqAuthzID=cn=admin,dc=eab,dc=bank,dc=local)' \
  reqStart reqDN reqOp reqResult
```

Expected output: audit entries with timestamps, target DNs, operation types, and results.

---

### 9. Replication & High Availability
9.1 **Replication Model**  
- **syncrepl in refreshAndPersist** with `mirror` mode for two-way sync between `ldap1` and `ldap2`.  
- Each node configured as both provider and consumer for resilience.

9.2 **Topology**  
- Active-active pair per environment.  
- Dedicated `ldap-accesslog` database replicates across nodes.  
- Additional read-only replicas possible (for analytics) via `syncprov` consumers.

9.3 **Failover**  
- Clients connect via VIP/load balancer.  
- Monitor replication status (syncrepl overlay).  
- In failover scenario, clients automatically reroute to healthy node; stale data detection via replication cookie.

---

### 10. Hardware & Software Prerequisites
10.1 **CPU/Memory/Storage**  
- Minimum: 4 vCPU, 16 GB RAM, 200 GB SSD. Adjust sizing based on entry volume (e.g., +1 GB RAM per 100k entries).  
- Disk IOPS: ensure 4K writes fast (1000 IOPS).  
- Separate disks for data vs. logs/accesslog.

10.2 **OS & OpenLDAP Versions**  
- OS: RHEL 9/Ubuntu 22.04 with latest security patches.  
- OpenLDAP: 2.6.x (supports cn=config and modern features).

10.3 **Network Prerequisites**  
- Dedicated VLAN and firewall rules for LDAP ports (389/636).  
- Internal DNS entries (ldap-dev, ldap-qa, ldap-prod).  
- TLS certificate distribution to load balancer/trusted clients.

10.4 **Capacity Planning**  
- Assume 5 million entries, 1000 writes per minute avg, peaks 2000.  
- Configure `olcDbCacheSize` to 1/3 of available memory.  
- Monitor hit ratio and adjust `olcDbCacheSize`.

---

### 11. Migration Strategy
11.1 **Pre-migration Assessment**  
- Inventory existing directories.  
- Validate schema compatibility.  
- Export data via `slapcat`, check for duplicates or unsupported attributes.

11.2 **Data/Config Migration**  
- Use `slapcat` -> transform into LDIF for new schema.  
- Load into new MDB via `slapadd` followed by `slapindex`.  
- Apply cn=config entries via `ldapmodify`.

11.3 **Schema Compatibility**  
- Compare attribute/objectClass definitions (ensure same OIDs).  
- Introduce missing schema by defining new OIDs; update applications.

11.4 **Cutover**  
- Sync final delta with script.  
- Switch client load balancers to new endpoints during maintenance window.  
- Validate application binds and queries.

11.5 **Rollback**  
- Maintain backup of old slapd.conf/data.  
- If failure, switch LB back to legacy nodes, restore ldif to old server.

---

### 12. Testing Strategy
12.1 **Functional Tests**  
- CRUD operations via ldapmodify/ldapadd/ldapdelete.  
- Schema enforcement tests.

12.2 **Schema Validation**  
- Use `slaptest` after each schema change.  
- Ensure no conflicts with existing OIDs.

12.3 **ACL Testing**  
- Evaluate using scripts to verify each role’s access (admin/service/user).  

12.4 **Performance & Load**  
- Run `ldapsearch` stress tests with JMeter or ldapperf.  
- Monitor replication latency.

12.5 **Security Testing**  
- TLS handshake verification (OpenSSL s_client).  
- Password policy test cases (lockout, min length).  
- Penetration tests for ACL bypass.

---

### 13. Deployment & Go-Live Plan
13.1 **Pre-deployment Checklist**  
- Configuration LDIF reviewed and tested.  
- Certificates provisioned.  
- Monitoring/alerting configured.  
- Replication peers accessible.

13.2 **Deployment Steps**  
1. Provision servers.  
2. Install OpenLDAP packages.  
3. Apply cn=config LDIF via automation.  
4. Start slapd, confirm `slapd` status.  
5. Configure replication and overlays.

13.3 **Go-live Criteria**  
- `slapd` running on all nodes with TLS.  
- Replication synchronized (tracked via `syncrepl`).  
- ACL tests pass, monitoring alerts green.  
- Accesslog database populated.

13.4 **Post-go-live Validation**  
- Run health checks (ldapsearch).  
- Validate backup jobs.  
- Monitor for replication errors for 24 hours.

---

### 14. Operational Considerations
14.1 **Monitoring & Alerting**  
- Collect `cn=Monitor` data via `ldapsearch`.  
- Alert on replication status, TLS expiration, disk usage, abnormal bind failures.

14.2 **Backup & Restore**  
- `slapcat -n0` and -1 dumps nightly; store encrypted in object storage.  
- Restore via `slapadd` and `slapindex`.  
- Document restore runbook.

14.3 **Maintenance & Upgrades**  
- Rolling upgrade process: disable one node, drain, upgrade package, verify, rejoin.  
- Maintain patch-level release notes for OpenLDAP package.

---

### 15. Risks & Mitigation
15.1 **Technical Risks**  
- **Replication mismatches** → Mitigate with consistent `syncprov` config and monitoring of `contextCSN`.  
- **Configuration drift** → Use Git-managed LDIF and automation; enforce policies with CI.  
- **Schema collisions** → Govern OID allocations, review schema additions centrally.

15.2 **Operational Risks**  
- **Certificate expiration** → Automate monitoring and renewal with reminder alerts.  
- **Unauthorized ACL changes** → Restrict ldapmodify access to automation account; audit with accesslog.

15.3 **Mitigations**  
- Run nightly validation scripts.  
- Maintain runbooks and disaster recovery procedures.

---

### 16. Appendices
16.1 **Sample LDIF Snippets**  
- Schema, ACL, overlay/ppolicy entries (see section 7.7 for schema example).  

16.2 **Configuration Examples**  
- Sample cn=config overlay entry:
  ```
dn: olcOverlay=syncprov,olcDatabase={1}mdb,cn=config
objectClass: olcOverlayConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionlog: 100
```

16.3 **Glossary**  
- **cn=config:** Dynamic configuration backend.  
- **MDB:** Memory-Mapped Database backend.  
- **syncrepl:** LDAP replication mechanism.  
- **ppolicy:** Password policy overlay.  
- **Accesslog:** Overlay capturing change logs.

---

**Next Steps**  
1. Validate this design with stakeholders and capture feedback for adjustments.  
2. Begin LDIF authoring + automation pipeline setup based on these specs.
