# Bank / Satellite Deployment Quickstart

For RHEL 9 environments with Satellite-managed repos (e.g., bank).

## Key Differences from AWS

| Aspect | AWS | Bank |
|--------|-----|------|
| Packages | Downloaded from repo.symas.com | Pre-installed via Satellite (`/etc/yum.repos.d/symas.repo`) |
| TLS hardening | Opt-in (`OPENLDAP_HARDEN=yes`) | Off by default |
| Repo setup | Automatic | Skip with `SKIP_REPO_SETUP=1` |

## Master Install

```bash
sudo SKIP_REPO_SETUP=1 TLS_MODE=yes bash script/install-symas-openldap-all-in-one.sh
```

- `SKIP_REPO_SETUP=1` — trusts Satellite has packages available
- No `OPENLDAP_HARDEN` means TLS hardening (olcSecurity simple_bind, TLSProtocolMin, cipher suite) is **not** applied
- If you want hardening, add `OPENLDAP_HARDEN=yes`

## Replica Install

```bash
sudo SKIP_REPO_SETUP=1 MASTER_IP=<master-ip> ADMIN_PW=<admin-pw> REPL_PW=replpass \
     TLS_MODE=yes COPY_FROM_MASTER=1 \
     STAGED_CA_CERT=/tmp/master-ca.crt STAGED_CA_KEY=/tmp/master-ca.key \
     bash script/install-symas-openldap-replica-all-in-one.sh
```

## Hardening (Optional)

If security policy requires TLS hardening, add `OPENLDAP_HARDEN=yes` to both master and replica install commands. This applies:

- `olcSecurity: simple_bind=128` — simple binds require encryption
- `olcTLSProtocolMin: 3.3` — TLS 1.2 minimum
- `olcTLSCipherSuite` — restrict ciphers to `HIGH:!aNULL:!eNULL:!MD5:!RC4:!3DES:!DES:!NULL`

## Key Env Vars

| Var | Default | Notes |
|-----|---------|-------|
| `SKIP_REPO_SETUP` | `auto` | Set `1` for Satellite-managed repos |
| `OPENLDAP_HARDEN` | `no` | Set `yes` to enable TLS hardening |
| `TLS_MODE` | `yes` | `no` skips TLS certs |
| `ADMIN_PW` | — | Required. Default base DN: `dc=eab,dc=bank,dc=local` |

## Pre-Flight

Packages must already be installed or resolvable:
```bash
dnf info symas-openldap-clients symas-openldap-servers
```
If Satellite is configured, this should resolve package info. If not, ensure your admin has set up `/etc/yum.repos.d/symas.repo`.
