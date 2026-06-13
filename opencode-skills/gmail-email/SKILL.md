---
name: gmail-email
description: Send emails via authenticated Gmail account. Use when asked to send an email, notify someone, or share information via Gmail. Covers to, cc, bcc, subject, and body parameters.
---

# Gmail Email Sending

## Tool

`gmail-send_send_email` — sends email using the authenticated Gmail account.

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `to` | Yes | Recipient email address |
| `subject` | Yes | Email subject line |
| `body` | Yes | Email body (plain text or markdown) |
| `cc` | No | CC recipients |
| `bcc` | No | BCC recipients |
| `attachments` | No | List of file paths to attach |

## Example

```
gmail-send_send_email:
  to: "recipient@example.com"
  subject: "Subject line here"
  body: "Email body content here"
  attachments: ["/path/to/file.pdf", "/path/to/report.zip"]
```

## MCP Server

`~/.config/gmail-opencode/server.py` (Python FastMCP + Gmail API). Venv at `~/.config/gmail-opencode/.venv/`.

Server handles attachments via `make_mixed()` + `EmailMessage.attach()` for text + `add_attachment()` for files. Requires `import mimetypes`.

If tool doesn't pick up new params (server not restarted), fallback: call the venv Python directly with Gmail API credentials from `token.json`.

```python
from email.message import EmailMessage
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build

creds = Credentials.from_authorized_user_file('~/.config/gmail-opencode/token.json', ['https://www.googleapis.com/auth/gmail.send'])
service = build('gmail', 'v1', credentials=creds)
msg = EmailMessage()
msg['To'] = '...'; msg['Subject'] = '...'
msg.make_mixed()
text_part = EmailMessage(); text_part.set_content(body, subtype='plain')
msg.attach(text_part)
msg.add_attachment(data, maintype='application', subtype='zip', filename='file.zip')
encoded = base64.urlsafe_b64encode(msg.as_bytes()).decode()
service.users().messages().send(userId='me', body={'raw': encoded}).execute()
```

## Notes

- Sent emails appear in the authenticated user's Gmail Sent folder.
- On success, returns the Gmail message ID.
- Recipient may need to check spam folder if email is not in inbox.
- `attachments` param was added 2026-06-13. Before that, use Python fallback above.
- Do NOT use `add_alternative()` after `make_mixed()` — raises `ValueError: Cannot convert mixed to alternative`.
