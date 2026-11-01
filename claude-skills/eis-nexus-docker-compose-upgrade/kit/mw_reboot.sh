cat /proc/sys/kernel/random/boot_id > $B/boot_id.pre; echo "boot_id.pre=$(cat $B/boot_id.pre)"; shutdown -r +0 "COEXT-112039 reboot" && echo reboot-scheduled
