# Bank Deployment — Session Learnings

Session date: 2026-06-03

## Updated IPs & Credentials

| Item | Old Value | New Value (this session) |
|------|-----------|--------------------------|
| Master IP | 172.23.11.236 | **52.43.173.218** (public) |
| Replica IP | 172.23.11.237 | **35.91.98.69** (public) |
| Admin password | `admin` | **`TheN1le1`** |
| Replication password | `replpass` | `replpass` (unchanged) |
| Base DN | `dc=eab,dc=bank,dc=local` | unchanged |
| Server hostname | — | `ciamuapplds01` (master) |

## Key Findings

### 1. `slappasswd` is missing on bank server

`/opt/symas/bin/slappasswd` does **not** exist on `ciamuapplds01`, though `ldapadd` and other Symas tools are present at `/opt/symas/bin/`.

**Workaround A** — Generate hash locally and embed it:

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

Then use the hash inline in the LDIF (no `$REPL_HASH` variable needed).

**Workaround B** — Install the clients package (may not be possible if repo not configured):

```bash
dnf install -y symas-openldap-clients
# then: /opt/symas/sbin/slappasswd -s replpass
```

### 2. TLS is enforced (self-signed cert)

The bank server requires TLS for binds. Self-signed certs cause:

```
ldap_bind: Confidentiality required (13)
ldap_start_tls: Connect error (-11) — certificate verify failed (self-signed certificate)
```

**Fix**: Always prefix commands with `LDAPTLS_REQCERT=never` and use `-ZZ`:

```bash
LDAPTLS_REQCERT=never /opt/symas/bin/ldapadd -x -H ldap://localhost:389 -ZZ \
  -D "cn=admin,dc=eab,dc=bank,dc=local" -w "TheN1le1" ...
```

### 3. Working command patterns

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

**Verify replication (query replica for an entry just added on master):**

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

### 4. Working local commands (on server via SSH)

On the master server (`ciamuapplds01`):

```bash
# Source Symas environment first
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

### 5. Logs location

OpenLDAP logs to systemd journal by default:

```bash
# View recent slapd logs
journalctl -u slapd --no-pager | tail -100

# Or if service name differs
journalctl -u symas-openldap-servers --no-pager | tail -100

# Follow live
journalctl -u slapd -f

# Syslog fallback
tail -100 /var/log/messages | grep -i slapd
```

Find correct service name:
```bash
systemctl list-units --type=service | grep -i ldap
```

## Checklist for `BANK_DEPLOYMENT.md` updates needed

- [ ] Update admin password from `admin` → `TheN1le1`
- [ ] Add public IPs (52.43.173.218, 35.91.98.69)
- [ ] Document `slappasswd` missing → SSHA hash workaround
- [ ] Add `LDAPTLS_REQCERT=never` to all command examples
- [ ] Add server hostname `ciamuapplds01`
- [ ] Add logs section
