---
name: zoho-mail
description: Send/list emails via Zoho Mail REST API with OAuth 2.0. Use when asked to send email from Zoho, list inbox, or manage Zoho Mail via CLI. Auto-refreshes access tokens.
---

# Zoho Mail API via CLI

## Setup

Credentials in project `.env` (gitignored):
```
ZOHO_CLIENT_ID=1000.CCY8500P0898UFGJXYNWA16G1E4ICQ
ZOHO_CLIENT_SECRET=5d7be3e1e0d79c5c504ac81579a3b44afa1dc3a77c
ZOHO_REFRESH_TOKEN=1000.bf05d0ea29fec8b506aeaf9cbc7894b0.f23f33897d6513baa491bbfa166ef417
```

Account: `ibrahim.timor@nxtedgetechnologies.com`
Account ID: `2204359000000008002`

Self Client registered at https://api-console.zoho.com

## Token Management

Access tokens expire in 1 hour. Always source `.env` and refresh before use:

```bash
source /Users/eramadan/openscript/nextgenopen/.env
TOKEN=$(curl -s -X POST "https://accounts.zoho.com/oauth/v2/token" \
  -d "refresh_token=$ZOHO_REFRESH_TOKEN" \
  -d "grant_type=refresh_token" \
  -d "client_id=$ZOHO_CLIENT_ID" \
  -d "client_secret=$ZOHO_CLIENT_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
```

If refresh fails, the grant code expired — user must generate a new one at https://api-console.zoho.com (Self Client → Generate Grant Token with scopes: `ZohoMail.messages.ALL,ZohoMail.accounts.READ`).

## Endpoints

| Action | Method | URL |
|--------|--------|-----|
| List accounts | GET | `https://mail.zoho.com/api/accounts` |
| List folders | GET | `https://mail.zoho.com/api/accounts/2204359000000008002/folders` |
| List inbox | GET | `https://mail.zoho.com/api/accounts/2204359000000008002/messages/view?folderId=FOLDER_ID&limit=50` |
| Search emails | GET | `https://mail.zoho.com/api/accounts/2204359000000008002/messages/search?searchKey=TERM` |
| Send email | POST | `https://mail.zoho.com/api/accounts/2204359000000008002/messages` |
| Get email content | GET | `https://mail.zoho.com/api/accounts/2204359000000008002/folders/FOLDER_ID/messages/MESSAGE_ID/content` |
| Get email headers | GET | `https://mail.zoho.com/api/accounts/2204359000000008002/folders/FOLDER_ID/messages/MESSAGE_ID/header` |

All requests use header: `Authorization: Zoho-oauthtoken $TOKEN`

## Send Email

```bash
curl -s -X POST "https://mail.zoho.com/api/accounts/2204359000000008002/messages" \
  -H "Authorization: Zoho-oauthtoken $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "fromAddress": "ibrahim.timor@nxtedgetechnologies.com",
    "toAddress": "recipient@example.com",
    "subject": "Subject",
    "content": "Body text"
  }'
```

For attachments, use multipart upload — see `/mail/help/api/post-send-email-attachment.html`.

## List Inbox (full pipeline)

```bash
TOKEN=...  # from refresh above
# Get Inbox folderId
FOLDER_ID=$(curl -s "https://mail.zoho.com/api/accounts/2204359000000008002/folders" \
  -H "Authorization: Zoho-oauthtoken $TOKEN" | \
  python3 -c "import sys,json; data=json.load(sys.stdin)['data']; print([f['folderId'] for f in data if f['folderType']=='Inbox'][0])")

# List emails
curl -s "https://mail.zoho.com/api/accounts/2204359000000008002/messages/view?folderId=$FOLDER_ID&limit=20" \
  -H "Authorization: Zoho-oauthtoken $TOKEN" | python3 -m json.tool
```

## Helper Script

`script/zoho-mail.sh` — unified CLI helper. Usage:
```bash
source .env && bash script/zoho-mail.sh send to@example.com "Subject" "Body"
bash script/zoho-mail.sh inbox [limit]
bash script/zoho-mail.sh search "search term"
bash script/zoho-mail.sh token   # just refresh + print token
```

## OAuth Scopes

| Scope | Purpose |
|-------|---------|
| `ZohoMail.accounts.READ` | Get account ID |
| `ZohoMail.folders.READ` | List folders |
| `ZohoMail.messages.ALL` | Send/read/delete emails |

## Requirements Audit Workflow

After completing any task in nextgenopen, check inbox for new emails from Mostafa (`m.elkady@nxtedgetechnologies.com`) to see if new requirements arrived:

```bash
source .env && bash script/zoho-mail.sh inbox 200 | python3 -c "
import sys,json
data = json.load(sys.stdin)['data']
mostafa = [m for m in data if 'm.elkady@nxtedgetechnologies.com' in m.get('fromAddress','')]
unread = [m for m in mostafa if m.get('status','0') == '0']
print(f'Mostafa: {len(mostafa)} emails, {len(unread)} unread')
for m in unread:
    print(f'  UNREAD [{m.get(\"sentDateInGMT\",\"?\")[:10]}] {m.get(\"subject\",\"?\")[:80]}')
"
```

## Requirements Coverage Matrix (from Mostafa's emails)

| # | Topic | Covered | Files |
|---|-------|:-------:|-------|
| 1 | Install scripts (master/replica) | YES | install-symas-openldap-all-in-one.sh, replica-all-in-one.sh |
| 2 | Replication fix | YES | bank-fix-all.sh, fix-master.sh, fix-replica.sh |
| 3 | Password policy (bank) | YES | bank-apply-password-policy.sh, BANK_PASSWORD_POLICY.md |
| 4 | PPM module | YES | ppm.so build fix + password policy scripts |
| 5 | TLS certificates (prod) | YES | deploy-tls-lab.sh, CA-signed rollout tool |
| 6 | TLS hardening | YES | bank-fix-all.sh hardening toggle |
| 7 | Schema/Oracle orclisenabled | YES | bank-add-orclisenabled.sh (3 copies) |
| 8 | Verification scripts | YES | verify-master.sh (16pt), verify-replica.sh (17pt) |
| 9 | Backup/Restore | NO | Only inline logic in fix scripts; no standalone script |
| 10 | Pre-Go-Live checklist | NO | No go-live/readiness docs exist |
| 11 | Disaster Recovery | INC | DR dir exists, no full runbook |
| 12 | Monitoring/Alerts | INC | Health checks only, no continuous monitoring |
| 13 | VPN configuration | INC | Windows fix script only |
| 14 | CIAM/Soldap user setup | INC | Referenced but no setup script |

## Contacts

| Alias | Name | Email |
|-------|------|-------|
| me / Ibrahim | Ibrahim Timor | `ibrahim.timor@nxtedgetechnologies.com` |
| yo / Youssef | Muhammad Youssef | `muhammad.youssef.89@gmail.com` |
| mo / Mostafa | Mostafa El Kady | `m.elkady@nxtedgetechnologies.com` |

## Notes

- API base: `https://mail.zoho.com` (not zohoapis.com for Mail)
- Max 200 emails per request, default 10
- Content-Type must be `application/json`
- Token expires in 3600s — always refresh before use
- Self Client grant codes expire in 10 minutes — exchange immediately
- Scopes active: messages.ALL, accounts.READ, folders.READ
