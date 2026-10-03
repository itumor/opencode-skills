[ "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat $B/boot_id.pre)" ] || { echo "G2 FAIL: not rebooted"; exit 6; }
for i in $(seq 1 24); do systemctl is-active -q docker && break; sleep 5; done
echo "G2 rebooted kernel=$(uname -r) docker=$(systemctl is-active docker)"
docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}'
