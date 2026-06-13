# Public URL Sharing — Cloudflared Tunnel

Share a local web server with the world via a temporary public URL.

## Quick Start

### 1. Serve your content locally
```bash
python3 -m http.server 9876   # or any port
```

### 2. Expose via cloudflared tunnel
```bash
cloudflared tunnel --url http://localhost:9876 --logfile /tmp/cf.log 2>&1 &
sleep 12
cat /tmp/cf.log | grep -o 'https://[^ ]*trycloudflare[^ ]*'
```

### 3. Get the URL
```bash
cat /tmp/cf.log | grep -o 'https://[^ ]*trycloudflare[^ ]*'
```

## Pattern for Hermes (background process + URL extraction)

```bash
# Start server in background
terminal(command="cd /path/to/site && python3 -m http.server PORT", background=true)

# Start tunnel in background
terminal(command="cloudflared tunnel --url http://localhost:PORT --logfile /tmp/cf.log", background=true)

# Wait and extract URL
terminal(command="sleep 12 && cat /tmp/cf.log | grep -o 'https://[^ ]*trycloudflare[^ ]*'")

# Result: https://xxxx-xxxx-xxxx.trycloudflare.com
```

## Common Commands

| Task | Command |
|------|---------|
| One-off tunnel | `cloudflared tunnel --url http://localhost:9876` |
| With logfile | `cloudflared tunnel --url http://localhost:9876 --logfile /tmp/cf.log` |
| Metrics server | `cloudflared tunnel --url http://localhost:9876 --metrics localhost:9223` |
| Check existing tunnel | `cat /tmp/cf.log | grep trycloudflare` |

## Troubleshooting

| Issue | Fix |
|-------|-----|
| No URL in log | Increase sleep to 12+ seconds |
| Permission denied | Check cloudflared is installed: `which cloudflared` |
| Port already in use | Change port: `python3 -m http.server 9877` |
| Tunnel dies quickly | Use `--logfile` to capture output, check for errors |

## Alternatives

- **localtunnel** (`lt`): `lt --port 9876` → gives .lt.do.jp URL
- **serveo.net**: `ssh -o ServerAliveInterval=60 -R 80:localhost:9876 serveo.net`
- **ngrok**: `ngrok http 9876` → requires account

Cloudflared requires no account and is the recommended default.
