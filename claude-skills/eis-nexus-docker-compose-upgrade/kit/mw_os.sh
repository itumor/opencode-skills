# dnf update with stack already stopped; reboot is a separate call
docker ps -q | grep -q . && { echo "stack still running, refuse"; exit 7; }
cat /proc/sys/kernel/random/boot_id > $B/boot_id.pre
dnf -y update > $B/dnf-$(date -u +%Y%m%dT%H%M).log 2>&1; echo "dnf_rc=$?"
rpm -q kernel --last | head -1; rpm -q docker-ce containerd.io
