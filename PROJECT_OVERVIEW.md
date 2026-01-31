# NEXTGenopen - High-Level Overview

## Purpose
Central workspace for OpenLDAP modernization: labs, infrastructure code, runbooks, and planning docs to migrate from legacy OID to a modern OpenLDAP platform.

## What's in this repo (top-level)
- `openldap-mirrormode/`: Local Docker Compose lab with 2 MirrorMode masters, 2 read-only replicas, HAProxy read/write VIPs, TLS, LDIFs, and helper scripts.
- `terraform/`: AWS lab that mirrors the same topology (live + dr VPCs, NLBs, artifacts bootstrap, optional keepalived). Includes a runbook for AWS and on-prem parity.
- `script/`: RHEL/Symas OpenLDAP install, tuning, hardening, password policy, and test scripts used for lab/POC environments.
- Requirements and planning docs: `OID_to_OpenLDAP_Modernization_Requirements.md`, `GAP_ANALYSIS_OID_to_OpenLDAP_Modernization.md`, and supporting proposal files.
- Execution notes: `INSTALLATION_RUN_SUMMARY.md`, `step-by-step.md`, `step-by-step-Thinking.md`.

## Common architecture (labs)
- MirrorMode active/active masters
- Read-only replicas via syncrepl
- Read/write VIPs for client separation
- TLS-enabled endpoints

## How to use (high-level)
1. Local lab: start with `openldap-mirrormode/README.md`.
2. AWS lab: start with `terraform/README.md` and `terraform/openldap/RUNBOOK.md`.
3. RHEL/Symas runbooks: see `README.md` and scripts under `script/`.
4. Target-state requirements: `OID_to_OpenLDAP_Modernization_Requirements.md`.
5. Current gaps vs target: `GAP_ANALYSIS_OID_to_OpenLDAP_Modernization.md`.

## Current maturity
The repo provides working labs and automation for topology/replication. Production-grade items (auditing/SIEM, full ACL model, formal migration tooling, and enterprise ops runbooks) are tracked in the requirements and gap analysis docs.

## Sensitive data note
Some files may contain credentials or keys (for example `terraform/AWS-access-keys.text` or lab installation notes). Handle with care and avoid committing secrets to shared repos.
