# NEXTGenopen

Repository notes, labs, and runbooks for OpenLDAP modernization work.

## Labs and docs

- OpenLDAP MirrorMode lab: `openldap-mirrormode/README.md`
- OID modernization docs: `GAP_ANALYSIS_OID_to_OpenLDAP_Modernization.md` and `OID_to_OpenLDAP_Modernization_Requirements.md`
- LDAP implementation notes (schema/OID/TLS/accesslog): `script/LDAP-implementation-notes.md`

---

## Symas OpenLDAP 2.6 LTS on RHEL 9.6 — Full Install & Bring-Up Runbook

This runbook installs Symas OpenLDAP 2.6 LTS on RHEL 9.6, initializes a working configuration using Symas’ supported tooling, applies SELinux/systemd best practices, and validates the service.

Sources: Symas LTS install page for RHEL9, plus Symas systemd + SELinux guidance and Symas KB articles (`repo.symas.com`, `kb.symas.com`).

### 0) Prereqs

Run everything as Linux `root` (this is separate from LDAP “rootDN” / admin password).

```bash
sudo -i
cat /etc/redhat-release
hostnamectl
```

Optional (recommended): reboot if kernel/glibc gets updated by `dnf update`.

### 1) Add Symas LTS repo + install packages (official Symas commands)

These commands are taken directly from Symas’ RHEL9 LTS instructions.

```bash
wget -q https://repo.symas.com/configs/SOLDAP/rhel9/release26.repo -O /etc/yum.repos.d/soldap-release26.repo
dnf update
dnf install symas-openldap-clients symas-openldap-servers
```

Confirm installed version (Symas notes current LTS version on the page):

```bash
/opt/symas/lib/slapd -VV || /opt/symas/sbin/slapd -VV || slapd -VV
```

### 2) Make Symas tools available in your shell (fix “ldapsearch not found”)

Symas installs LDAP utilities under `/opt/symas/bin` and `/opt/symas/sbin`. Add them to `PATH` and set LDAP client defaults if desired.

#### Option A — per-user (root) quick fix

```bash
export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
export LDAPCONF=/opt/symas/etc/openldap/ldap.conf
```

#### Option B — system-wide (recommended)

Create `/etc/profile.d/symas_env.sh` like Symas KB suggests:

```bash
cat >/etc/profile.d/symas_env.sh <<'EOF'
if [ -d "/opt/symas" ]; then
  export LDAPCONF=/opt/symas/etc/openldap/ldap.conf
  export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
  export MANPATH=$MANPATH:/opt/symas/share/man
fi
EOF
chmod +x /etc/profile.d/symas_env.sh
source /etc/profile.d/symas_env.sh
```

Verify:

```bash
which ldapsearch
ldapsearch -VV
```

### 3) Initialize configuration & database (recommended: Symas `exampledb.sh`)

Symas provides an official rapid deployment script that:

- Creates a generic config (`slapd.conf` and `symas-openldap.conf`)
- Installs an example database
- Starts `slapd`

This is Symas’ supported “get running fast” path.

```bash
cd /opt/symas/share/symas
./exampledb.sh
```

When prompted, type `YES` in all caps (as Symas instructs).

The script will also prompt for config style (static `slapd.conf` vs dynamic `cn=config`). Pick what you want:

- Static is simpler for learning.
- Dynamic (`cn=config`) is preferred long-term (online changes, better automation).

### 4) SELinux (RHEL 9.6) — required if you use `cn=config`

On RHEL8+ Symas provides an SELinux profile, but you must create the `slapd.d` directory and label it before using `cn=config`.

```bash
cd /opt/symas/etc/openldap
mkdir -p slapd.d
restorecon -RvF /opt/symas/etc/openldap/slapd.d
```

If you skip this, modifying `cn=config` on the fly may fail under SELinux enforcement.

### 5) systemd review & tuning (Symas-supported)

#### 5.1 Identify service unit name

