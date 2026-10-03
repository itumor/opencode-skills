# sourced by every MW script. TARGET=clone|prod must be set by caller.
set -euo pipefail
B=/root/${TICKET,,}; mkdir -p $B; cd ${COMPOSE_DIR:-/opt/docker_compose_nexus}
PG="docker exec docker_compose_nexus-postgres-1"
IID=$(TOK=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60'); curl -s -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/instance-id)
FQ=$(getent hosts $FQDN | awk '{print $1}')
case "${TARGET:-}" in
  clone) [ "$FQ" = 127.0.0.1 ] && [ "$IID" = "$CLONE_IID" ] || { echo "GUARD: not the clone ($IID $FQ)"; exit 9; } ;;
  prod)  [ "$IID" = "$PROD_IID" ] && [ "$FQ" != 127.0.0.1 ] || { echo "GUARD: not prod ($IID $FQ)"; exit 9; } ;;
  *) echo "GUARD: TARGET unset"; exit 9 ;;
esac
echo "target=$TARGET iid=$IID $(date -u +%FT%TZ)"
wait_writable(){ for i in $(seq 1 ${1:-90}); do c=$(curl -sk -o /dev/null -w '%{http_code}' https://localhost/service/rest/v1/status/writable || true); [ "$c" = 200 ] && { echo "writable=200 after $((i*5))s"; return 0; }; sleep 5; done; echo "writable=$c TIMEOUT"; return 1; }
