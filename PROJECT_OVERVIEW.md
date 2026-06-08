# NEXTGenopen - High-Level Overview

## Purpose
Central workspace for OpenLDAP modernization: labs, infra code, runbooks, planning docs to migrate from legacy OID to modern OpenLDAP.

## Repo contents (top-level)
- `openldap-mirrormode/`: Local Docker Compose lab — 2 MirrorMode masters, 2 read-only replicas, HAProxy read/write VIPs, TLS, LDIFs, helper scripts.
- `terraform/`: AWS lab mirrors same topology (live + DR VPCs, NLBs, artifacts bootstrap, optional keepalived). Runbook for AWS and on-prem parity.
- `script/`: RHEL/Symas OpenLDAP install, tuning, hardening, password policy, test scripts for lab/POC.
- Requirements + planning: `OID_to_OpenLDAP_Modernization_Requirements.md`, `GAP_ANALYSIS_OID_to_OpenLDAP_Modernization.md`, supporting proposal files.
- Execution notes: `INSTALLATION_RUN_SUMMARY.md`, `step-by-step.md`, `step-by-step-Thinking.md`.

## Common architecture (labs)
- MirrorMode active/active masters
- Read-only replicas via syncrepl
- Read/write VIPs for client separation
- TLS-enabled endpoints

## How to use
1. Local lab: start with `openldap-mirrormode/README.md`.
2. AWS lab: start with `terraform/README.md` and `terraform/openldap/RUNBOOK.md`.
3. RHEL/Symas runbooks: see `README.md` and scripts under `script/`.
4. Target-state requirements: `OID_to_OpenLDAP_Modernization_Requirements.md`.
5. Current gaps vs target: `GAP_ANALYSIS_OID_to_OpenLDAP_Modernization.md`.

## Maturity
Repo provides working labs + automation for topology/replication. Production-grade items (auditing/SIEM, full ACL model, formal migration tooling, enterprise ops runbooks) tracked in requirements and gap analysis docs.

## Sensitive data note
Some files contain credentials or keys (e.g. `terraform/AWS-access-keys.text` or lab notes). Handle with care. Avoid committing secrets to shared repos.
