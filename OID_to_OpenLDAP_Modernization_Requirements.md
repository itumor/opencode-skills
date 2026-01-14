OID to OpenLDAP Modernization Program

Requirements Document

Version: 0.1 (Draft)

Date: 11 June 2026

Prepared for: CAE

Prepared by: ____________________

Status: Draft

# 1. Introduction

## 1.1 Purpose

This document defines the business, functional, security, and non-functional requirements for modernizing the legacy identity stack by replacing Oracle Internet Directory (OID) with OpenLDAP as the single authoritative identity store.

## 1.2 Background

Current identity landscape includes multiple components (OID, OAM, SSO + FCDB, and SSO administration tools). Key challenges include high operational overhead, redundant/unused identity data, deprecated password hashing (SHA-1), fragmented administration and governance, and limited flexibility for future integrations.

## 1.3 Goals

• Establish OpenLDAP as the single authoritative identity store.

• Move customer administration actions to CRM/NCT and expose identity data via middleware APIs.

• Standardize integrations using secure, API-based patterns and scoped LDAP service accounts.

• Improve security posture (LDAPS, stronger password hashing, auditing, SIEM integration).

• Provide a scalable, highly available directory platform.

# 2. Scope

## 2.1 In Scope

• Deploy and configure OpenLDAP on CAE-provided Linux infrastructure (preference: Red Hat Enterprise Linux).

• Implement a highly available OpenLDAP topology (2 Masters in Mirror Mode, 2 Read Replicas).

• Design and implement directory structure and access controls (OUs for users/admins/systems).

• Enforce secure LDAP communication (LDAPS) and directory auditing/logging.

• Enable monitoring and log forwarding to SIEM via Syslog.

• Support integration with middleware systems through secure and standardized APIs.

• Define and execute user migration from OID to OpenLDAP using an LDIF-based ETL approach (details finalized during design).

## 2.2 Out of Scope / Provided by CAE

• VM provisioning and operating system installation and hardening.

• Load balancer configuration and VIP/DNS cutover.

• Performance and load testing.

• DR site VM replication setup and DR failover execution (per CAE DR procedures).

• Provisioning of infrastructure, OS, and certificates.

• Direct LDAP replication between main and DR sites.

Note: Documents requiring CAE approval are expected to be approved within 3 business days.

# 3. Target State

The target state is an OpenLDAP-based identity platform where OpenLDAP is the single authoritative identity store, CRM/NCT is the central customer administration system, and all consuming systems integrate via middleware APIs. Security is enforced by design through LDAPS, strong password hashing, and centralized monitoring/logging.

# 4. Architecture Requirements

## 4.1 Platform and Topology

• Platform: Red Hat Enterprise Linux (RHEL).

• Topology: 2 Masters (Mirror Mode) and 2 Read Replicas.

• Replication: Ensure data consistency across masters and replicas.

• Availability: No single point of failure; maintain service continuity during node failures.

• Scalability: Support horizontal scale-out of read replicas as needed.

## 4.2 Directory Structure

Logical separation of identities is required to improve security, governance, and auditing.

• ou=users (end users)

• ou=admins (administrative users)

• ou=systems (system/service accounts)

Base DN, schema extensions, and attribute mappings will be finalized during the analysis and design phases.

# 5. Requirements

## 5.1 Functional Requirements

FR-001 (High): Deploy and configure OpenLDAP on CAE-provided Linux infrastructure (preference: RHEL) aligned to enterprise operational standards.

FR-002 (High): Implement HA topology with 2 Masters (Mirror Mode) and 2 Read Replicas, including replication and failover behavior.

FR-003 (High): Implement directory structure using OUs for users, admins, and systems/service accounts.

FR-004 (High): Provide middleware API integration for authentication and identity-related services; expose OpenLDAP data via middleware APIs.

FR-005 (High): Provision a dedicated LDAP admin/service account per connected system with scoped permissions and isolation.

FR-006 (High): Migrate user accounts from OID to OpenLDAP using an LDIF-based ETL process.

FR-007 (Medium): Document and implement a post go-live enhancement path to upgrade password hashing from legacy SHA-1 to modern hashing (for example SHA-256/bcrypt) as permitted by compatibility constraints.

FR-008 (High): Support CRM/NCT as the central customer administration system for customer-related identity actions (SSO administration, OAM workflows, call center and digital channel identity operations).

FR-009 (High): Enable directory auditing and logging for authentication, access, and administrative operations.

FR-010 (High): Enable Syslog forwarding of relevant logs to SIEM for monitoring, incident detection, and compliance reporting.

## 5.2 Security Requirements

SR-001 (High): Enforce LDAPS for all LDAP communications; reject or disable plaintext LDAP where feasible.

