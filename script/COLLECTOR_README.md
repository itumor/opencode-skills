# Symas OpenLDAP Diagnostic Collector

## What it does
Collects a full diagnostic bundle from a Symas OpenLDAP RHEL 9 host (master or replica):
- Runtime config (`cn=config` / `slapd.d`)
- All LDAP diagnostics: ppolicy overlay, syncprov, syncrepl, ACLs, schema, TLS, monitor
- Systemd service status, journalctl logs, syslog
- File permissions, SELinux contexts, package versions
- TLS certificate metadata (subject, expiry, fingerprint)
- Entry count + top-level DNs only (no user/employee/customer data)

## PRIVACY: No User Data Exported
- **Does NOT dump LDAP user/employee/customer entries** — no `slapcat -n 1` data dump
- Entry counts and top-level organizational DNs only (no attributes, no user DNs)
- All LDAP queries target `cn=config` only (zero data reads)
- Safe for bank, financial, healthcare, and PII-sensitive deployments

## Security
- **Redacts passwords** by default (`olcRootPW`, `userPassword`, `credentials`, etc.)
- **Redacts email addresses** from logs and command output
- **Skips private keys** by default
- **Skips raw LMDB** by default
- Output bundle is `chmod 700`

## Usage

### Copy to host
```bash
scp collect-symas-diagnostics.sh user@192.0.2.10:/tmp/script/
```

### Run on master
```bash
ssh user@192.0.2.10
sudo bash /tmp/script/collect-symas-diagnostics.sh --since "30 days ago"
```

### Run on replica
```bash
ssh user@192.0.2.11
sudo bash /tmp/script/collect-symas-diagnostics.sh --since "30 days ago"
```

### Copy output back
```bash
scp user@192.0.2.10:/tmp/symas-openldap-collect-*.tar.gz ./
scp user@192.0.2.11:/tmp/symas-openldap-collect-*.tar.gz ./
```

### Review before sharing
```bash
tar -tzf symas-openldap-collect-HOST-*.tar.gz | less
grep -RniE 'password|credential|secret|token|private|userPassword|olcRootPW|@.*\.' /tmp/symas-openldap-collect-*
```

## What you get
```
symas-openldap-collect-HOST-TIMESTAMP.tar.gz
└── SUMMARY.md              ← quick overview
├── meta/                   ← collector log, README
├── system/                 ← detected services list
├── commands/               ← all diagnostic command outputs:
│   ├── cn-config-*.txt     ← ppolicy, syncprov, syncrepl, ACLs, schema, TLS
│   ├── slapcat-config-n0.txt ← full config LDIF (redacted)
│   ├── slapcat-data-stats.txt ← entry count + top-level DNs only
│   ├── slaptest-config-check.txt
│   ├── journal-*.txt       ← service logs
│   └── ...
├── files/                  ← copied config files (redacted)
│   ├── opt/symas/etc/openldap/slapd.d/
│   ├── opt/symas/etc/openldap/schema/
│   ├── opt/symas/etc/openldap/ldap.conf
│   └── ...
├── logs/                   ← log extracts
├── ldap/                   ← LDAP query results
└── errors/                 ← any errors encountered
```

## Options
| Flag | What |
|------|------|
| `--since "14 days ago"` | Time range for journal/logs |
| `--include-raw-db` | Copy raw data.mdb — DANGER: all user data. Approval required. |
| `--include-private-keys` | Copy TLS private keys (approval required) |
| `--no-redaction` | Skip password/email redaction |
| `--service symas-openldap` | Explicit service name hint |
