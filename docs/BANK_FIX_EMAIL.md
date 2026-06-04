Subject: OpenLDAP Replication Fix — Scripts for ciamuapplds01/ciamuapplds02

Hi Salama,

We analysed the Symas OpenLDAP logs from the bank deployment
(ciamuapplds01.eab.bank.local, covering May 24 through Jun 03 2026) and found
that replication between the master and replica was not working.

## What We Found

The master was hardened to require TLS for all password-based binds, but the
replica's syncrepl configuration was still sending credentials in plain text.
Every replication attempt (14 in total) was rejected by the master with
"err=13 confidentiality required".

The logs also showed a TLS negotiation failure on port 636 and a cn=config
checksum warning on the master.

## What We Did

We created four self-contained scripts that fix all issues and verify the
result. They run directly on each server as root — no external tools needed.

## Attachments

| File | Run On | What It Does |
|------|--------|--------------|
| fix-master.sh | 172.23.11.236 (ciamuapplds01) | Rebuild cn=config checksums, add syncrepl indices |
| fix-replica.sh | 172.23.11.237 | Update syncrepl to use StartTLS, load ppolicy module, generate TLS certs |
| verify-master.sh | 172.23.11.236 | 16-point health check (service, ports, binds, indices, log analysis) |
| verify-replica.sh | 172.23.11.237 | 17-point sync verification (data, config, contextCSN, write rejection) |
| BANK_FIX_GUIDE.md | — | Full guide with steps, expected results, and troubleshooting |

## Running the Fix

On the master:

    scp fix-master.sh verify-master.sh root@172.23.11.236:/tmp/
    ssh root@172.23.11.236
    sudo bash /tmp/fix-master.sh
    sudo ADMIN_PW='TheN1le1' bash /tmp/verify-master.sh

On the replica:

    scp fix-replica.sh verify-replica.sh root@172.23.11.237:/tmp/
    ssh root@172.23.11.237
    sudo bash /tmp/fix-replica.sh
    sudo ADMIN_PW='TheN1le1' bash /tmp/verify-replica.sh

The scripts will report PASS/FAIL for each check. If any check fails, the
output will show which one and suggest a fix.

## Expected Result

After running both fix scripts:
- Zero err=13 (confidentiality required) errors
- Zero TLS negotiation failures
- Entry counts match between master and replica
- contextCSN matches between master and replica
- Entries created on the master appear on the replica within seconds

## Verification

We tested these scripts end-to-end in our AWS lab:
- Fresh RHEL 9 deploy → master + replica install → fix scripts → verify
- 13/13 entries synced
- All log checks passed (0 errors, 0 warnings on replica)
- E2E replication confirmed in <10 seconds

The complete guide is in BANK_FIX_GUIDE.md. Please run the scripts and let us
know the verify output. We're available to assist if anything needs adjusting.

Regards
