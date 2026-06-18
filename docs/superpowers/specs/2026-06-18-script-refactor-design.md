# Script Refactor: Library + Thin Scripts Architecture

**Date:** 2026-06-18  
**Branch:** New branch from `Development`  
**Goal:** 2 big all-in-one scripts (master + replica), small single-purpose scripts, clean output, no duplication.

## Architecture

```
script/
├── master-all-in-one.sh          # Master full pipeline (~400 lines)
├── replica-all-in-one.sh         # Replica full pipeline (~400 lines)
│
├── lib/                          # Reusable library (sourced, never executed directly)
│   ├── common.sh                 # Colors, section headers, PASS/FAIL/WARN counting, env check
│   ├── ldap-ops.sh               # ldapsearch/add/modify wrappers with error handling
│   ├── install.sh                # Package install, service setup
│   ├── configure.sh              # cn=config, TLS certs, replication, ppolicy, schema, OUs
│   ├── harden.sh                 # Security: anon disable, TLS enforce, firewall
│   ├── verify.sh                 # Health checks (auto-detects master vs replica)
│   ├── tune.sh                   # NOFILE, SLAPD_URLS, indices, db maxsize
│   ├── fix.sh                    # Self-healing: checksums, syncrepl TLS, ppolicy, ACL
│   └── diag.sh                   # Log collection, status dump, report generation
│
├── steps/                        # Ad-hoc single-purpose scripts (source lib)
│   ├── fix-syncrepl.sh           # Fix replica syncrepl TLS/starttls
│   ├── fix-checksums.sh          # Fix ldif checksum errors on cn=config
│   ├── fix-ppolicy.sh            # Fix missing ppolicy overlay/module
│   ├── fix-acl.sh                # Fix ldapi ACL for cn=config
│   ├── health-check.sh           # Quick health check (master or replica)
│   ├── collect-logs.sh           # Collect slapd logs + config for support
│   ├── show-status.sh            # contextCSN, entry count, sync status
│   ├── reset-admin-pw.sh         # Reset admin password (SSHA hash)
│   └── seed-replica.sh           # Seed empty replica DB from master
│
├── test/                         # Tests (consolidated)
│   ├── run-all.sh                # Test orchestrator
│   ├── smoke.sh                  # Syntax + ref checks (merged smoke scripts)
│   ├── integration-master.sh     # Master-only integration tests
│   ├── integration-replica.sh    # Replica-only integration tests
│   └── test-connections.sh       # Connection test matrix (was test-openldap-connections.sh)
│
└── schema/                       # Schema .ldif files for ldapadd
    └── *.ldif
```

## All-in-One Pipeline Flow

Both `master-all-in-one.sh` and `replica-all-in-one.sh` follow this sequence:

```
=== STEP 1: Install    — dnf install packages, env setup
=== STEP 2: Configure  — cn=config init, TLS, replication, ppolicy, schema, OUs
=== STEP 3: Harden     — disable anon, require TLS, firewall
=== STEP 4: Tune       — NOFILE, indices, db sizing
=== STEP 5: Start      — systemctl start, wait for ready
=== STEP 6: Verify     — health checks (role-aware, 16-17 checks)
=== STEP 7: Test       — integration tests
=== STEP 8: Diagnose   — collect status report, contextCSN, entry count
=== STEP 9: Fix (auto) — if any WARN/FAIL in Verify, auto-apply fixes, re-verify
=== DONE               — summary: PASS=X FAIL=Y WARN=Z
```

**Master-specific:** Creates replicator user, syncprov overlay, accesslog DB, serverID=1.  
**Replica-specific:** Requires `MASTER_IP`/`ADMIN_PW`, configures `olcSyncrepl`, serverID=2, readonly, updateRef, optional DB seed from master.

## Override ENV Vars

| Var | Effect |
|-----|--------|
| `SKIP_INSTALL=1` | Skip package install |
| `SKIP_TLS=1` | Skip TLS cert generation |
| `SKIP_HARDEN=1` | Skip security hardening |
| `SKIP_TUNE=1` | Skip performance tuning |
| `SKIP_TEST=1` | Skip integration tests |
| `SKIP_DIAG=1` | Skip diagnostic collection |
| `FORCE_FIX=1` | Run fix step even if verify passed |
| `ONLY_VERIFY=1` | Only verify + diagnose (no install/config) |
| `ONLY_FIX=1` | Only fix + verify (for existing broken install) |
| `DRY_RUN=1` | Print what would be done, don't execute |
| `TLS_MODE=yes/no` | Enable/disable TLS (default: yes) |
| `VERBOSE=1` | Show command output, not just PASS/FAIL |
| `QUIET=1` | Only print section headers + FAIL/WARN (no PASS lines) |

## Output Format

Each step logs `[PASS]`, `[FAIL]`, `[WARN]`, `[SKIP]`, or `[INFO]` with a one-line message.
Colors: Green PASS, Red FAIL, Yellow WARN, Cyan SKIP, White INFO. `--no-color` disables.

Final section shows:
```
========================================
 SUMMARY: PASS=28 FAIL=0 WARN=1 SKIP=2
 RESULT: OK (1 warning, see above)
 Duration: 3m 42s
========================================
```

## Duplicate/Contradicted Script Resolution

