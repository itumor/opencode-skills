# B1 pg_dump (writes stopped) + B3 /opt tarball, then stop whole stack (ready for B2 snapshot)
TS=$(date -u +%Y%m%dT%H%M)
docker compose stop nexus nginx
$PG pg_dump -Fc -U nexus nexus > $B/nexus-$TS.dump
n=$(docker exec -i docker_compose_nexus-postgres-1 pg_restore -l < $B/nexus-$TS.dump | grep -c 'TABLE DATA')
[ "$n" -gt 50 ] || { echo "B1 FAIL toc_table_data=$n"; exit 8; }
sha256sum $B/nexus-$TS.dump > $B/nexus-$TS.dump.sha256
tar czf $B/opt-$TS.tgz /opt/docker_compose_nexus /opt/nginx /opt/ssl 2>/dev/null
ln -sfn $B/nexus-$TS.dump $B/LATEST.dump; ln -sfn $B/opt-$TS.tgz $B/LATEST.tgz
docker compose stop
echo "B1 ok toc_table_data=$n $(du -h $B/nexus-$TS.dump | cut -f1)  B3 ok $(du -h $B/opt-$TS.tgz | cut -f1)  stack stopped"
docker ps -a --format '{{.Names}}|{{.Status}}'
