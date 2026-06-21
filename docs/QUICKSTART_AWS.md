# AWS Lab Quickstart

Deploy OpenLDAP master + replica on the AWS lab in ~5-7 minutes.

## One-Command Deploy

```bash
bash deploy-tls-lab.sh
```

This runs a full clean-install with TLS enabled and security hardening applied:
- `TLS_MODE=yes` — StartTLS + LDAPS
- `OPENLDAP_HARDEN=yes` — `olcSecurity: simple_bind=128`, TLS protocol min, cipher suite
- Packages from repo.symas.com

## Manual Master Install

```bash
sudo TLS_MODE=yes OPENLDAP_HARDEN=yes bash script/install-symas-openldap-all-in-one.sh
```

## Manual Replica Install

```bash
sudo MASTER_IP=<master-private-ip> ADMIN_PW=<admin-pw> REPL_PW=replpass \
     TLS_MODE=yes OPENLDAP_HARDEN=yes COPY_FROM_MASTER=1 \
     STAGED_CA_CERT=/tmp/master-ca.crt STAGED_CA_KEY=/tmp/master-ca.key \
     bash script/install-symas-openldap-replica-all-in-one.sh
```

## Key Env Vars

| Var | Default | Notes |
|-----|---------|-------|
| `TLS_MODE` | `yes` | `no` skips TLS certs |
| `OPENLDAP_HARDEN` | `no` | `yes` enables TLS hardening (olcSecurity, TLSProtocolMin, ciphers) |
| `SKIP_REPO_SETUP` | `auto` | `auto` detects, `1` skips, `0` forces download |
