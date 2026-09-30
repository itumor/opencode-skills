#!/usr/bin/env bash
# Read-only on-host usage check via SSM RunShellScript.
# Usage: onhost.sh <profile-with-ssm:SendCommand> <region> <instance-id> [ticket]
# ReadOnlyAccess can NOT send-command; use the Admin profile (script itself only reads).
set -uo pipefail
[ $# -ge 3 ] || { echo "usage: $0 <profile> <region> <instance-id> [ticket]"; exit 2; }
P=$1 R=$2 I=$3 T=${4:-decommission}
A=(aws --profile "$P" --region "$R")
D=$(mktemp -d)

cat > "$D/remote.sh" <<'EOF'
echo "## uptime/date"; uptime; date -u
echo "## who / last (reboots only = nobody logs in)"; who; last -a -n 25 2>&1 | head -30
echo "## lastlog (empty = no user ever logged in)"; timeout 15 lastlog 2>/dev/null | grep -v "Never logged in"
echo "## established TCP"; ss -tnH state established 2>&1 | head -40
echo "## listening"; ss -tlnH 2>&1 | head -20
echo "## docker ps"; docker ps -a --format '{{.Names}} {{.Image}} {{.Status}}' 2>&1
echo "## cron"; ls /etc/cron.d 2>&1; for u in $(cut -d: -f1 /etc/passwd); do c=$(crontab -l -u $u 2>/dev/null); [ -n "$c" ] && echo "-- $u" && echo "$c"; done
echo "## systemd timers"; systemctl list-timers --no-pager 2>&1 | head -15
docker ps -q 2>/dev/null | while read c; do n=$(docker inspect -f '{{.Name}}' $c); echo "-- $n client IPs (last 400 lines)"; timeout 15 docker logs --tail 400 $c 2>&1 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort | uniq -c | sort -nr | head -8; echo "-- $n last 5"; timeout 15 docker logs --tail 5 $c 2>&1 | cut -c1-250; done
echo "## access/request logs"
timeout 40 find /var/log /opt /data /nexus-data /var/lib/docker/volumes -maxdepth 6 \( -name 'request*.log' -o -name 'access*.log' \) -size +0 2>/dev/null | head -10 | while read f; do echo "== $f (mtime $(stat -c %y "$f"))"; tail -3 "$f" | cut -c1-250; done
echo "## ssh auth (last 20)"; grep -E "Accepted|session opened" /var/log/secure /var/log/auth.log 2>/dev/null | tail -20
EOF

python3 -c 'import json,sys;json.dump({"commands":open(sys.argv[1]).read().splitlines()},open(sys.argv[2],"w"))' "$D/remote.sh" "$D/params.json"
CID=$("${A[@]}" ssm send-command --instance-ids "$I" --document-name AWS-RunShellScript \
  --comment "$T read-only usage check" --parameters "file://$D/params.json" --query Command.CommandId --output text) || exit 1
for _ in $(seq 1 40); do
  s=$("${A[@]}" ssm get-command-invocation --command-id "$CID" --instance-id "$I" --query Status --output text 2>&1)
  case $s in InProgress|Pending|*InvocationDoesNotExist*) sleep 4;; *) break;; esac
done
echo "Status $s (CommandId $CID)"
"${A[@]}" ssm get-command-invocation --command-id "$CID" --instance-id "$I" --query '[StandardOutputContent,StandardErrorContent]' --output text
