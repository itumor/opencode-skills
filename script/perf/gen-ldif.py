#!/usr/bin/env python3
"""Generate 1.5M LDAP user entries for performance testing.
Usage: python3 gen-ldif.py <count> [password] > output.ldif
"""

import sys
import os
import hashlib
import base64

def ssha_hash(password):
    salt = os.urandom(8)
    sha1 = hashlib.sha1(password.encode())
    sha1.update(salt)
    digest = sha1.digest()
    return '{SSHA}' + base64.b64encode(digest + salt).decode()

def generate(count, password, base_dn):
    print("# Generated LDIF - {} users".format(count))
    print("# Base DN: {}".format(base_dn))
    print()

    # Use one pre-computed SSHA for all users (massively faster generation)
    pw_hash = ssha_hash(password)

    batch = []
    for i in range(1, count + 1):
        uid = "user{:07d}".format(i)
        dn = "uid={},ou=Users,{}".format(uid, base_dn)
        cn = "User {:07d}".format(i)
        sn = "{:07d}".format(i)
        mail = "{}@bank.local".format(uid)

        batch.append("""\
dn: {}
objectClass: inetOrgPerson
objectClass: organizationalPerson
objectClass: person
objectClass: top
uid: {}
cn: {}
sn: {}
mail: {}
userPassword: {}

""".format(dn, uid, cn, sn, mail, pw_hash))

        # Flush batch every 5000 entries
        if len(batch) >= 5000:
            sys.stdout.write(''.join(batch))
            batch = []

    if batch:
        sys.stdout.write(''.join(batch))

if __name__ == '__main__':
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 1500000
    password = sys.argv[2] if len(sys.argv) > 2 else "Test123!"
    base_dn = sys.argv[3] if len(sys.argv) > 3 else "dc=eab,dc=bank,dc=local"
    generate(count, password, base_dn)