SR-002 (High): Use CAE-approved TLS versions/cipher suites and certificate management practices for LDAPS.

SR-003 (High): Apply least-privilege access controls (ACLs) for all identities and integrations.

SR-004 (High): Enforce differentiated password policies for end users, admin users, and system/service accounts.

SR-005 (High): Store credentials using strong hashing algorithms. Maintain legacy hashing only as required for migration compatibility, with a defined remediation/upgrade plan.

SR-006 (High): Provide comprehensive auditing/logging and support SIEM integration via Syslog.

## 5.3 Non-Functional Requirements

NFR-001 (High): High availability with no single point of failure for directory services.

NFR-002 (Medium): Horizontal scalability (add read replicas to increase read capacity).

NFR-003 (High): Operational maintainability (documentation, runbooks, monitoring hooks).

NFR-004 (High): Auditability and compliance (log completeness, integrity, and retention requirements to be agreed with CAE/SIEM team).

NFR-005 (Medium): Customer login performance must be maintained or improved compared to the legacy landscape (formal load testing excluded per scope).

## 5.4 Constraints and Dependencies

• CAE provides infrastructure/VMs, OS installation/hardening, and certificates.

• VIP/DNS cutover and load balancer configuration are out of scope.

• Performance and load testing are out of scope.

• DR is managed by CAE procedures; no direct LDAP replication between main and DR sites.

• Migration strategy details are finalized during design; password history cannot be migrated.

• CAE approvals for required documents are expected within 3 business days.

# 6. Migration Requirements

User migration from OID to OpenLDAP will be executed using an LDIF-based ETL process.

• Data extraction from OID into LDIF.

• Transformation/mapping to the target OpenLDAP schema (to be defined during design).

• Loading into OpenLDAP with validation and reconciliation.

• Password handling: legacy password hashes migrate; modern hashing is applied post-migration/post go live. Password history is not migrated.

• Decommissioning: enable prompt decommissioning of legacy identity systems once acceptance criteria are met.

# 7. Monitoring and SIEM Integration

• Enable Syslog on OpenLDAP hosts.

• Forward authentication and access logs to SIEM.

• Provide log fields sufficient for security monitoring, incident detection, and audit/compliance reporting (final field list to be agreed).

# 8. Acceptance Criteria

• OpenLDAP is deployed on the agreed Linux platform and accessible via LDAPS.

• Mirror Mode replication between masters is functional and consistent; read replicas are in sync.

• Directory structure (ou=users, ou=admins, ou=systems) is implemented.

• Dedicated service accounts exist per consuming system with validated least-privilege access.

• Migration results reconcile (record counts, key attributes) and sample authentications succeed.

• Audit logs are enabled and forwarding to SIEM is verified.

• Operational documentation and runbooks are delivered and reviewed.

# 9. Deliverables and Next Steps

## 9.1 Key Deliverables

• Analysis and design documentation (target architecture, schema, integration model, security design).

• Project plan (scope, timeline, milestones, responsibilities).

• OpenLDAP build/configuration artifacts and operational runbooks.

• Migration plan and LDIF-based ETL scripts/process documentation.

• Logging/SIEM integration configuration and verification evidence.

• Go-live and rollback approach (to be finalized during design).

## 9.2 Next Steps (per program deck)

• Complete the analysis and design phases and finalize solution design activities.

• Finalize the project plan (scope, timelines, milestones, responsibilities).

• Review and approve design deliverables.

• Prepare the testing environment and communication matrix.

• Initiate implementation in accordance with the approved plan.

# Appendix A: Extracted Slide Text

The following text was extracted from the provided PowerPoint deck to preserve original phrasing. Slides that contain only visuals may appear with limited text.

## Slide 1

• OID to Open LDAP Modernization Program Design review

• Replacing Legacy Identity Stack with Secure, Scalable LDAP

• 11,June,2026

## Slide 2

• Executive Summary

## Slide 3

• Overview

• Multiple identity components:

• • OID

• • OAM

• • SSO + FCDB

• • SSO Admin Tools

• Key challenges:

• • High operational overhead

• • Redundant and unused identity data

• • Deprecated password hashing (SHA-1)

• • Fragmented administration and governance

• • Limited flexibility for future integrations

## Slide 4

• Program Scope

• Installation and Configuration of OpenLDAP   Deploy and configure OpenLDAP on a Linux platform, with a   preference for Red Hat Enterprise Linux (RHEL), in accordance with enterprise security and operational standards.

• Middleware (MW) API Integration    Enable and support integration with middleware systems through secure and standardized APIs to facilitate authentication and identity-related services.

## Slide 5

• Out of Scope

• CAE to provides VM and operating system installation and Hardening.

