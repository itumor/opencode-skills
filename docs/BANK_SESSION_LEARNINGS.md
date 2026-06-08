# Bank Deployment — Session Learnings

2026-06-03

## IPs & Credentials

| Item | Old | New |
|------|-----|-----|
| Master IP | 172.23.11.236 | **52.43.173.218** (public) |
| Replica IP | 172.23.11.237 | **35.91.98.69** (public) |
| Admin password | `admin` | **`TheN1le1`** |
| Replication password | `replpass` | unchanged |
| Base DN | `dc=eab,dc=bank,dc=local` | unchanged |
| Server hostname | — | `ciamuapplds01` (master) |

## Findings

### 1. `slappasswd` missing on bank server

`/opt/symas/bin/slappasswd` absent on `ciamuapplds01`. `ldapadd` and other Symas tools present at `/opt/symas/bin/`.

**Workaround A** — Generate SSHA hash locally, embed inline:

```bash
python3 -c "
import hashlib, base64, os
salt = os.urandom(8)
h = hashlib.sha1(b'replpass')
h.update(salt)
digest = base64.b64encode(h.digest() + salt).decode()
print('{SSHA}' + digest)
"
# Output: {SSHA}vDJL5DOYxkOOv62uR/0boOhJItyq51qwdcORIA==
```

Use hash inline in LDIF. No `$REPL_HASH` variable needed.

**Workaround B** — Install clients package (if repo configured):

```bash
dnf install -y symas-openldap-clients
# then: /opt/symas/sbin/slappasswd -s replpass
```

### 2. TLS enforced (self-signed cert)

Bank server requires TLS for binds. Self-signed certs cause:

```
ldap_bind: Confidentiality required (13)
ldap_start_tls: Connect error (-11) — certificate verify failed (self-signed certificate)
```

**Fix**: Prefix all commands with `LDAPTLS_REQCERT=never`, use `-ZZ`:

```bash
LDAPTLS_REQCERT=never /opt/symas/bin/ldapadd -x -H ldap://localhost:389 -ZZ \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" ...
```

### 3. Command patterns

**Bind test (both nodes):**

```bash
# Master
LDAPTLS_REQCERT=never ldapwhoami -x -ZZ \
  -H ldap://52.43.173.218:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1"

# Replica
LDAPTLS_REQCERT=never ldapwhoami -x -ZZ \
  -H ldap://35.91.98.69:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1"
```

**Add entry on master:**

```bash
LDAPTLS_REQCERT=never /opt/symas/bin/ldapadd -x -H ldap://localhost:389 -ZZ \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" <<'LDIF'
dn: cn=test33,dc=eab,dc=bank,dc=local
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: test33
userPassword: {SSHA}vDJL5DOYxkOOv62uR/0boOhJItyq51qwdcORIA==
description: Replication bind user
LDIF
```

**Verify replication (query replica for entry added on master):**

```bash
LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
  -H ldap://35.91.98.69:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  -b "cn=test33,dc=eab,dc=bank,dc=local" -s base dn

# Expected: dn: cn=test33,dc=eab,dc=bank,dc=local
```

**List all entries:**

```bash
LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
  -H ldap://52.43.173.218:389 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  -b "dc=eab,dc=bank,dc=local" -s one "(objectClass=*)" dn
```

**Via LDAPS (port 636):**

```bash
LDAPTLS_REQCERT=never ldapsearch -x \
  -H ldaps://52.43.173.218:636 \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  -b "dc=eab,dc=bank,dc=local" -s base dn
```

### 4. Local commands (on server via SSH)

On master (`ciamuapplds01`):

```bash
# Source Symas env first
source /etc/profile.d/symas_env.sh

# Bind test (localhost)
LDAPTLS_REQCERT=never ldapwhoami -x -ZZ \
  -H ldap://localhost -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1"

# List all entries
LDAPTLS_REQCERT=never ldapsearch -x -ZZ \
  -H ldap://localhost \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" \
  -b "dc=eab,dc=bank,dc=local" -s sub "(objectClass=*)" dn

# LDAPI (no password, root only)
sudo ldapsearch -Y EXTERNAL -H ldapi:/// \
  -b "dc=eab,dc=bank,dc=local" -LLL dn
```

### 5. Logs

OpenLDAP logs → systemd journal by default.

```bash
# Recent slapd logs
journalctl -u slapd --no-pager | tail -100

# If service name differs
journalctl -u symas-openldap-servers --no-pager | tail -100

# Follow live
journalctl -u slapd -f

# Syslog fallback
tail -100 /var/log/messages | grep -i slapd
```

Find service name:
```bash
systemctl list-units --type=service | grep -i ldap
```

## BANK_DEPLOYMENT.md updates needed

- [ ] Admin password `admin` → `TheN1le1`
- [ ] Add public IPs (52.43.173.218, 35.91.98.69)
- [ ] Document `slappasswd` missing → SSHA hash workaround
- [ ] Add `LDAPTLS_REQCERT=never` to all command examples
- [ ] Add server hostname `ciamuapplds01`
- [ ] Add logs section