Symas packaging commonly uses `symas-openldap-servers.service` with an alias/target often referenced as `slapd`.

```bash
systemctl list-unit-files | egrep -i 'slapd|symas-openldap'
systemctl status symas-openldap-servers --no-pager || true
systemctl status slapd --no-pager || true
```

#### 5.2 Start the daemon (official Symas step)

Symas’ RHEL9 LTS page uses:

```bash
systemctl start slapd
```

In environments where the concrete unit name is required, use:

```bash
systemctl start symas-openldap-servers
```

Enable at boot:

```bash
systemctl enable symas-openldap-servers
```

#### 5.3 Optional: raise file descriptor limits (high load)

Symas provides a systemd drop-in example:

```bash
mkdir -p /etc/systemd/system/symas-openldap-servers.service.d
cat >/etc/systemd/system/symas-openldap-servers.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=524288
EOF
systemctl daemon-reload
systemctl restart slapd
```

#### 5.4 Optional: change listen URLs / run as `ldap` user

Symas documents overriding defaults via `/etc/default/symas-openldap`:

- `SLAPD_URLS` (ldap/ldaps/ldapi)
- `SLAPD_OPTIONS` (e.g., `-u ldap -g ldap`)

Example:

```bash
sed -i 's|^SLAPD_URLS=.*|SLAPD_URLS="ldap:/// ldaps:/// ldapi:///"|g' /etc/default/symas-openldap || true
sed -i 's|^SLAPD_OPTIONS=.*|SLAPD_OPTIONS="-u ldap -g ldap"|g' /etc/default/symas-openldap || true
systemctl restart slapd
```

### 6) Firewall (if this host should accept remote LDAP/LDAPS)

Open port `389/tcp` for LDAP and `636/tcp` for LDAPS (if enabled).

```bash
firewall-cmd --permanent --add-port=389/tcp
firewall-cmd --permanent --add-port=636/tcp
firewall-cmd --reload
```

### 7) Validate the service (local)

#### 7.1 Confirm listener

```bash
ss -tulnp | grep slapd
```

#### 7.2 RootDSE query (no auth)

Use Symas `ldapsearch` (now in `PATH` if you did section 2):

```bash
ldapsearch -x -H ldap://localhost -b "" -s base
```

Expected: returns RootDSE attributes (at minimum `dn:`).

### 8) Common pitfalls (from install history + Symas notes)

#### A) `ldapsearch: command not found`

Install clients + ensure `/opt/symas/bin` is in `PATH`:

```bash
dnf install -y symas-openldap-clients
export PATH=/opt/symas/bin:/opt/symas/sbin:$PATH
```

#### B) Wrong module path in configs

Symas notes the module path must be:

```text
/opt/symas/lib/openldap
```

#### C) SELinux blocks `cn=config` updates

Create `slapd.d` and relabel it exactly as Symas documents (section 4).

### 9) Notes on “root user/password root”

- Linux `root` is only for installing/managing packages and services.
- LDAP admin auth is controlled by the `rootDN/rootPW` (or `olcRootDN/olcRootPW` in `cn=config`).
- If you set LDAP admin password to `root` for a lab, hash it (don’t store plaintext).

### 10) Reference links

- Symas OpenLDAP 2.6 RHEL9 LTS install page (commands & version): `repo.symas.com`
- Symas systemd configuration (limits, `SLAPD_URLS`/`SLAPD_OPTIONS`): `repo.symas.com`
- Symas SELinux notes for `cn=config`: `repo.symas.com`
- Symas KB: Installing OpenLDAP (2.5 and later) + `exampledb.sh`: `kb.symas.com`
- Symas KB: Environment configuration (`PATH`/`LDAPCONF`): `kb.symas.com`
- OpenLDAP 2.6 Admin Guide (general configuration/security): `openldap.org`

---

## Scripts (`script/`)

Note: this repo uses `script/` (singular). There is no `scripts/` directory.

