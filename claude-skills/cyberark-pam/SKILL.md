---
name: cyberark-pam
description: Generic CyberArk Privileged Access Management concepts and troubleshooting — Vault/Digital Vault, CPM (password rotation), PVWA (web portal), PSM/PSMP (session proxy for RDP/SSH), Safes and platforms, and the connection-component chain for session recording. Use whenever the user mentions CyberArk, PAM, PSM/PSMP session failures ("failed to connect to all addresses", broken RDP-over-CyberArk), password rotation not happening, Safe permissions, or onboarding an account/platform into CyberArk — even if they only say "privileged access" or "vaulted credentials." Not tied to any one company's CyberArk install; for EIS/OneSuite's specific CyberArk deployment, prefer the repo's own cyberark-eis-install skill first.
---

# CyberArk PAM

CyberArk Privileged Access Management vaults, rotates, and brokers privileged credentials so humans and automation never see the raw secret and every privileged session is auditable.

## Core components

| Component | Role |
|---|---|
| **Digital Vault** | Encrypted credential store — the source of truth. Everything else is a client of it. |
| **CPM** (Central Policy Manager) | Rotates passwords/keys on a schedule or on-demand, per platform policy. |
| **PVWA** (Password Vault Web Access) | Web UI/API for requesting, viewing (if allowed), and managing accounts and Safes. |
| **PSM** (Privileged Session Manager) | RDP proxy — brokers a session to a Windows/Linux target without the user ever holding the credential; records the session. |
| **PSMP** (PSM for SSH) | Same idea for SSH — a Linux connector box the user SSHes through, which then vaults-authenticates onward to the real target. |

## Object model

- **Account**: one credential (username + secret + address), owned by exactly one Safe.
- **Safe**: an ACL boundary — who can retrieve, use, or manage accounts in it. Onboarding an account means creating/placing it in the right Safe with the right platform.
- **Platform**: a policy template — rotation interval, connection component, workflow rules — applied to an account. Get the platform wrong and rotation either never fires or fires against the wrong protocol.
- **Connection Component**: defines how PSM actually launches the session (RDP file params, SSH client, MFA caching) — the thing that usually breaks silently when a target's config changes (new host key, changed shell, disabled password auth).

## Onboarding an account/target — the usual checklist

1. Target must be reachable from PSM/PSMP network path (firewall, security group) — not just from the vault server.
2. Platform selected matches the target OS/protocol (Windows Domain vs Windows Local vs Unix SSH vs SSH key-based, etc.).
3. Safe permissions grant the requesting user/group "Use Accounts" (to broker a session) vs "Retrieve" (to see the plaintext) — these are different rights and commonly confused.
4. If rotation is required, CPM's scan/rotation account on the target needs the actual OS-level rights to change the credential (e.g. local admin, or a service account with the right ACL) — CyberArk itself only initiates rotation, it doesn't grant itself target permissions.

## Common failure: PSMP SSH connect errors

`"failed to connect to all addresses"` or a session that drops immediately after auth is almost always one of:

- PSMP's own connection component config doesn't match the target's SSH server (cipher/kex mismatch, disabled password auth when the component expects password, host key changed and not re-trusted).
- The vaulted account's actual OS credential is stale (rotated in CyberArk but the target's `authorized_keys`/password wasn't updated — happens when the CPM rotation plugin silently failed).
- Network path from the PSMP connector to the target is fine, but PSMP → Vault communication (for the actual retrieve) is blocked — check PSMP's own logs, not just the target's sshd log.

## Ansible / automation over CyberArk

Automation (e.g. Ansible) that needs to run *through* a CyberArk-brokered session (not just fetch a secret via CCP/AIM) inherits PSM/PSMP's session semantics — file transfer or long-running interactive commands can behave differently than a direct SSH session (buffering, session idle timeouts, recording overhead). If a playbook works against a direct host but fails or hangs through the CyberArk path, suspect the proxy layer before the playbook logic.

## Fetching secrets programmatically (not session brokering)

CCP (Central Credential Provider) / AIM exposes a REST-ish interface for an application to pull a secret directly (no interactive session) — this is the pattern for CI/CD or app startup fetching a DB password. It's a different access path from PSM/PSMP and has its own Safe permission ("Retrieve") and its own app-identity allowlisting (by IP, OS user, hash, or path) — a CCP 403 is almost always the app identity not matching what's registered, not a Safe permission gap.
