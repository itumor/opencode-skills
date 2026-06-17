# Symas OpenLDAP Diagnostic Collector

## What it does
Collects a full diagnostic bundle from a Symas OpenLDAP RHEL 9 host (master or replica):
- Runtime config (`cn=config` / `slapd.d`)
- All LDAP diagnostics: ppolicy overlay, syncprov, syncrepl, ACLs, schema, TLS, monitor
- Systemd service status, journalctl logs, syslog
- File permissions, SELinux contexts, package versions
- TLS certificate metadata (subject, expiry, fingerprint)
- Optional: `slapcat` data dump, raw LMDB files

## Security
- **Redacts passwords** by default (`olcRootPW`, `userPassword`, `credentials`, etc.)
- **Skips private keys** by default
- **Skips raw LMDB** by default
- Output bundle is `chmod 700`

## Usage

### Copy to host
```bash
scp collect-symas-diagnostics.sh ebrahim@172.23.11.236:/tmp/script/
scp collect-symas-diagnostics.sh ebrahim@172.23.11.237:/tmp/script/
```

### Run on master
```bash
ssh ebrahim@172.23.11.236
sudo bash /tmp/script/collect-symas-diagnostics.sh --since "30 days ago" --include-data-ldif
```

### Run on replica
```bash
ssh ebrahim@172.23.11.237
sudo bash /tmp/script/collect-symas-diagnostics.sh --since "30 days ago" --include-data-ldif
```

### Copy output back
```bash
scp ebrahim@172.23.11.236:/tmp/symas-openldap-collect-*.tar.gz ./
scp ebrahim@172.23.11.237:/tmp/symas-openldap-collect-*.tar.gz ./
```

### Review before sharing
```bash
tar -tzf symas-openldap-collect-HOST-*.tar.gz | less
grep -RniE 'password|credential|secret|token|private|userPassword|olcRootPW' /tmp/symas-openldap-collect-*
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
| `--include-data-ldif` | Include `slapcat -n 1` data dump |
| `--include-raw-db` | Copy raw data.mdb (approval required) |
| `--include-private-keys` | Copy TLS private keys (approval required) |
| `--no-redaction` | Skip password redaction |
| `--service symas-openldap` | Explicit service name hint |
