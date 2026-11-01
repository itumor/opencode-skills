---
name: docker-desktop-restart
description: Use when Docker Desktop on macOS is wedged - `docker` commands hang, `docker info` times out, "Cannot connect to the Docker daemon", "read-only file system" from the daemon (e.g. gitlab-ci-local volume create), or the user says docker/docer has an issue and asks to restart it.
---

# Restart a wedged Docker Desktop (macOS)

**Restart only when Docker is actually broken (user rule 2026-10-27).** Probe first; if every probe passes, do not restart. Restart stops all running containers (other sessions, MCP servers).

macOS has no `timeout`/`gtimeout`. Use perl's alarm for a hard cap:

```bash
t(){ perl -e 'alarm shift; exec @ARGV' "$@"; }
t 10 docker info --format '{{.ServerVersion}}'; echo "info exit=$?"
t 30 docker run --rm alpine:3 sh -c 'touch /tmp/x && echo rw-ok'
t 15 docker volume create rwprobe && docker volume rm rwprobe
```

Broken = any probe hangs/times out, "Cannot connect", or "read-only file system". Healthy = version + `rw-ok` + volume ok -> stop here, no restart.

"read-only file system" usually follows the Mac disk filling up (`df -h /System/Volumes/Data` >= 99%). Free space first, then restart: Docker stays read-only until restarted, even after space is back.

## Restart (only if broken)

```bash
osascript -e 'quit app "Docker"'
sleep 20
pkill -9 -f 'com.docker.backend' ; pkill -9 -f 'Docker Desktop.app' ; pkill -9 -f 'docker-agent'
open -a Docker
t(){ perl -e 'alarm shift; exec @ARGV' "$@"; }
for i in $(seq 1 45); do t 5 docker info >/dev/null 2>&1 && { echo up; break; }; sleep 4; done
```

Then re-run the three probes above.

Notes:
- Restart stops all running containers, including MCP ones (`terraform-mcp-server`). They come back when the MCP client reconnects.
- Stuck `docker system df` / `docker image inspect` CLI processes: kill them before restarting (`pkill -f 'docker system df'`).
- If the daemon is still down after restart, check Docker Desktop's own UI or logs under `~/Library/Containers/com.docker.docker/Data/log/`. Do not reinstall without asking.
- Killing processes is not destructive for images or volumes; Docker data stays on disk.