The goal of the scripts is to make a Symas OpenLDAP (RHEL9) lab reproducible: install, configure `cn=config`, enable password policy + complexity, create example service/users, apply hardening/tuning, and validate via tests.

Secure transport defaults:
- Listener mode defaults to `starttls_and_ldaps` (`389` for StartTLS, `636` for LDAPS).
- TLS for simple binds is expected; plain simple bind on `389` is rejected when hardening is enabled.
- **`TLS_MODE=no`** on the orchestrator scripts skips TLS cert generation and TLS hardening. Syncrepl uses plain `ldap://` instead of `starttls=yes`. Plain LDAP binds work on port 389.
- `script/24-configure-ssl-tls.sh` cert modes:
  - `TLS_CERT_MODE=external_or_self_signed` (default)
  - `TLS_CERT_MODE=self_signed`
  - `TLS_CERT_MODE=external_required` with `TLS_CA_CERT_PEM`, `TLS_CERT_PEM`, `TLS_KEY_PEM`

| Script | What It Does (Short) | Why We Need It | Notes / Overlaps |
|---|---|---|---|
| `script/0-clean-openldap.sh` | Stops services, removes Symas packages + `/opt/symas` + `/var/symas`, cleans firewall ports | Fast “reset to zero” for repeatable labs | Destructive; root only |
| `script/1-install-symas-openldap.sh` | Adds Symas repo + installs Symas OpenLDAP packages | Base install step | Root only |
| `script/3-install-example.sh` | Replaces Symas `exampledb.sh` with repo version, then runs it non-interactively | Bootstraps DB + `cn=config` quickly | Uses `script/Exampledb/exampledb.sh` |
| `script/4-Start-the-daemon.sh` | Starts/enables/restarts slapd units | Brings service up after install | Very manual; other scripts also restart |
| `script/5-fix_all_symas_warns.sh` | Creates `/etc/profile.d/symas_env.sh`, sets listeners, restarts, opens firewall ports | Removes common Symas verification WARNs | Pairs with `script/6-fix_remaining_symas_warns.sh` |
| `script/6-fix_remaining_symas_warns.sh` | Ensures `slapd` path expectations + generates minimal TLS + enables LDAPS | Fixes remaining WARNs + gets LDAPS listening | Online config first, offline fallback |
| `script/7-verify_symas_openldap.sh` | Runs local checks: packages, service unit, listeners, RootDSE, firewall, SELinux hints | Quick “is the host OK?” gate | Used by the orchestrators |
| `script/8.0-fix_ldapi_acl.sh` | Fixes `cn=config` ACL for `SASL/EXTERNAL` manage and can reset `olcRootPW` | Unblocks automation that uses `ldapi:///` | Root only; touches `slapd.d` |
| `script/8-create_top_ous.sh` | Creates top-level OUs for the chosen base DN (lab structure) | Standardizes DIT layout used by later scripts | Depends on exampledb/base DN |
| `script/9-password_policy.sh` | Loads `ppolicy` module path/load into `cn=config` (module list) | Enables password policy module | Overlaps with later PPolicy work; keep with `9.0/10.*` sequence |
| `script/9.0-password_policy_load_module.sh` | Adds `ppolicy` overlay to the main DB | Makes ppolicy active for the database | Run before PPolicy defaults |
| `script/10-ppolicy-container.sh` | Creates `ou=Policies` + a `cn=default` `pwdPolicy` entry | Provides actual policy objects | Uses simple bind (`cn=admin,...`) |
| `script/10.0-password_policy_make_default.sh` | Sets `olcPPolicyDefault` to the `cn=default` policy DN | Makes default policy effective | `ldapi:///` EXTERNAL |
| `script/11-fix_version_warns.sh` | Patches verification script to capture version output correctly | Avoids false “version WARN” | Edits `script/7-verify_symas_openldap.sh` |
| `script/12-Create_custom_schema.sh` | Creates a custom schema container in `cn=config` | Prereq for custom attributes/objectClasses | Used before `13-*` |
| `script/13-Create_custom_schema_attr.sh` | Adds custom attributeTypes + objectClass (bank extension) | Models app-specific attributes | Depends on `12-*` |
| `script/14-next-steps.sh` | Prints the recommended order of scripts | Simple operator guide | Informational only |
| `script/15-add-password-checker.sh` | Ensures `pwdPolicyChecker` and sets `pwdCheckQuality` | Turns on password checks in policy | Overlaps with first part of `10.3` |
| `script/16-add-strong-password-quality-checker-PPM.sh` | Strong password policy: config + PPM rules + policy wiring | “Real” password complexity baseline | Recommended vs `10.1/10.2/10.3` experiments |
| `script/17-create_mw_user.sh` | Creates a `mw` service account (bind user) under ServiceAccounts | Enables app-like bind flows | Uses exampledb admin creds |
| `script/18-service-account-password-policy-never-expire.sh` | Creates/updates a service-account password policy with `pwdMaxAge: 0` | Prevents service accounts from expiring | Requires `ou=Policies` |
| `script/19-create-user-using-mw-user.sh` | Creates an example user entry using the `mw` bind user | Demonstrates delegated provisioning | Supports `DRY_RUN=1` |
| `script/20-migration.sh` | Placeholder for migration steps | Stub for future | Currently empty/no-op |
| `script/21-hardening.sh` | Hardening: disable anon bind, require TLS for simple binds, tighten TLS params, perms | Moves lab config toward “production-ish” | Supports `OPENLDAP_REQUIRE_TLS_SIMPLE_BINDS` alias |
| `script/22-tuning.sh` | Systemd drop-in for `LimitNOFILE`; optional `SLAPD_URLS`/`SLAPD_OPTIONS` | Performance + listener tuning | Idempotent; restarts only if needed |
| `script/23-ensure-installation-not-under-root.sh` | Verifies Symas install paths are not under `/root` | Avoids bad filesystem layout | Mostly a compliance/guardrail check |
| `script/24-configure-ssl-tls.sh` | Configures TLS in `cn=config` + updates `ldap.conf`; supports external PEM or self-signed certs | Enables StartTLS/LDAPS correctly | Keeps serverID-safe listener defaults |
| `script/25-configure-accesslog-audit.sh` | Configures `accesslog` module, DB, and overlay for audit logging | Adds write/read/session audit trails | Requires `cn=config` access |
| `script/install-symas-openldap-all-in-one.sh` | Runs the full sequence (install through hardening + tests) | One-command lab bring-up | Supports `TLS_MODE=yes` (default) or `TLS_MODE=no` |
| `script/install-symas-openldap-replica-all-in-one.sh` | Runs full replica sequence (r1–r9 + tests) | One-command replica bring-up | Requires `MASTER_IP`, `ADMIN_PW`; supports `TLS_MODE=no` |
| `script/Exampledb/exampledb.sh` | Customized Symas `exampledb.sh` (base DN/suffix/etc.) | Standardizes lab naming/passwords | Consumed by `3-install-example.sh` |
| `script/audio-test.sh` | Plays an audible confirmation sound | Operator feedback / CI hooks | Used by agent workflow |

### Duplicate/Overlap Notes (And Which One To Prefer)

- `script/15-add-password-checker.sh` vs `script/16-add-strong-password-quality-checker-PPM.sh`: prefer `script/16-add-strong-password-quality-checker-PPM.sh` if you want strong password complexity via PPM; use `script/15-add-password-checker.sh` only for basic checker enablement.

### Testing

Local (no LDAP required) smoke tests:

```bash
bash script/test/run_all.sh
```

LDAP integration tests (run later on your real RHEL/RedHat environment):

```bash
RUN_LDAP_INTEGRATION_TESTS=1 bash script/test/run_all.sh
```