| Old Scripts | Resolution |
|-------------|------------|
| `fix-master.sh` + `fix-master-checksum.sh` | Merge into `lib/fix.sh`. `steps/fix-checksums.sh` wraps one function. |
| `fix-replica.sh` + `fix-replica-syncrepl-tls.sh` | Merge into `lib/fix.sh`. `steps/fix-syncrepl.sh` wraps one function. |
| `verify-master.sh` + `verify-replica.sh` + `verify-post-fix.sh` | Merge into `lib/verify.sh` (auto-detect role). |
| `bank-fix-all.sh` | Replaced by all-in-one scripts' `ONLY_FIX=1` mode. Delete. |
| `deploy-fix-pipeline.sh` | All-in-one scripts run directly on-node. Delete. |
| `8.0-fix_ldapi_acl.sh` + `r6-fix-replica-ldapi-acl.sh` | Merge into `lib/fix.sh` with role param. |
| `5-fix_all_symas_warns.sh` + `r4-fix-replica-env.sh` | Merge into `lib/install.sh` post-install hook. |
| `test-openldap-connections.sh` | Move to `test/test-connections.sh`, source `lib/ldap-ops.sh`. |
| All numbered step scripts (0-27) | Logic merged into `lib/{install,configure,harden,tune}.sh`. |
| Replica scripts (r1-r9) | Logic merged into `lib/` functions, called by `replica-all-in-one.sh`. |
| `bank-apply-password-policy.sh` | Keep as `steps/apply-password-policy.sh` (bank-specific, sourced from lib). |
| `bank-add-orclisenabled.sh` | Keep as `steps/add-orclisenabled.sh` (bank-specific schema). |

## Files Deleted (26 removed)

```
0-clean-openldap.sh, 0-clean-openldap.sh (→ lib/install.sh reset function)
1-install-symas-openldap.sh, 3-install-example.sh, 4-Start-the-daemon.sh
5-fix_all_symas_warns.sh, 6-fix_remaining_symas_warns.sh, 7-verify_symas_openldap.sh
8-create_top_ous.sh, 8.0-fix_ldapi_acl.sh, 9-password_policy.sh
9.0-password_policy_load_module.sh, 10-ppolicy-container.sh
10.0-password_policy_make_default.sh, 11-fix_version_warns.sh, 14-next-steps.sh
20-migration.sh, 21-hardening.sh, 22-tuning.sh, 23-ensure-installation-not-under-root.sh
fix-master.sh, fix-master-checksum.sh, fix-replica.sh, fix-replica-syncrepl-tls.sh
verify-master.sh, verify-replica.sh, verify-post-fix.sh
bank-fix-all.sh, deploy-fix-pipeline.sh, test-openldap-connections.sh (moved)
```

## Remaining Existing Scripts (kept, possibly moved)

| Script | New Location/Notes |
|--------|-------------------|
| `12-Create_custom_schema.sh` | Logic → `lib/configure.sh` |
| `13-Create_custom_schema_attr.sh` | Logic → `lib/configure.sh` |
| `15-add-password-checker.sh` | Logic → `lib/configure.sh` |
| `16-add-strong-password-quality-checker-PPM.sh` | Logic → `lib/configure.sh` |
| `17-create_mw_user.sh` | Logic → `lib/configure.sh` |
| `18-service-account-password-policy-never-expire.sh` | Logic → `lib/configure.sh` |
| `19-create-user-using-mw-user.sh` | Keep in `steps/` as test helper |
| `24-configure-ssl-tls.sh` | Logic → `lib/configure.sh` |
| `25-configure-accesslog-audit.sh` | Logic → `lib/configure.sh` |
| `26-configure-bindings.sh` | Logic → `lib/configure.sh` |
| `27-configure-mw-acl.sh` | Logic → `lib/configure.sh` |
| `audio-test.sh` | Keep in `script/` |
| `bank-apply-password-policy.sh` | Move to `steps/apply-password-policy.sh` |
| `bank-add-orclisenabled.sh` | Move to `steps/add-orclisenabled.sh` |
| `install-symas-openldap-all-in-one.sh` | **Replaced** by `master-all-in-one.sh` |
| `install-symas-openldap-replica-all-in-one.sh` | **Replaced** by `replica-all-in-one.sh` |
| `replica/r1-r9-*.sh` | Logic → `lib/configure.sh` + `lib/fix.sh` |
| `replica/test/*.sh` | Move to `test/integration-replica.sh` |
| `test/test_*.sh` | Consolidate into `test/integration-master.sh` + `test/smoke.sh` |
| `Exampledb/exampledb.sh` | Logic → `lib/install.sh` |
| `TODO.txt`, `script.md`, `SCRIPT_GUIDE.md` | Update SCRIPT_GUIDE.md for new structure |

## Implementation Order

1. Create new branch from `Development`
2. Create `lib/` directory, write `lib/common.sh` (color, logging, section headers)
3. Write `lib/ldap-ops.sh` (wrapper functions for all LDAP operations)
4. Write `lib/install.sh` (package install, service setup, env fix, reset)
5. Write `lib/configure.sh` (cn=config, TLS, replication, ppolicy, schema, OUs)
6. Write `lib/harden.sh` (security hardening)
7. Write `lib/tune.sh` (performance tuning)
8. Write `lib/verify.sh` (health checks, auto-detect role)
9. Write `lib/fix.sh` (self-healing functions)
10. Write `lib/diag.sh` (diagnostics, log collection, reports)
11. Write `master-all-in-one.sh` (orchestrate lib functions for master)
12. Write `replica-all-in-one.sh` (orchestrate lib functions for replica)
13. Write `steps/` ad-hoc scripts (thin wrappers sourcing lib)
14. Consolidate tests into `test/smoke.sh`, `test/integration-master.sh`, `test/integration-replica.sh`
15. Move schema .ldif files to `schema/`
16. Delete 26 old files
17. Update `SCRIPT_GUIDE.md`
18. Run `bash deploy-tls-lab.sh` to verify nothing broke
