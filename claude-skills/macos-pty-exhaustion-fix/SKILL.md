---
name: macos-pty-exhaustion-fix
description: Use when macOS throws "cannot allocate pseudo-terminal", forkpty errors, "out of pty", or terminals/AI-agents (Claude Code, Cursor, VS Code, iTerm) fail to spawn shells. Diagnoses PTY exhaustion, raises kern.tty.ptmx_max (hard cap 999), and finds the leaking process.
---

# macOS PTY exhaustion fix

`forkpty()` fails when the system runs out of pseudo-terminals. Symptom: "cannot allocate pseudo-terminal", new terminals/agent shells won't open.

## 1. Check current state

```bash
sysctl -n kern.tty.ptmx_max          # current limit
sudo lsof -nP /dev/ptmx | wc -l       # how many in use
# who is holding them:
sudo lsof -nP /dev/ptmx 2>/dev/null | awk 'NR>1{c[$1]++} END{for(p in c) print c[p],p}' | sort -nr | head -20
```

## 2. Find the leak (usually the real fix)

A single app pinned near the limit = the leak. **Claude Code has been seen holding 510 PTYs** (pinned at the old 511 ceiling). Restart that app to reclaim — band-aiding the limit alone won't help if it keeps leaking.

## 3. Raise the limit (headroom)

`kern.tty.ptmx_max` HARD CAPS at **999** on macOS. `1024/2048/4096` reject with `sysctl: kern.tty.ptmx_max=N: Invalid argument` — online guides citing 4096 are wrong.

```bash
sudo sysctl -w kern.tty.ptmx_max=999
```

If you have a stored sudo password (e.g. `SUDO_PASS` in a gitignored `.env`):
```bash
source /path/.env; printf '%s\n' "$SUDO_PASS" | sudo -S sysctl -w kern.tty.ptmx_max=999
```
(`sudo -S` reads stdin — password never lands in argv/logs.)

## 4. Persist (optional)

`sysctl -w` resets on reboot. `/etc/sysctl.conf` is unreliable on macOS → use a LaunchDaemon plist running the sysctl at boot. Only build this if the limit must survive reboots.