• Configure load balancing (VIP/DNS cutover) is out of scope.

• Performance and load testing is out of scope.

• CAE to provide VM replication setup for DR site.

• CAE to provide infrastructure, OS, and certificates.

• Failover at DR site is triggered and managed by CAE DR procedures however

• No direct LDAP replication between main and DR sites.

• The Migration strategy for data from the existing OID to the openLDAP to be defined during the design phase.

• Any document requiring approval by CAE to be approved within 3 business days.

## Slide 6

• Target State Overview

• OpenLDAP as the single authoritative identity store

• CRM or NCT as the central customer administration system

• API-based integration for all consuming systems

• Secure-by-design configuration

• LDAPS enforced

• Strong password hashing

• Centralized logging and monitoring

## Slide 7

• OpenLDAP Architecture

## Slide 8

• OpenLDAP Architecture

• Platform: Red Hat Enterprise Linux

• Topology:

• 2 Masters (Mirror Mode)

• 2 Read Replicas

• Benefits:

• Load distribution

• No single point of failure

• Horizontal scalability

• High availability

• Data consistency

## Slide 9

• Directory Structure Design

• Logical separation of identities using OUs:

• ou=users

• ou=admins

• ou=systems

• Clear separation of concerns:

• End users

• Administrative users

• System/service accounts

• Improves security, governance, and auditing

## Slide 10

• Security Architecture

• Secure LDAP Communication

• Enforce LDAPS for all LDAP communications to ensure encrypted data transmission.

• Operating System Hardening

• Implement Red Hat Enterprise Linux hardening in alignment with CAE security baselines and best practices.

• Least-Privilege Access Model

• Apply a least-privilege access model across all integrations to minimize security exposure.

• Role-Based Password Policies

• Enforce differentiated password policies for end users, administrators, and service accounts.

• Strong Password Hashing

• Utilize industry-standard strong hashing algorithms to securely store credentials.

• Audit and Logging

• Enable comprehensive auditing and logging for all authentication and directory operations.

• SIEM Integration Support

• Support integration with SIEM platforms through Syslog for centralized monitoring and security analytics.

## Slide 11

• Password & Policy Management

• • Legacy OID passwords migrated successfully

• • Current state: SHA1 -based hashing (legacy compatibility)

• Post go-live enhancement:

• • Upgrade to modern hashing (SHA-256 / bcrypt)

• Password policies defined for:

• • End users

• • Admin users

• • System/service users

## Slide 12

• Enhancements from Legacy OID

## Slide 13

• CRM/NCT -Centric Customer approach

• • All customer related action to be  moved to CRM/NCT

• – SSO administration

• – OAM-related workflows

• – Call center identity functions

• – Digital channel identity operations

• • OpenLDAP  related data to be exposed via Middleware APIs

• • LDAP acts as backend identity store

## Slide 14

• Integration Model

• • Each connected system has its own LDAP admin/service account

• • Dedicated permissions and scope per system

• Benefits:

• • Strong isolation

• • Reduced risk exposure

• • Simplified audit and compliance

## Slide 15

• Monitoring & SIEM Integration

• • Syslog enabled on OpenLDAP

• • Authentication and access logs forwarded to SIEM

• Enables:

• • Security monitoring

• • Incident detection

• • Audit and compliance reporting

## Slide 16

• Migration Strategy

• Approach

• User Migration from OID to OpenLDAPMigrate user accounts from Oracle Internet Directory (OID) to OpenLDAP using an LDIF-based ETL process.

• Limitation

• The new password Hashing will be applied after migration

• The password history can’t be migrated

• Key Benefits

• Single Centralized DirectoryEstablish a single source of truth for all user identities.

• Reduced Middleware LoadMinimize dependency on middleware for identity resolution and synchronization.

• Improved Customer Login PerformanceEnable faster and more efficient customer authentication processes.

• Immediate Legacy DecommissioningAllow prompt decommissioning of legacy identity systems, reducing cost and operational risk.

## Slide 17

• Go-Live Approach

## Slide 18

• Key Business & Technical Benefits

• • Simplified identity landscape

• • Reduced licensing and operational costs

• • Improved security compliance

• • Scalable and future-ready architecture

• • Clear ownership and governance model

## Slide 19

• Next Steps

• Complete the Analysis and Design PhasesFinalize all analysis and solution design activities.

• Finalize the Project PlanConfirm scope, timelines, milestones, and responsibilities.

• Approve Design DeliverablesReview and formally approve the analysis and design documentation.

• Prepare the Testing EnvironmentProvision the testing environment and implement the agreed communication matrix.

• Initiate ImplementationCommence the implementation phase in accordance with the approved plan.
