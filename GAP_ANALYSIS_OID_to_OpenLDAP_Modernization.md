# Gap Analysis: OID → OpenLDAP Modernization Requirements vs. Current Repo

Source requirements: `OID_to_OpenLDAP_Modernization_Requirements.md`

Scope of this gap analysis: compare the **current state of this repository** (primarily the `openldap-mirrormode/` Docker Compose lab) against the stated modernization requirements, and identify what is **covered**, **partially covered**, or **missing**.

## Executive Summary

This repo currently provides a **working OpenLDAP MirrorMode lab** with:

- 2 masters in MirrorMode + 2 read-only replicas (`openldap-mirrormode/PROJECT.md`)
- Read/write VIP separation via HAProxy (`openldap-mirrormode/haproxy/`)
- TLS-enabled LDAP endpoints (LDAPS ports exposed; `openldap-mirrormode/docker-compose.yml`)
- Replication configuration via LDIFs + scripts (`openldap-mirrormode/ldif/`, `openldap-mirrormode/scripts/`)

However, the modernization requirements target a **production identity platform** (RHEL hosts, enterprise TLS policy, auditing + SIEM/syslog, least-privilege service accounts per system, password policies/hashing strategy, migration ETL, and middleware/CRM integration). Those areas are **not implemented** in this repo today (or are lab-only and require productionization).

## Current Implementation Evidence (What exists today)

- Topology (2 masters + 2 replicas): `openldap-mirrormode/PROJECT.md`
- Docker services + TLS enabled: `openldap-mirrormode/docker-compose.yml`
- HAProxy VIPs expose both LDAP and LDAPS:
  - Write VIP config: `openldap-mirrormode/haproxy/haproxy-write.cfg`
  - Read VIP config: `openldap-mirrormode/haproxy/haproxy-read.cfg`
- Replication setup automation: `openldap-mirrormode/scripts/apply-replication-ldifs.sh`
- Replication LDIFs (server IDs, syncprov, mirrormode, consumers): `openldap-mirrormode/ldif/`
- Replicator account + minimal ACL for replication reads:
  - `openldap-mirrormode/ldif/01-replicator.ldif`
  - `openldap-mirrormode/ldif/02-replicator-acl.ldif`

## Gaps by Requirement (Traceability Matrix)

Status legend:
- **Covered**: implemented in repo and demonstrably usable
- **Partial**: some pieces exist, but not aligned to the requirement intent (usually “lab-only”)
- **Missing**: not implemented / not documented

### Functional Requirements

| ID | Priority | Status | Evidence in repo | Gap / What’s needed |
|---|---:|---|---|---|
| FR-001 | High | Partial | `openldap-mirrormode/` | Repo deploys OpenLDAP in Docker; requirement is **CAE Linux (RHEL) enterprise-aligned** build (packages, systemd, backups, patching, hardening, ops standards). |
| FR-002 | High | Covered | `openldap-mirrormode/PROJECT.md`, `openldap-mirrormode/ldif/21-mirrormode-master-a.ldif`, `openldap-mirrormode/ldif/22-mirrormode-master-b.ldif`, `openldap-mirrormode/ldif/30-replica-consumer.ldif` | Production runbooks + failure-domain design still needed (multi-host, real LB, storage, monitoring). |
| FR-003 | High | Missing | (no OU bootstrap LDIF) | Create base DIT structure: `ou=users`, `ou=admins`, `ou=systems`, plus any required groups/roles; document schema/attribute mappings. |
| FR-004 | High | Missing | (no middleware code/docs) | Define the middleware/API contract, authn/authz flows, and how LDAP is exposed indirectly; add architecture + integration docs. |
| FR-005 | High | Missing | Only replicator exists: `openldap-mirrormode/ldif/01-replicator.ldif` | Create per-consuming-system service accounts + scoped ACLs (least privilege), credential lifecycle, and onboarding process. |
| FR-006 | High | Missing | (no migration tooling) | Provide LDIF ETL plan + scripts: extract from OID, transform/mapping, load to OpenLDAP, reconciliation checks, rollback plan. |
| FR-007 | Medium | Missing | (no hashing strategy docs) | Document and implement the **post-go-live** password hashing upgrade plan (compat constraints, rehash-on-bind, forced reset strategy, etc.). |
| FR-008 | High | Missing | (no CRM/NCT integration docs) | Document ownership boundaries: CRM/NCT as system of record for customer admin actions; define workflows and API integration points. |
| FR-009 | High | Missing | (no audit/accesslog config in current lab) | Implement directory auditing/logging (log levels, accesslog overlay if required) and document what events are captured. |
| FR-010 | High | Missing | (no syslog forwarding) | Implement syslog forwarding for OpenLDAP logs (host-level rsyslog/syslog-ng or container log drivers) and provide SIEM field mapping. |

### Security Requirements

