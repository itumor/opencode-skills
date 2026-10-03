# R1: back to pre-upgrade app state from B1+B3 (OS untouched). Uses LATEST.* unless DUMP/TGZ set.
DUMP=${DUMP:-$(readlink -f $B/LATEST.dump)}; TGZ=${TGZ:-$(readlink -f $B/LATEST.tgz)}
sha256sum -c $DUMP.sha256
docker compose stop || true
tar xzf $TGZ -C /
docker compose up -d postgres
for i in $(seq 1 30); do $PG pg_isready -U nexus -q && break; sleep 2; done
docker exec -i docker_compose_nexus-postgres-1 sh -c 'cat > /tmp/r1.dump' < $DUMP
$PG psql -U nexus -d postgres -qc "select pg_terminate_backend(pid) from pg_stat_activity where datname='nexus' and pid<>pg_backend_pid()" >/dev/null
$PG dropdb -U nexus nexus; $PG createdb -U nexus -O nexus nexus
$PG pg_restore -U nexus -d nexus --no-owner --role=nexus -j 2 /tmp/r1.dump; $PG rm -f /tmp/r1.dump
docker compose up -d
wait_writable 90
echo "R1 done image=$(docker inspect -f '{{.Config.Image}}' docker_compose_nexus-nexus-1)"
