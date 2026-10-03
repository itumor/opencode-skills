wait_writable 90
docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}'
for p in 443 5000 5001 5002; do printf "port$p=%s " "$(curl -sk -o /dev/null -w '%{http_code}' https://localhost:$p/v2/ || true)"; done; echo
echo "version=$(docker logs docker_compose_nexus-nexus-1 2>&1 | grep -o 'Started Sonatype Nexus [A-Z]* [0-9.]*-[0-9]*' | tail -1)"
echo "repos=$($PG psql -U nexus -d nexus -At -c 'select count(*) from repository')"
echo "nginx_host_not_found_last5m=$(docker logs --since 5m docker_compose_nexus-nginx-1 2>&1 | grep -c 'host not found' || true)"