| ID | Priority | Status | Evidence in repo | Gap / What’s needed |
|---|---:|---|---|---|
| SR-001 | High | Partial | LDAPS exposed: `openldap-mirrormode/docker-compose.yml`; plaintext LDAP also exposed: `openldap-mirrormode/haproxy/haproxy-write.cfg`, `openldap-mirrormode/haproxy/haproxy-read.cfg` | Requirement is to **enforce LDAPS** and reject/disable plaintext. Decide whether to (a) remove LDAP listeners at LB, (b) disable LDAP (389) on servers, and/or (c) enforce StartTLS-only. |
| SR-002 | High | Partial | Lab cert generation: `openldap-mirrormode/scripts/gen-certs.sh` | Replace lab certs with CAE PKI-managed certs; set and document TLS min versions/ciphers per CAE standards; manage rotation. |
| SR-003 | High | Partial | Replication ACL only: `openldap-mirrormode/ldif/02-replicator-acl.ldif` | Define full ACL model for users/admins/systems + service accounts; ensure least privilege by OU, attributes, and operations. |
| SR-004 | High | Missing | (no ppolicy config) | Implement differentiated password policies (users vs admins vs systems) using `ppolicy` (or equivalent) and document policy settings. |
| SR-005 | High | Missing (not verified) | (no explicit password hash config) | Define required hashing (e.g., SSHA512 / ARGON2 / bcrypt depending on OpenLDAP support & CAE policy) and ensure configuration enforces it; keep legacy only for migration with a remediation plan. |
| SR-006 | High | Missing | (no auditing/syslog config) | Implement comprehensive auditing + SIEM forwarding, including validation steps and retention/integrity requirements. |

### Non-Functional Requirements

| ID | Priority | Status | Evidence in repo | Gap / What’s needed |
|---|---:|---|---|---|
| NFR-001 | High | Partial | MirrorMode + replicas exist (`openldap-mirrormode/PROJECT.md`) | Current HA is **single Docker host**. Production HA requires multi-node infra, LB HA, storage considerations, backup/restore, failure testing. |
| NFR-002 | Medium | Partial | Compose pattern supports adding replicas | Document a scale-out approach (add consumer nodes, capacity planning, connection limits, LB config updates). |
| NFR-003 | High | Partial | Lab scripts + docs exist | Add production runbooks: onboarding, cert rotation, backup/restore, schema change process, incident response, monitoring hooks/alerts. |
| NFR-004 | High | Missing | (no SIEM field list/retention) | Define audit log completeness + retention + integrity requirements with CAE SIEM team; document field mapping and verification. |
| NFR-005 | Medium | Missing | (no perf validation) | Define performance baselines and validation approach (even if formal load testing is out of scope). |

## Acceptance Criteria Coverage

| Requirement | Status | Notes |
|---|---|---|
| OpenLDAP deployed and accessible via LDAPS | Partial | LDAPS exists in lab; production platform/TLS policy not implemented. |
| MirrorMode replication + replicas functional | Covered (lab) | Lab provides replication LDIFs and scripts; production validation/runbooks still needed. |
| Directory structure (ou=users/admins/systems) implemented | Missing | No bootstrap LDIF for required OUs in current repo. |
| Dedicated service accounts per consuming system | Missing | Only `cn=admin` and `cn=replicator` exist by default. |
| Migration reconciles + sample auth succeeds | Missing | No migration tooling/plan implemented. |
| Audit logs enabled + forwarding to SIEM verified | Missing | No audit/accesslog/syslog-to-SIEM implementation in current repo. |

## Recommended Next Additions to This Repo (Actionable Work Items)

1. **DIT bootstrap**: add LDIF(s) to create `ou=users`, `ou=admins`, `ou=systems` and any required base entries; update docs.
2. **Service accounts + ACL model**: add an ACL design doc + example LDIFs for per-system service accounts and least-privilege access.
3. **LDAPS enforcement**: remove/disable plaintext LDAP exposure (update HAProxy configs and/or slapd listeners) and document client requirements.
4. **Password policy + hashing**: implement `ppolicy` (or equivalent), define hashing policy, and add an explicit “hash upgrade path” doc.
5. **Auditing + SIEM forwarding**: define what to log, enable it (e.g., loglevel/accesslog overlay if needed), and provide syslog forwarding examples + validation steps.
6. **Migration ETL skeleton**: add a `migration/` folder with planned steps, sample LDIF transform approach, reconciliation scripts, and acceptance criteria checklist.
7. **Productionization docs**: add a “from lab to RHEL” document (packages, system users, filesystem layout, systemd units, backups, monitoring).

## Notes / Clarifications Needed (to close gaps accurately)

- Target OpenLDAP version/distro and whether containers are allowed in production (requirements mention RHEL hosts).
- CAE TLS policy specifics (min TLS version, cipher suites, cert rotation, hostname/VIP cert strategy).
- Required schema extensions and attribute mappings from OID.
- Exact audit event requirements + SIEM field list.
- Password hash compatibility constraints (what legacy hashes exist in OID, what clients support post-migration).
