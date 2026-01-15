# NEXTGenopen

Repository notes, labs, and runbooks for OpenLDAP modernization work.

## Labs and docs

- OpenLDAP MirrorMode lab: `openldap-mirrormode/README.md`
- OID modernization docs: `GAP_ANALYSIS_OID_to_OpenLDAP_Modernization.md` and `OID_to_OpenLDAP_Modernization_Requirements.md`

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

If you want, I can extend this doc with a production hardening appendix (TLS/StartTLS, secure ciphers, disabling anonymous binds, audit logging, backup/restore via `slapcat`, and a systemd drop-in that matches your expected runtime/data dirs).
